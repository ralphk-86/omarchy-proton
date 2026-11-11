#!/usr/bin/env bash
# ============================================================================
#  install.sh - set up (or update) the system part of omarchy-proton.
#
#  The Omarchy plugin installer only copies this folder; it never runs sudo.
#  The kill switch, the torrent namespace and the helpers need root once, and
#  this script is that once. The VPN panel runs it for you ("Finish setup");
#  you can also run it in a terminal. Run it again after `omarchy plugin
#  update` when the panel says the system part is out of date.
#
#  Run as your normal user. Asks for your password once, through sudo in a
#  terminal or a polkit dialog otherwise.
#
#  USAGE
#    install.sh                 install or update
#    install.sh --keep-ipv6     leave IPv6 on (see README); on an existing
#                               install it sets DISABLE_IPV6=0 (vpnkit.conf is
#                               backed up) and gives IPv6 back
#    install.sh --qbt-config    also apply the recommended qBittorrent settings
#                               (qbittorrent/qBittorrent.conf.template) to your
#                               qBittorrent.conf; a backup is kept. Never done
#                               unless you ask for it.
#    install.sh --qbt-launcher  replace a qBittorrent launcher entry of your
#                               own with the kit's; yours is backed up and the
#                               uninstaller puts it back
#    install.sh --move-aside    move files of yours in /usr/local/bin that have
#                               the names of the kit's commands aside (the
#                               uninstaller puts them back); without it setup
#                               stops and names them
#  Options combine.
# ============================================================================
set -euo pipefail

[ "$(uname -s)" = "Linux" ] || { echo "omarchy-proton is for Linux (Omarchy)."; exit 1; }
[[ $EUID -eq 0 ]] && { echo "Run as your normal user, without sudo."; exit 1; }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
# The log holds the status output (external IPs, server names): readable by
# you only, in your runtime folder, or in ~/.cache without one (over SSH).
if [[ -n "${XDG_RUNTIME_DIR:-}" && -d "$XDG_RUNTIME_DIR" && -O "$XDG_RUNTIME_DIR" ]]; then
  LOG="$XDG_RUNTIME_DIR/vpnkit-install.log"
else
  # Created private if missing; an existing ~/.cache keeps its mode (the log
  # file itself is private either way).
  [[ -d "$HOME/.cache" ]] || install -d -m 700 "$HOME/.cache"
  LOG="$HOME/.cache/vpnkit-install.log"
fi
rm -f -- "$LOG"
( umask 077; : > "$LOG" )
ROOT_ARGS=(); DO_QBT_CONF=0; DO_QBT_LAUNCHER=0
for a in "$@"; do
  case "$a" in
    --keep-ipv6)     ROOT_ARGS+=("--keep-ipv6") ;;
    --move-aside)    ROOT_ARGS+=("--move-aside") ;;
    --qbt-config)    DO_QBT_CONF=1 ;;
    --qbt-launcher)  DO_QBT_LAUNCHER=1 ;;
    -h|--help)       sed -n '2,31p' "$0"; exit 0 ;;
    *) echo "unknown option: $a"; exit 1 ;;
  esac
done

say()  { printf '==> %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*"; }

# Which launcher entries are the kit's (marker line): the same code the
# uninstallers use. Run as you.
# shellcheck disable=SC1091
. "$SRC/system/lib/owned.sh"

# The qBittorrent launcher entry (menus, magnet links) has to start the
# wrapper. The kit's own entry is written or updated; one of yours is left
# alone unless you pass --qbt-launcher (then it is backed up first, and the
# uninstaller puts it back). Nothing here stops the run: the system part is
# already done, and a launcher that cannot be written is only a warning.
qbt_launcher() {
  local apps="$HOME/.local/share/applications" desk tmp bak exe
  desk=$(vpnkit_qbt_desk "$HOME")
  if [[ -e "$desk" || -L "$desk" ]] && ! vpnkit_desk_ours "$desk" "$VPNKIT_QBT_DESK_MARK" "$VPNKIT_QBT_DESK_LEGACY_SHA"; then
    if (( ! DO_QBT_LAUNCHER )); then
      exe=$(vpnkit_desk_exec "$desk") || exe=""
      case "$exe" in
        qbittorrent|/usr/local/bin/qbittorrent)
          echo "    your own qBittorrent launcher entry is kept; it starts $exe, which reaches the tunnel" ;;
        *)
          warn "Your own qBittorrent launcher entry ($desk) starts ${exe:-nothing},"
          warn "which skips the torrent tunnel. It is left as it is. Change its Exec= to"
          warn "/usr/local/bin/qbittorrent, or replace it with the kit's (yours is backed up,"
          warn "and the uninstaller puts it back) by running"
          warn "    $(printf '%q' "$SRC/install.sh") --qbt-launcher" ;;
      esac
      return 0
    fi
    if ! bak=$(vpnkit_desk_backup "$desk"); then
      warn "Could not back up your own qBittorrent launcher entry ($desk); it is left as it is."
      return 0
    fi
    echo "    your own qBittorrent launcher entry is kept as $bak (the uninstaller puts it back)"
  fi
  say "Pointing the qBittorrent launcher at the namespace wrapper"
  if ! install -d -m 755 "$apps" || ! tmp=$(mktemp "$apps/.qbittorrent.desktop.XXXXXX" 2>/dev/null); then
    warn "Could not write the qBittorrent launcher entry in $apps; it is left as it is."
    return 0
  fi
  if ! { printf '%s\n' "$VPNKIT_QBT_DESK_MARK"; cat "$SRC/applications/org.qbittorrent.qBittorrent.desktop"; } > "$tmp" \
     || ! chmod 644 "$tmp" || ! mv -f "$tmp" "$desk"; then
    rm -f -- "$tmp"
    warn "Could not write the qBittorrent launcher entry $desk; it is left as it is."
    return 0
  fi
  vpnkit_desk_refresh "$apps"
}

main() {
  say "omarchy-proton $(cat "$SRC/VERSION"): system setup (one password prompt)"
  if [[ -t 0 ]]; then
    sudo /usr/bin/bash "$SRC/system/install-root.sh" "$SRC" "$USER" "${ROOT_ARGS[@]}"
  else
    pkexec /usr/bin/bash "$SRC/system/install-root.sh" "$SRC" "$USER" "${ROOT_ARGS[@]}"
  fi

  # Chrome direct (off unless turned on with vpn-direct): the Chrome launcher
  # entry follows it, so a reinstall rewrites it from the current package.
  /usr/local/bin/vpn-direct launcher || warn "Chrome direct: could not update the Chrome launcher entry"
  # The Firefox tunnel (off until a Firefox server is chosen): the same for
  # the Firefox launcher entry.
  /usr/local/bin/vpn-firefox-launcher || warn "Firefox tunnel: could not update the Firefox launcher entry"

  if command -v qbittorrent >/dev/null 2>&1 || [[ -x /usr/bin/qbittorrent ]]; then
    qbt_launcher

    local qconf="$HOME/.config/qBittorrent/qBittorrent.conf"
    if (( DO_QBT_CONF )); then
      if pgrep -x qbittorrent >/dev/null; then
        warn "qBittorrent is running and rewrites its settings on exit. Close it and run install.sh again to apply the template."
      else
        say "Applying the recommended qBittorrent settings"
        local wgif save
        wgif=$( . /usr/local/lib/vpnkit/common.sh; printf '%s' "$WG_IF" )
        save="$(xdg-user-dir DOWNLOAD 2>/dev/null || echo "$HOME/Downloads")/torrents"
        install -d -m 755 "$save" "$save/incomplete" "$(dirname "$qconf")"
        [[ -f "$qconf" ]] && cp -a "$qconf" "$qconf.bak.$STAMP"
        # Merge key by key so GUI preferences survive.
        python3 - "$SRC/qbittorrent/qBittorrent.conf.template" "$qconf" "$wgif" "$save" <<'PY'
import sys, configparser
tpl, live, wgif, save = sys.argv[1:5]
def load(p):
    c = configparser.RawConfigParser(); c.optionxform = str
    try: c.read(p, encoding='utf-8')
    except Exception: pass
    return c
t = load(tpl); l = load(live)
for sec in t.sections():
    if not l.has_section(sec): l.add_section(sec)
    for k, v in t.items(sec):
        l.set(sec, k, v.replace('@WG_IF@', wgif).replace('@SAVE_PATH@', save))
with open(live, 'w', encoding='utf-8') as f: l.write(f, space_around_delimiters=False)
print(f"    merged (interface {wgif}, downloads to {save})")
PY
      fi
    fi
  else
    echo "    qBittorrent is not installed; the torrent tunnel is optional (omarchy pkg add qbittorrent)"
  fi

  echo
  say "Done."
  /usr/local/bin/vpn-status || true
  local dir
  dir=$( . /usr/local/lib/vpnkit/common.sh; printf '%s' "$CONFIG_DIR" )
  cat <<TXT

  Put WireGuard configs in   $dir
  (one more, used nowhere else, in its torrent/ subfolder), then press Refresh
  in the VPN panel.

  vpn-status     both tunnels and both external IPs
  vpn-toggle     switch server / "vpn-toggle off" for the normal connection
  vpn-import     import what is waiting in the folder
  vpn-verify     leak checks ("--fail-closed" also pulls the tunnels down to prove it)
  vpn-rescue     way back: VPN off, kill switch off, normal internet
TXT
}

# Keep a log: when the panel runs this there is no terminal to read.
main 2>&1 | tee "$LOG"
exit "${PIPESTATUS[0]}"
