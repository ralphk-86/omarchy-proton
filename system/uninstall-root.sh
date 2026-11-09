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

RESTORE_V6=0; PURGE=0; RC=0
for a in "$@"; do
  case "$a" in
    --restore-ipv6) RESTORE_V6=1 ;;
    --purge)        PURGE=1 ;;
  esac
done

PREFIX="vpn"; QBT_CONF=""; DIRECT_FWMARK=51821; DIRECT_STATE=/etc/vpnkit/direct-apps
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
# Chrome direct: stopping the slice ends what still runs in it. A unit that
# will not go is reported (and the exit code says so); its rules are removed
# below in any case.
if systemctl cat vpnkit-direct.service >/dev/null 2>&1; then
  systemctl disable --now vpnkit-direct.service >/dev/null || { echo "could not stop and disable vpnkit-direct.service"; RC=1; }
fi
systemctl stop vpnkitdirect.slice 2>/dev/null || true
nft delete table inet vpnkit_direct 2>/dev/null || true
while ip -4 rule del priority 90 fwmark "$DIRECT_FWMARK" table main 2>/dev/null; do :; done
while ip -4 rule del priority 89 fwmark "$DIRECT_FWMARK" to 100.64.0.0/10 table 52 2>/dev/null; do :; done
rm -f /etc/systemd/system/vpnkit-direct.service /etc/systemd/system/vpnkitdirect.slice "$DIRECT_STATE"
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
         vpnkit-import vpnkit-killswitch vpnkit-sync vpnkit-pick vpnkit-direct vpnkit-direct-rules \
         vpn-direct direct-launch google-chrome-stable \
         vpn-status vpn-toggle vpn-import vpn-verify vpn-check vpn-rescue vpn-diagnose; do
  rm -f "/usr/local/bin/$f"
done
rm -rf /etc/netns/qbtvpn /etc/vpnkit/providers
# Your settings survive a plain uninstall, so a reinstall behaves the same.
# Before --purge removes /etc/vpnkit: ipv6-profiles.saved holds each profile's
# IPv6 settings from before the install (method, dns, dns-search).
if (( RESTORE_V6 )); then
  V6_SAVED=/etc/vpnkit/ipv6-profiles.saved
  rm -f /etc/sysctl.d/99-vpnkit-disable-ipv6.conf
  sysctl -qw net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0
  while IFS=: read -r name type; do
    case "$type" in
      802-3-ethernet|802-11-wireless)
        saved=""; method="auto"; dns=""; search=""
        [[ -f "$V6_SAVED" ]] && saved=$(awk -F'\t' -v n="$name" '$1 == n { print; exit }' "$V6_SAVED")
        if [[ -n "$saved" ]]; then
          IFS=$'\t' read -r _ method dns search <<< "$saved"
          [[ -n "$method" && "$method" != "disabled" ]] || method="auto"
        fi
        nmcli connection modify "$name" ipv6.method "$method" ipv6.dns "$dns" ipv6.dns-search "$search" \
          || nmcli connection modify "$name" ipv6.method auto || true
        ;;
    esac
  done < <(nmcli -t -f NAME,TYPE connection show)
  rm -f "$V6_SAVED"
  echo "IPv6 re-enabled; reconnect the network (or reboot) for addresses to come back."
fi

(( PURGE )) && rm -rf /etc/vpnkit
rm -f /etc/sudoers.d/99-vpnkit /etc/sudoers.d/10-vpnkit

rm -rf /usr/local/lib/vpnkit
echo "vpnkit system part removed."
exit "$RC"
