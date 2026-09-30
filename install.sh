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
#    install.sh --keep-ipv6     first install only: leave IPv6 on (see README)
#    install.sh --qbt-config    also apply the recommended qBittorrent settings
#                               (qbittorrent/qBittorrent.conf.template) to your
#                               qBittorrent.conf; a backup is kept. Never done
#                               unless you ask for it.
# ============================================================================
set -euo pipefail

[ "$(uname -s)" = "Linux" ] || { echo "omarchy-proton is for Linux (Omarchy)."; exit 1; }
[[ $EUID -eq 0 ]] && { echo "Run as your normal user, without sudo."; exit 1; }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="${XDG_RUNTIME_DIR:-/tmp}/vpnkit-install.log"
ROOT_ARGS=(); DO_QBT_CONF=0
for a in "$@"; do
  case "$a" in
    --keep-ipv6)     ROOT_ARGS+=("--keep-ipv6") ;;
    --qbt-config)    DO_QBT_CONF=1 ;;
    -h|--help)       sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown option: $a"; exit 1 ;;
  esac
done

say()  { printf '==> %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*"; }

main() {
  say "omarchy-proton $(cat "$SRC/VERSION"): system setup (one password prompt)"
  if [[ -t 0 ]]; then
    sudo /usr/bin/bash "$SRC/system/install-root.sh" "$SRC" "$USER" "${ROOT_ARGS[@]}"
  else
    pkexec /usr/bin/bash "$SRC/system/install-root.sh" "$SRC" "$USER" "${ROOT_ARGS[@]}"
  fi

  if command -v qbittorrent >/dev/null 2>&1 || [[ -x /usr/bin/qbittorrent ]]; then
    say "Pointing the qBittorrent launcher at the namespace wrapper"
    local apps="$HOME/.local/share/applications" desk
    desk="$apps/org.qbittorrent.qBittorrent.desktop"
    install -d -m 755 "$apps"
    if [[ -f "$desk" ]] && ! cmp -s "$SRC/applications/org.qbittorrent.qBittorrent.desktop" "$desk"; then
      cp -a "$desk" "$desk.bak.$STAMP"
    fi
    install -m 644 "$SRC/applications/org.qbittorrent.qBittorrent.desktop" "$desk"
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$apps" >/dev/null 2>&1 || true

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
