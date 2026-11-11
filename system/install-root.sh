#!/usr/bin/env bash
# ============================================================================
#  install-root.sh - the privileged half of the vpnkit install.
#  Do not run this directly; ../install.sh calls it once through sudo (in a
#  terminal) or pkexec (from the VPN panel).
#
#  Usage: install-root.sh <plugin-dir> <user> [--keep-ipv6] [--move-aside]
#    --keep-ipv6   leave IPv6 on (DISABLE_IPV6=0); on an existing install it
#                  also gives IPv6 back (vpnkit.conf is backed up first)
#    --move-aside  files of yours in /usr/local/bin that have the names of the
#                  kit's commands are moved to /usr/local/lib/vpnkit/moved-aside
#                  (the uninstaller puts them back); without it setup stops
#                  and changes nothing when there are any
#
#  Nothing here changes the normal route or the normal DNS, and nothing here
#  connects a VPN. The last step checks that the internet still answers and
#  undoes the network-facing changes if it does not; it runs as well when a
#  step fails half way. The version stamp (/usr/local/lib/vpnkit/VERSION),
#  which tells the panel that setup is done, is written only when every step
#  succeeded.
# ============================================================================
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/bin"

[ "$(uname -s)" = "Linux" ] || { echo "Linux only"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "must run as root"; exit 1; }

SRC="${1:?plugin dir}"; RUN_USER="${2:?user}"; shift 2
KEEP_V6=0; MOVE_ASIDE=0
for a in "$@"; do
  case "$a" in
    --keep-ipv6)  KEEP_V6=1 ;;
    --move-aside) MOVE_ASIDE=1 ;;
    *) echo "unknown option: $a"; exit 1 ;;
  esac
done
SYS="$SRC/system"
[[ -f "$SYS/lib/common.sh" && -f "$SYS/lib/owned.sh" && -f "$SYS/lib/released-bin.sha256" && -f "$SRC/VERSION" ]] || { echo "no vpnkit under $SRC"; exit 1; }
id "$RUN_USER" >/dev/null 2>&1 || { echo "unknown user $RUN_USER"; exit 1; }
[[ "$RUN_USER" != "root" ]] || { echo "install for your normal user, not root"; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
STEP="starting"
say()  { STEP="$*"; printf '==> %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*"; }
# Which files are the kit's (marker line), the same code the uninstaller uses.
# shellcheck disable=SC1091
. "$SYS/lib/owned.sh"

# ------------------------------------------------- checks that change nothing -
# The kit acts for one desktop user (TARGET_USER): the torrent tunnel and
# Chrome run as that user, the drop folder is theirs. The passwordless rules
# are written for whoever runs setup. Another user running it would get the
# rules while the kit keeps acting for the first one: stop instead.
# Read the way every helper reads it (common.sh sources the file), so quotes
# or a comment on that line mean the same user here as there.
if [[ -r /etc/vpnkit/vpnkit.conf ]]; then
  pinned=$(set +eu; . /etc/vpnkit/vpnkit.conf >/dev/null 2>&1; printf '%s' "${TARGET_USER:-}") || true
  if [[ -n "$pinned" && "$pinned" != "$RUN_USER" ]]; then
    echo "omarchy-proton is set up for the desktop user '$pinned' (TARGET_USER in /etc/vpnkit/vpnkit.conf)."
    echo "Run by '$RUN_USER', setup would give $RUN_USER the passwordless rules while the torrent"
    echo "tunnel, Chrome direct and the drop folder keep acting for $pinned. Nothing was changed."
    echo "To move the kit to $RUN_USER, set TARGET_USER=\"$RUN_USER\" in /etc/vpnkit/vpnkit.conf"
    echo "(as root), then run setup again as $RUN_USER:"
    printf '    %q\n' "$SRC/install.sh"
    exit 1
  fi
fi

# Files in /usr/local/bin with the names of the kit's commands that are not
# the kit's (an admin's own wrapper, say): never replaced without being asked.
FOREIGN=()
for f in "$SYS"/bin/*; do
  t="/usr/local/bin/$(basename "$f")"
  if [[ -e "$t" || -L "$t" ]] && ! vpnkit_owned_bin "$t"; then FOREIGN+=("$t"); fi
done
if (( ${#FOREIGN[@]} )) && (( ! MOVE_ASIDE )); then
  echo "These files are not omarchy-proton's, and setup would have to replace them:"
  printf '    %s\n' "${FOREIGN[@]}"
  echo "Nothing was changed. Move them away yourself, or run setup in a terminal as"
  printf '    %q --move-aside\n' "$SRC/install.sh"
  echo "which keeps them in $VPNKIT_ASIDE; the uninstaller puts them back."
  echo "If one of them is an edited copy of omarchy-proton's own command (or one from"
  echo "before 0.3.0), delete it instead: moved aside, the uninstaller would put it back."
  exit 1
fi

# The same lookup address the rest of the kit uses, once it is configured.
LOOKUP_URL="https://ifconfig.me/ip"
if [[ -r /etc/vpnkit/vpnkit.conf ]]; then
  configured=$(sed -nE 's/^IP_LOOKUP_URL="?([^"]*)"?.*/\1/p' /etc/vpnkit/vpnkit.conf | tail -1)
  [[ -n "$configured" ]] && LOOKUP_URL="$configured"
fi
internet_ok() {
  local i answer
  for i in 1 2 3; do
    # Capped at 256 bytes (an IP address); common.sh is not installed yet at this point.
    answer=$(curl -4 -s --max-time 6 --max-filesize 256 "$LOOKUP_URL" 2>/dev/null) || answer=""
    [[ -n "$answer" ]] && return 0
    sleep 2
  done
  return 1
}

say "Checking prerequisites"
# command -> the official Arch package that provides it. Omarchy ships most of
# these; whatever is missing is installed from the official repositories.
# xdg-dbus-proxy: Chrome direct gives Chrome a filtered session bus (direct-launch).
declare -A PKG=( [wg]=wireguard-tools [nft]=nftables [nmcli]=networkmanager [jq]=jq [curl]=curl
                 [ip]=iproute2 [visudo]=sudo [uuidgen]=util-linux [runuser]=util-linux
                 [xdg-dbus-proxy]=xdg-dbus-proxy )
NEED=()
for c in "${!PKG[@]}"; do
  command -v "$c" >/dev/null 2>&1 || NEED+=("${PKG[$c]}")
done
if (( ${#NEED[@]} )); then
  mapfile -t NEED < <(printf '%s\n' "${NEED[@]}" | sort -u)
  command -v pacman >/dev/null 2>&1 || { echo "missing packages: ${NEED[*]} (and no pacman to install them)"; exit 1; }
  say "Installing missing packages: ${NEED[*]}"
  pacman -S --needed --noconfirm "${NEED[@]}" || {
    echo "Could not install ${NEED[*]}. Run 'omarchy update' (the package list may be out of date), then setup again."
    exit 1
  }
fi
# The desktop VPN is a NetworkManager connection. This kit does not switch a
# machine from another network manager to NetworkManager behind your back.
if ! systemctl is-active --quiet NetworkManager; then
  echo "NetworkManager is not running. omarchy-proton manages the VPN through NetworkManager"
  echo "(the Omarchy default). Enable it first, then run setup again."
  exit 1
fi
# Without secure_path in sudoers, sudo hands every caller's PATH to the
# commands it runs as root. The kit's own helpers set a fixed PATH first, so
# they are not affected; other sudo rules on this machine may be. Said, not
# changed: /etc/sudoers is the administrator's.
# (LC_ALL=C: sudo -V is translated, and sudo keeps the caller's LANG. Read in
# full first: grep -q quitting early would fail the pipe under pipefail.)
SUDO_V=$(LC_ALL=C sudo -V 2>/dev/null) || SUDO_V=""
if ! grep -q "Value to override user's \$PATH with" <<< "$SUDO_V"; then
  warn "sudo has no secure_path (/etc/sudoers): it passes your PATH on to what it runs as root."
  warn "The kit's helpers do not depend on it. Other sudo rules may: consider adding"
  warn "  Defaults secure_path=\"/usr/local/sbin:/usr/local/bin:/usr/bin\""
  warn "to /etc/sudoers (with visudo)."
fi
# With a kill switch armed and no tunnel, the machine is offline on purpose;
# that is not a reason to refuse an update.
ONLINE_BEFORE=1
internet_ok || ONLINE_BEFORE=0

# From here on the system part changes. Until the last step has succeeded it
# is not finished: no version stamp (the panel offers setup again), and a
# step that fails still gets the connectivity check and its rollback.
WIRED_V6=()       # uuids of the profiles switched off here, for the rollback
V6_SYSCTL_NEW=0   # this run switched IPv6 off (the rollback undoes only that)
NET_TOUCHED=0     # the network-facing changes have begun
CHECKED=0         # the connectivity check has run
INCOMPLETE=()     # steps that failed but did not stop the run
# connectivity_check: did the normal connection survive? If not, undo the
# network-facing changes of this run. Also run (from on_exit) when a step
# failed half way. Returns 1 after a rollback.
connectivity_check() {
  CHECKED=1
  say "Checking that the normal connection still works"
  if (( ! ONLINE_BEFORE )); then
    echo "    offline before and after (kill switch holding, or no network) - nothing to compare"
    return 0
  elif internet_ok; then
    echo "    internet OK, default route: $(ip -4 route show default | head -1)"
    return 0
  fi
  warn "No internet after the install - undoing the network-facing changes"
  # Only what this run changed: on an update, IPv6 was already off by an
  # earlier install's choice, and stays off.
  if (( V6_SYSCTL_NEW )); then
    rm -f /etc/sysctl.d/99-vpnkit-disable-ipv6.conf
    sysctl -qw net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 2>/dev/null || true
  fi
  # Each profile gets all its saved IPv6 settings back and its running link
  # is reapplied, so a network that needs IPv6 works again at once.
  local uuid
  for uuid in "${WIRED_V6[@]}"; do
    v6_restore_profile "$uuid" || true   # it names a profile it could not restore
  done
  if internet_ok; then echo "    internet is back after the rollback"
  else echo "    STILL no internet - run vpn-rescue, then check the router"; fi
  return 1
}
on_exit() {
  local rc=$?
  trap - EXIT
  (( rc != 0 && ! CHECKED )) || exit "$rc"
  warn "Setup stopped during: $STEP (exit $rc). It is not finished; the panel keeps offering it."
  if (( NET_TOUCHED )); then connectivity_check || true; fi
  exit "$rc"
}
trap on_exit EXIT
rm -f /usr/local/lib/vpnkit/VERSION

# ------------------------------------------------------------------ config -
say "Installing configuration to /etc/vpnkit"
install -d -m 755 /etc/vpnkit /etc/vpnkit/providers
for p in "$SRC"/providers/*.preset; do
  install -m 644 "$p" "/etc/vpnkit/providers/$(basename "$p" .preset).conf"
done
if [[ -f /etc/vpnkit/vpnkit.conf ]]; then
  echo "    keeping your /etc/vpnkit/vpnkit.conf"
  # --keep-ipv6 on an existing install: asked for, so the setting changes
  # (backup first), and the IPv6 step below gives IPv6 back.
  if (( KEEP_V6 )) && ! grep -qx 'DISABLE_IPV6=0' /etc/vpnkit/vpnkit.conf; then
    cp -a /etc/vpnkit/vpnkit.conf "/etc/vpnkit/vpnkit.conf.bak.$STAMP"
    if grep -qE '^DISABLE_IPV6=' /etc/vpnkit/vpnkit.conf; then
      sed -i 's/^DISABLE_IPV6=.*/DISABLE_IPV6=0/' /etc/vpnkit/vpnkit.conf
    else
      printf '\n# Set by install.sh --keep-ipv6.\nDISABLE_IPV6=0\n' >> /etc/vpnkit/vpnkit.conf
    fi
    echo "    --keep-ipv6: set DISABLE_IPV6=0 (the previous file is /etc/vpnkit/vpnkit.conf.bak.$STAMP)"
  fi
else
  install -m 644 "$SYS/vpnkit.settings" /etc/vpnkit/vpnkit.conf
  (( KEEP_V6 )) && sed -i 's/^DISABLE_IPV6=.*/DISABLE_IPV6=0/' /etc/vpnkit/vpnkit.conf
fi
# Pin the desktop user, so services that run without a login session (the
# boot-time namespace, the NetworkManager hook) agree on who it is.
if grep -qE '^TARGET_USER=""' /etc/vpnkit/vpnkit.conf; then
  sed -i "s/^TARGET_USER=\"\"/TARGET_USER=\"$RUN_USER\"/" /etc/vpnkit/vpnkit.conf
elif ! grep -qE '^TARGET_USER=' /etc/vpnkit/vpnkit.conf; then
  printf '\n# The desktop user (added by the installer).\nTARGET_USER="%s"\n' "$RUN_USER" >> /etc/vpnkit/vpnkit.conf
fi

# ----------------------------------------------------- library and helpers -
say "Installing helpers to /usr/local/bin"
install -d -m 755 /usr/local/lib/vpnkit
install -m 644 "$SYS/lib/common.sh" /usr/local/lib/vpnkit/common.sh
install -m 644 "$SYS/lib/netns.sh" /usr/local/lib/vpnkit/netns.sh
install -m 644 "$SYS/lib/direct.sh" /usr/local/lib/vpnkit/direct.sh
install -m 644 "$SYS/lib/ipv6.sh" /usr/local/lib/vpnkit/ipv6.sh
install -m 644 "$SYS/lib/owned.sh" /usr/local/lib/vpnkit/owned.sh
install -m 644 "$SYS/lib/released-bin.sha256" /usr/local/lib/vpnkit/released-bin.sha256
# Chrome direct's xdg-open, first in Chrome's PATH only (see direct-launch).
install -d -m 755 /usr/local/lib/vpnkit/direct-bin
install -m 755 "$SYS/direct-bin/xdg-open" /usr/local/lib/vpnkit/direct-bin/xdg-open
install -m 755 "$SYS/uninstall-root.sh" /usr/local/lib/vpnkit/uninstall-root.sh
# What an AI agent follows when the user picks "Troubleshoot with AI" (vpn-diagnose).
install -d -m 755 /usr/local/lib/vpnkit/skills/diagnose-vpn
install -m 644 "$SYS/skills/diagnose-vpn/SKILL.md" /usr/local/lib/vpnkit/skills/diagnose-vpn/SKILL.md
for f in "$SYS"/bin/*; do
  t="/usr/local/bin/$(basename "$f")"
  # Only with --move-aside (checked above): a file of someone else's is kept.
  if [[ -e "$t" || -L "$t" ]] && ! vpnkit_owned_bin "$t"; then
    install -d -m 755 "$VPNKIT_ASIDE"
    dest="$VPNKIT_ASIDE/$(basename "$f")"
    [[ -e "$dest" || -L "$dest" ]] && dest="$dest.$STAMP"
    mv -f -- "$t" "$dest"
    echo "    moved $t (not the kit's) to $dest; the uninstaller puts it back"
  fi
  install -m 755 "$f" "$t"
done

# shellcheck disable=SC1091
. /usr/local/lib/vpnkit/common.sh
# shellcheck disable=SC1091
. /usr/local/lib/vpnkit/direct.sh
# shellcheck disable=SC1091
. /usr/local/lib/vpnkit/ipv6.sh

# --------------------------------------------------------------- sudoers ---
say "Installing the sudoers rules (validated before install)"
tmp=$(mktemp)
sed "s/@USER@/$RUN_USER/g" "$SYS/sudoers.d/99-vpnkit" > "$tmp"
# NEVER install an unvalidated sudoers file: a syntax error locks sudo.
visudo -c -f "$tmp" >/dev/null || { rm -f "$tmp"; echo "generated sudoers file is invalid - aborting"; exit 1; }
# Rules in /etc/sudoers.d apply in file-name order and the last match wins, so
# this file sorts late: a "%wheel ALL=(ALL) ALL" rule in an earlier file must
# not turn these passwordless rules back into password prompts.
install -m 440 -o root -g root "$tmp" /etc/sudoers.d/99-vpnkit
rm -f /etc/sudoers.d/10-vpnkit   # the name used before 0.1.0
rm -f "$tmp"

# ----------------------------------------------------------------- ipv6 ----
# Saving, clearing and restoring a profile's IPv6 settings: lib/ipv6.sh, the
# same code uninstall-root.sh --restore-ipv6 uses.
# A kernel started with ipv6.disable=1 has no IPv6 at all: no sysctl keys to
# set (sysctl would fail on them), and nothing to switch off now.
v6_kernel() { [[ -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ]]; }
NET_TOUCHED=1
if [[ "${DISABLE_IPV6:-1}" == "1" ]]; then
  say "Disabling IPv6 (loopback keeps ::1)"
  [[ -e /etc/sysctl.d/99-vpnkit-disable-ipv6.conf ]] || V6_SYSCTL_NEW=1
  install -m 644 "$SYS/sysctl.d/99-vpnkit-disable-ipv6.sysctl" /etc/sysctl.d/99-vpnkit-disable-ipv6.conf
  if v6_kernel; then
    sysctl -q -p /etc/sysctl.d/99-vpnkit-disable-ipv6.conf
  else
    echo "    this kernel has no IPv6 (started with ipv6.disable=1): nothing to switch off now"
  fi
  # NetworkManager re-enables IPv6 on a link whenever it activates a profile
  # whose ipv6.method is not "disabled", so the saved profiles have to agree
  # with the sysctl. This takes effect on their next activation; the running
  # link is already covered by the sysctl above.
  # NetworkManager refuses method=disabled while the profile still carries
  # static IPv6 settings (e.g. ipv6.dns, which Omarchy's DNS picker sets), so
  # v6_disable_profile clears them in the same call, after saving all of them
  # (method, dns, dns-search, addresses, gateway, routes) in V6_SAVED. A
  # profile it cannot save or change is left exactly as it was.
  V6_FAILED=(); V6_DONE=()
  # By uuid: names may contain colons (escaped by -g) and need not be unique.
  while IFS=: read -r uuid type; do
    case "$type" in
      802-3-ethernet|802-11-wireless)
        [[ "$(v6_get "$uuid" ipv6.method)" != "disabled" ]] || continue
        name=$(v6_get "$uuid" connection.id) || name="$uuid"
        if v6_disable_profile "$uuid"; then
          WIRED_V6+=("$uuid"); V6_DONE+=("$name")
        else
          V6_FAILED+=("$name")
        fi
        ;;
    esac
  done < <(nmcli -g UUID,TYPE connection show)
  if (( ${#V6_FAILED[@]} )); then
    warn "Could not set ipv6.method=disabled on: ${V6_FAILED[*]} (left unchanged)"
    warn "IPv6 is off now (sysctl), but NetworkManager may turn it back on for that link"
    warn "when it reconnects. Fix: nmcli connection modify \"<name>\" ipv6.method disabled"
  fi
  if (( ${#WIRED_V6[@]} )); then
    echo "    ipv6.method=disabled on: ${V6_DONE[*]}"
    # Apply it to the running link too, without taking the link down; else
    # NetworkManager keeps trying to add IPv6 addresses and logs every try.
    for uuid in "${WIRED_V6[@]}"; do v6_reapply "$uuid"; done
  fi
else
  # DISABLE_IPV6=0 (or --keep-ipv6): IPv6 stays on, or comes back if an
  # earlier setup switched it off. The same restore as uninstall --restore-ipv6.
  say "Keeping IPv6 on (DISABLE_IPV6=0)"
  if [[ -e /etc/sysctl.d/99-vpnkit-disable-ipv6.conf ]]; then
    rm -f /etc/sysctl.d/99-vpnkit-disable-ipv6.conf
    if v6_kernel; then
      sysctl -qw net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0
    fi
    echo "    removed the sysctl file an earlier setup installed; IPv6 is on again"
  fi
  if [[ -s "$V6_SAVED" ]]; then
    if v6_restore_saved; then
      rm -f "$V6_SAVED"
      echo "    put back the IPv6 settings saved by an earlier setup"
    else
      warn "Some profiles keep IPv6 off (named above); their settings stay in $V6_SAVED."
      INCOMPLETE+=("giving IPv6 back to every profile")
    fi
  fi
fi

# ------------------------------------------------------------ global DNS ---
# A global DNS setting (NetworkManager [global-dns], or DNS= in resolved.conf;
# Omarchy's "omarchy dns Cloudflare|Google|Custom" writes both) overrides the
# DNS of every connection, the VPN's included, so its resolver is never used.
# Not changed here: it is the user's choice, and the normal connection may rely
# on it. Said loudly, because the leak check fails on it.
# Informational only: without systemd-resolved there is nothing to report.
gdns=$(resolvectl dns 2>/dev/null | sed -n 's/^Global: *//p') || gdns=""
if [[ -n "${gdns// /}" ]]; then
  warn "Global DNS servers are set: $gdns"
  warn "They override the VPN's DNS while a server is selected (the leak check fails on this)."
  warn "Fix: set DNS per connection (nmcli connection modify \"<name>\" ipv4.dns \"...\"), then remove"
  warn "the global setting: /etc/NetworkManager/conf.d/*.conf [global-dns], and DNS= in"
  warn "/etc/systemd/resolved.conf. README: \"DNS and Omarchy's DNS setting\"."
fi

# ------------------------------------------------------- dispatcher hook ---
say "Installing the NetworkManager hook (arms the kill switch, reconnects after resume)"
install -d -m 755 /etc/NetworkManager/dispatcher.d
install -m 755 -o root -g root "$SYS/dispatcher.d/50-vpnkit" /etc/NetworkManager/dispatcher.d/50-vpnkit

# --------------------------------------------------------------- systemd ---
say "Installing qbt-netns.service, ff-netns.service and the units of Chrome direct and SSH direct"
install -m 644 "$SYS/systemd/qbt-netns.service" /etc/systemd/system/qbt-netns.service
# The Firefox tunnel is opt-in: its unit is installed, but enabled only below
# once a Firefox server has been chosen (FF_CONF exists).
install -m 644 "$SYS/systemd/ff-netns.service" /etc/systemd/system/ff-netns.service
# Chrome direct and SSH direct are opt-in: their units are installed, but only
# `vpnkit-direct on` or `vpnkit-direct ssh on` enables them. When one is
# already on, the rules are loaded again in place (a restart would recreate
# the slice and end a Chrome running in it).
install -m 644 "$SYS/systemd/vpnkitdirect.slice" /etc/systemd/system/vpnkitdirect.slice
install -m 644 "$SYS/systemd/vpnkit-direct.service" /etc/systemd/system/vpnkit-direct.service
systemctl daemon-reload
if vpnkit_direct_any_on; then
  systemctl enable vpnkit-direct.service >/dev/null \
    || { warn "Chrome direct / SSH direct: could not enable vpnkit-direct.service; it will not come back after a reboot"
         INCOMPLETE+=("enabling vpnkit-direct.service"); }
  if systemctl is-active --quiet vpnkit-direct.service; then
    /usr/local/bin/vpnkit-direct-rules up || warn "Chrome direct / SSH direct: reloading their rules failed"
  else
    systemctl start vpnkit-direct.service || warn "vpnkit-direct.service failed to start: journalctl -u vpnkit-direct.service"
  fi
fi

# ------------------------------------------------------------ drop folder --
say "Reading the drop folder: $CONFIG_DIR"
/usr/local/bin/vpnkit-sync sync | jq -r '
  (.imported[] | "    imported: \(.)"),
  (if .torrent != "" then "    torrent tunnel: \(.torrent)" else empty end),
  (if (.firefox // "") != "" then "    Firefox tunnel: \(.firefox)" else empty end),
  (.skipped[] | "    skipped: \(.file): \(.reason)")' || true

# Before 0.1.0 the torrent config was not a server of its own. Make it one, so
# it shows in the panel and can be swapped like any other.
if [[ -r "$QBT_CONF" && ! -s /etc/vpnkit/torrent-server ]]; then
  if name=$(/usr/local/bin/vpnkit-import "$QBT_CONF" 2>/dev/null | sed -n 's/^imported: //p') && [[ -n "$name" ]]; then
    printf '%s\n' "$name" > /etc/vpnkit/torrent-server; chmod 644 /etc/vpnkit/torrent-server
    echo "    the torrent config is now the server $name"
  fi
fi

if [[ -r "$QBT_CONF" ]]; then
  systemctl enable qbt-netns.service >/dev/null \
    || { warn "could not enable qbt-netns.service: the torrent tunnel would not start at boot"
         INCOMPLETE+=("enabling qbt-netns.service"); }
  # Leave a running namespace alone: rebuilding it would cut a running
  # qBittorrent off from the network.
  # (Tested on its file, not with `ip netns list | grep -q`: under pipefail
  # that pipeline can fail when grep quits early.)
  if [[ ! -e "/run/netns/$NS" ]]; then
    systemctl restart qbt-netns.service || warn "qbt-netns.service failed to start: journalctl -u qbt-netns.service"
  fi
else
  echo "    no torrent tunnel yet: put one config in $CONFIG_DIR/torrent and press Refresh"
fi

# The Firefox tunnel: only for a user who chose a Firefox server. Without one,
# nothing here touches Firefox.
if [[ -r "$FF_CONF" ]]; then
  systemctl enable ff-netns.service >/dev/null \
    || { warn "could not enable ff-netns.service: the Firefox tunnel would not start at boot"
         INCOMPLETE+=("enabling ff-netns.service"); }
  # Leave a running namespace alone: rebuilding it would cut a running
  # Firefox off from the network.
  if ! [[ -e "/run/netns/$FF_NS" ]]; then
    systemctl restart ff-netns.service || warn "ff-netns.service failed to start: journalctl -u ff-netns.service"
  fi
fi

# ------------------------------------------------- did the internet survive -
connectivity_check || exit 1

if (( ${#INCOMPLETE[@]} )); then
  warn "Setup is not finished. These steps failed (see above):"
  printf '    %s\n' "${INCOMPLETE[@]}"
  warn "Fix the cause and run setup again; the panel keeps offering it."
  exit 1
fi

# The last step: the version stamp says the whole run succeeded.
install -m 644 "$SRC/VERSION" /usr/local/lib/vpnkit/VERSION
say "System part $(cat /usr/local/lib/vpnkit/VERSION) installed"
