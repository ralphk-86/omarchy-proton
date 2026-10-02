#!/usr/bin/env bash
# ============================================================================
#  uninstall-root.sh - remove the system part of vpnkit. Called by
#  ../uninstall.sh; a copy lives at /usr/local/lib/vpnkit/uninstall-root.sh so
#  it still works after the plugin folder is gone.
#
#  Usage: uninstall-root.sh [--restore-ipv6] [--purge]
#    --purge  also delete the WireGuard configs and the VPN servers
# ============================================================================
set -uo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/bin"
[[ $EUID -eq 0 ]] || { echo "must run as root"; exit 1; }

RESTORE_V6=0; PURGE=0
for a in "$@"; do
  case "$a" in
    --restore-ipv6) RESTORE_V6=1 ;;
    --purge)        PURGE=1 ;;
  esac
done

PREFIX="vpn"; QBT_CONF=""
if [[ -r /usr/local/lib/vpnkit/common.sh ]]; then
  # shellcheck disable=SC1091
  . /usr/local/lib/vpnkit/common.sh
  PREFIX="$PROFILE_PREFIX"
fi

nft delete table inet vpnkit_kill 2>/dev/null || true
rm -rf /run/vpnkit /run/qbt-netns-exit-ip
rm -f /etc/NetworkManager/dispatcher.d/50-vpnkit
systemctl disable --now qbt-netns.service 2>/dev/null || true
rm -f /etc/systemd/system/qbt-netns.service
systemctl daemon-reload

if (( PURGE )); then
  while IFS=: read -r name type; do
    [[ "$type" == "wireguard" && "$name" == "$PREFIX"-* ]] || continue
    nmcli connection delete "$name" >/dev/null 2>&1 && echo "removed server $name"
    rm -f "/etc/wireguard/$name.conf"
  done < <(nmcli -t -f NAME,TYPE connection show)
  [[ -n "$QBT_CONF" ]] && rm -f "$QBT_CONF" "$QBT_CONF".bak.*
  rm -f /etc/vpnkit/torrent-server
fi

for f in qbt-netns-up qbt-netns-down qbt-netns-status qbt-launch qbittorrent \
         vpnkit-import vpnkit-killswitch vpnkit-sync vpnkit-pick \
         vpn-status vpn-toggle vpn-import vpn-verify vpn-check vpn-rescue vpn-diagnose; do
  rm -f "/usr/local/bin/$f"
done
rm -rf /etc/netns/qbtvpn /etc/vpnkit/providers
# Your settings survive a plain uninstall, so a reinstall behaves the same.
(( PURGE )) && rm -rf /etc/vpnkit
rm -f /etc/sudoers.d/99-vpnkit /etc/sudoers.d/10-vpnkit

if (( RESTORE_V6 )); then
  rm -f /etc/sysctl.d/99-vpnkit-disable-ipv6.conf
  sysctl -qw net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0
  while IFS=: read -r name type; do
    case "$type" in
      802-3-ethernet|802-11-wireless) nmcli connection modify "$name" ipv6.method auto || true ;;
    esac
  done < <(nmcli -t -f NAME,TYPE connection show)
  echo "IPv6 re-enabled; reconnect the network (or reboot) for addresses to come back."
fi
rm -rf /usr/local/lib/vpnkit
echo "vpnkit system part removed."
