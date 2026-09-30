#!/usr/bin/env bash
# ============================================================================
#  install-root.sh - the privileged half of the vpnkit install.
#  Do not run this directly; ../install.sh calls it once through sudo (in a
#  terminal) or pkexec (from the VPN panel).
#
#  Usage: install-root.sh <plugin-dir> <user> [--keep-ipv6]
#
#  Nothing here changes the normal route or the normal DNS, and nothing here
#  connects a VPN. The last step checks that the internet still answers and
#  undoes the network-facing changes if it does not.
# ============================================================================
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/bin"

[ "$(uname -s)" = "Linux" ] || { echo "Linux only"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "must run as root"; exit 1; }

SRC="${1:?plugin dir}"; RUN_USER="${2:?user}"; shift 2
KEEP_V6=0
[[ "${1:-}" == "--keep-ipv6" ]] && KEEP_V6=1
SYS="$SRC/system"
[[ -f "$SYS/lib/common.sh" && -f "$SRC/VERSION" ]] || { echo "no vpnkit under $SRC"; exit 1; }
id "$RUN_USER" >/dev/null 2>&1 || { echo "unknown user $RUN_USER"; exit 1; }
[[ "$RUN_USER" != "root" ]] || { echo "install for your normal user, not root"; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
say()  { printf '==> %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*"; }

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
declare -A PKG=( [wg]=wireguard-tools [nft]=nftables [nmcli]=networkmanager [jq]=jq [curl]=curl
                 [ip]=iproute2 [visudo]=sudo [uuidgen]=util-linux [runuser]=util-linux )
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
# With a kill switch armed and no tunnel, the machine is offline on purpose;
# that is not a reason to refuse an update.
ONLINE_BEFORE=1
internet_ok || ONLINE_BEFORE=0

# ------------------------------------------------------------------ config -
say "Installing configuration to /etc/vpnkit"
install -d -m 755 /etc/vpnkit /etc/vpnkit/providers
for p in "$SRC"/providers/*.preset; do
  install -m 644 "$p" "/etc/vpnkit/providers/$(basename "$p" .preset).conf"
done
if [[ -f /etc/vpnkit/vpnkit.conf ]]; then
  echo "    keeping your /etc/vpnkit/vpnkit.conf"
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
install -m 644 "$SRC/VERSION" /usr/local/lib/vpnkit/VERSION
install -m 755 "$SYS/uninstall-root.sh" /usr/local/lib/vpnkit/uninstall-root.sh
# What an AI agent follows when the user picks "Troubleshoot with AI" (vpn-diagnose).
install -d -m 755 /usr/local/lib/vpnkit/skills/diagnose-vpn
install -m 644 "$SYS/skills/diagnose-vpn/SKILL.md" /usr/local/lib/vpnkit/skills/diagnose-vpn/SKILL.md
for f in "$SYS"/bin/*; do
  install -m 755 "$f" "/usr/local/bin/$(basename "$f")"
done

# shellcheck disable=SC1091
. /usr/local/lib/vpnkit/common.sh

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
WIRED_V6=()   # profiles whose ipv6.method we changed, for rollback
if [[ "${DISABLE_IPV6:-1}" == "1" ]]; then
  say "Disabling IPv6 (loopback keeps ::1)"
  install -m 644 "$SYS/sysctl.d/99-vpnkit-disable-ipv6.sysctl" /etc/sysctl.d/99-vpnkit-disable-ipv6.conf
  sysctl -q -p /etc/sysctl.d/99-vpnkit-disable-ipv6.conf
  # NetworkManager re-enables IPv6 on a link whenever it activates a profile
  # whose ipv6.method is not "disabled", so the saved profiles have to agree
  # with the sysctl. This takes effect on their next activation; the running
  # link is already covered by the sysctl above.
  while IFS=: read -r name type; do
    case "$type" in
      802-3-ethernet|802-11-wireless)
        method=$(nmcli -g ipv6.method connection show "$name" 2>/dev/null || true)
        if [[ "$method" != "disabled" ]]; then
          nmcli connection modify "$name" ipv6.method disabled && WIRED_V6+=("$name")
        fi
        ;;
    esac
  done < <(nmcli -t -f NAME,TYPE connection show)
  if (( ${#WIRED_V6[@]} )); then
    echo "    ipv6.method=disabled on: ${WIRED_V6[*]}"
    # Apply it to the running link too, without taking the link down; else
    # NetworkManager keeps trying to add IPv6 addresses and logs every try.
    for name in "${WIRED_V6[@]}"; do
      dev=$(nmcli -g GENERAL.DEVICES connection show "$name" 2>/dev/null | head -1)
      [[ -n "$dev" ]] && nmcli device reapply "$dev" >/dev/null 2>&1 || true
    done
  fi
else
  echo "    IPv6 left on (DISABLE_IPV6=0)"
  rm -f /etc/sysctl.d/99-vpnkit-disable-ipv6.conf
fi

# ------------------------------------------------------- dispatcher hook ---
say "Installing the NetworkManager hook (arms the kill switch, reconnects after resume)"
install -d -m 755 /etc/NetworkManager/dispatcher.d
install -m 755 -o root -g root "$SYS/dispatcher.d/50-vpnkit" /etc/NetworkManager/dispatcher.d/50-vpnkit

# --------------------------------------------------------------- systemd ---
say "Installing qbt-netns.service"
install -m 644 "$SYS/systemd/qbt-netns.service" /etc/systemd/system/qbt-netns.service
systemctl daemon-reload

# ------------------------------------------------------------ drop folder --
say "Reading the drop folder: $CONFIG_DIR"
/usr/local/bin/vpnkit-sync sync | jq -r '
  (.imported[] | "    imported: \(.)"),
  (if .torrent != "" then "    torrent tunnel: \(.torrent)" else empty end),
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
  systemctl enable qbt-netns.service >/dev/null 2>&1
  # Leave a running namespace alone: rebuilding it would cut a running
  # qBittorrent off from the network.
  if ! ip netns list 2>/dev/null | grep -qw "$NS"; then
    systemctl restart qbt-netns.service || warn "qbt-netns.service failed to start: journalctl -u qbt-netns.service"
  fi
else
  echo "    no torrent tunnel yet: put one config in $CONFIG_DIR/torrent and press Refresh"
fi

# ------------------------------------------------- did the internet survive -
say "Checking that the normal connection still works"
if (( ! ONLINE_BEFORE )); then
  echo "    offline before and after (kill switch holding, or no network) - nothing to compare"
elif internet_ok; then
  echo "    internet OK, default route: $(ip -4 route show default | head -1)"
else
  warn "No internet after the install - undoing the network-facing changes"
  rm -f /etc/sysctl.d/99-vpnkit-disable-ipv6.conf
  sysctl -qw net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 || true
  for name in "${WIRED_V6[@]}"; do nmcli connection modify "$name" ipv6.method auto || true; done
  internet_ok && echo "    internet is back after the rollback" \
              || echo "    STILL no internet - run vpn-rescue, then check the router"
  exit 1
fi

say "System part $(cat /usr/local/lib/vpnkit/VERSION) installed"
