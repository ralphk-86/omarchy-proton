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
# The IPv6 save/restore code install-root.sh uses: next to this script, from
# the plugin folder (system/lib/) or from the installed copy.
V6_LIB=""
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for f in "$HERE/lib/ipv6.sh" "$HERE/ipv6.sh"; do
  [[ -r "$f" ]] && { V6_LIB="$f"; break; }
done
V6_KEEP=0   # IPv6 settings still saved that only the user has: --purge keeps them

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
# ipv6-profiles.saved holds each profile's IPv6 settings from before the
# install (lib/ipv6.sh says what and how).
V6_SAVED=/etc/vpnkit/ipv6-profiles.saved
if (( RESTORE_V6 )); then
  rm -f /etc/sysctl.d/99-vpnkit-disable-ipv6.conf
  sysctl -qw net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0
  if [[ -z "$V6_LIB" ]]; then
    echo "[!] IPv6: lib/ipv6.sh is missing, so no profile was changed; their saved settings stay in $V6_SAVED."
    RC=1
  else
    # shellcheck disable=SC1090
    . "$V6_LIB"
    # Only the profiles the install changed (the ones saved), each applied to
    # its running link; profiles it never changed are left alone.
    if v6_restore_saved; then
      rm -f "$V6_SAVED"
    else
      echo "[!] IPv6 could not be restored on every profile (named above); kept $V6_SAVED."
      RC=1
    fi
  fi
  echo "IPv6 re-enabled."
fi
# Saved IPv6 settings not put back are the only copy of what the install
# cleared (static addresses, gateway, routes): even --purge keeps them (with
# ipv6-profiles.superseded, the entries later installs replaced).
[[ -s "$V6_SAVED" ]] && V6_KEEP=1

if (( PURGE )); then
  if (( V6_KEEP )); then
    find /etc/vpnkit -mindepth 1 -maxdepth 1 ! -name 'ipv6-profiles.saved' ! -name 'ipv6-profiles.superseded' \
      -exec rm -rf {} +
    echo "[!] Kept /etc/vpnkit/ipv6-profiles.saved: your profiles' IPv6 settings from before the"
    echo "    install, not put back (no --restore-ipv6). IPv6 stays off on those profiles. To put them"
    echo "    back, run uninstall.sh --restore-ipv6 from the plugin folder BEFORE removing the plugin:"
    echo "    after 'omarchy plugin remove' nothing on this machine can read that file."
  else
    rm -rf /etc/vpnkit
  fi
fi
rm -f /etc/sudoers.d/99-vpnkit /etc/sudoers.d/10-vpnkit

rm -rf /usr/local/lib/vpnkit
echo "vpnkit system part removed."
exit "$RC"
