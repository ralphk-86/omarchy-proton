#!/usr/bin/env bash
# ============================================================================
#  uninstall-root.sh - remove the system part of vpnkit. Called by
#  ../uninstall.sh; a copy lives at /usr/local/lib/vpnkit/uninstall-root.sh so
#  it still works after the plugin folder is gone.
#
#  Usage: uninstall-root.sh [--restore-ipv6] [--purge]
#    --restore-ipv6  turn IPv6 back on and put back the saved profile settings
#    --purge         also delete the kit's servers, the WireGuard configs and
#                    /etc/vpnkit
#
#  Removes what it can even when a step fails: each failure is reported, and
#  the exit code is then 1. Only what is the kit's is removed: the servers it
#  imported (by their uuid), the commands it installed (by their marker line),
#  its launcher entries (removed as the desktop user, never as root). Files
#  of yours that setup moved aside are put back.
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
fail() { echo "[!] $*"; RC=1; }

# Next to this script: from the plugin folder (system/lib/), or the installed
# copy (/usr/local/lib/vpnkit/).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib() {  # lib <name>: the first readable copy of a library, or nothing
  local f
  for f in "$HERE/lib/$1" "$HERE/$1" "/usr/local/lib/vpnkit/$1"; do
    [[ -r "$f" ]] && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}

NS="qbtvpn"; QBT_CONF=""; TARGET_USER=""; TARGET_HOME=""; DIRECT_FWMARK=51821; DIRECT_STATE=/etc/vpnkit/direct-apps
COMMON=$(lib common.sh) || COMMON=""
if [[ -n "$COMMON" ]]; then
  # shellcheck disable=SC1090
  . "$COMMON"
fi
V6_LIB=$(lib ipv6.sh) || V6_LIB=""
OWNED_LIB=$(lib owned.sh) || OWNED_LIB=""
VPNKIT_ASIDE=/usr/local/lib/vpnkit/moved-aside
if [[ -n "$OWNED_LIB" ]]; then
  # shellcheck disable=SC1090
  . "$OWNED_LIB"
fi
V6_KEEP=0   # IPv6 settings still saved that only the user has: kept, even by --purge

# kit_servers [--active]: "uuid name" of each server the kit imported: a
# WireGuard profile whose uuid is the one vpnkit-import derives from its name
# (any prefix). A profile of your own, even with the same prefix, is not one.
kit_servers() {
  local all line u rest t name
  all=$(nmcli -e no -g UUID,TYPE,NAME connection show "$@" 2>/dev/null) || return 1
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    u=${line%%:*}; rest=${line#*:}; t=${rest%%:*}; name=${rest#*:}
    [[ "$t" == wireguard && "$name" =~ ^[A-Za-z0-9._-]{1,15}$ ]] || continue
    [[ "$u" == "$(uuidgen --sha1 --namespace @dns --name "vpnkit-$name" 2>/dev/null)" ]] || continue
    printf '%s %s\n' "$u" "$name"
  done <<< "$all"
}

# Back to the normal connection first (uninstall.sh did it already, unless
# this runs on its own, after the plugin folder is gone).
rm -f /etc/NetworkManager/dispatcher.d/50-vpnkit
if active=$(kit_servers --active); then
  while read -r u name; do
    [[ -n "$u" ]] || continue
    nmcli connection down uuid "$u" >/dev/null 2>&1 && echo "disconnected $name" || fail "could not disconnect $name"
  done <<< "$active"
else
  fail "could not ask NetworkManager which server is connected"
fi

if nft list table inet vpnkit_kill >/dev/null 2>&1; then
  nft delete table inet vpnkit_kill || fail "could not remove the kill switch (nft table inet vpnkit_kill)"
fi
rm -rf /run/vpnkit /run/qbt-netns-exit-ip
if [[ -e /etc/systemd/system/qbt-netns.service ]]; then
  systemctl disable --now qbt-netns.service >/dev/null 2>&1 || fail "could not stop and disable qbt-netns.service"
fi
rm -f /etc/systemd/system/qbt-netns.service
# Chrome direct: stopping the slice ends what still runs in it. A unit that
# will not go is reported; its rules are removed below in any case.
if systemctl cat vpnkit-direct.service >/dev/null 2>&1; then
  systemctl disable --now vpnkit-direct.service >/dev/null || fail "could not stop and disable vpnkit-direct.service"
fi
systemctl stop vpnkitdirect.slice 2>/dev/null || true
nft delete table inet vpnkit_direct 2>/dev/null || true
while ip -4 rule del priority 90 fwmark "$DIRECT_FWMARK" table main 2>/dev/null; do :; done
while ip -4 rule del priority 89 fwmark "$DIRECT_FWMARK" to 100.64.0.0/10 table 52 2>/dev/null; do :; done
rm -f /etc/systemd/system/vpnkit-direct.service /etc/systemd/system/vpnkitdirect.slice "$DIRECT_STATE"
systemctl daemon-reload || fail "systemctl daemon-reload failed"
# The namespace itself goes with its unit; this is in case the unit was gone.
[[ "$NS" =~ ^[A-Za-z0-9._-]{1,32}$ ]] && ip netns del "$NS" 2>/dev/null

if (( PURGE )); then
  # Only the servers the kit imported (kit_servers): under any prefix, so
  # servers imported under another provider's prefix go too; a profile of
  # your own, even with the same prefix, is left alone.
  if servers=$(kit_servers); then
    while read -r u name; do
      [[ -n "$u" ]] || continue
      if nmcli connection delete uuid "$u" >/dev/null 2>&1; then
        echo "removed server $name"
        rm -f "/etc/wireguard/$name.conf"
      else
        fail "could not remove the server $name"
      fi
    done <<< "$servers"
  else
    fail "could not list NetworkManager's profiles, so no server was removed"
  fi
  [[ -n "$QBT_CONF" ]] && rm -f "$QBT_CONF" "$QBT_CONF".bak.*
  rm -f /etc/vpnkit/torrent-server
fi

# The launcher entries in the desktop user's folder: removed only if they are
# the kit's, and the user's own put back, as the user. Here too, so that
# removing the system part alone (after the plugin folder is gone) leaves no
# entry pointing at a wrapper that is about to be deleted.
if [[ -n "$OWNED_LIB" && -n "$TARGET_USER" && "$TARGET_USER" != root ]] \
   && TH=$(getent passwd "$TARGET_USER" | cut -d: -f6) && [[ -n "$TH" && -d "$TH" ]]; then
  runuser -u "$TARGET_USER" -- env -i HOME="$TH" PATH="$PATH" \
      bash -c '. "$1" && vpnkit_launchers_remove "$2"' _ "$OWNED_LIB" "$TH" \
    || fail "could not remove the launcher entries in $TH/.local/share/applications"
else
  fail "the desktop user is unknown, so the launcher entries in their folder were not checked"
fi

# Commands in /usr/local/bin: only the kit's (lib/owned.sh); files setup moved
# aside (install.sh --move-aside) go back where they were.
for f in qbt-netns-up qbt-netns-down qbt-netns-status qbt-launch qbittorrent \
         vpnkit-import vpnkit-killswitch vpnkit-sync vpnkit-pick vpnkit-direct vpnkit-direct-rules \
         vpn-direct direct-launch google-chrome-stable \
         vpn-status vpn-toggle vpn-import vpn-verify vpn-check vpn-rescue vpn-diagnose; do
  t="/usr/local/bin/$f"
  if [[ -e "$t" || -L "$t" ]]; then
    if [[ -z "$OWNED_LIB" ]]; then
      fail "kept $t: lib/owned.sh is missing, so it cannot be told apart from a file of yours"
      continue
    elif vpnkit_owned_bin "$t"; then
      rm -f -- "$t" || fail "could not remove $t"
    else
      echo "kept $t: it is not omarchy-proton's"
    fi
  fi
  if [[ -n "$OWNED_LIB" && ( -e "$VPNKIT_ASIDE/$f" || -L "$VPNKIT_ASIDE/$f" ) ]]; then
    if [[ -e "$t" || -L "$t" ]]; then
      fail "your $t is still in $VPNKIT_ASIDE: $t is taken"
    elif mv -- "$VPNKIT_ASIDE/$f" "$t"; then
      echo "put your $t back"
    else
      fail "could not put your $t back from $VPNKIT_ASIDE"
    fi
  fi
done
[[ "$NS" =~ ^[A-Za-z0-9._-]{1,32}$ ]] && rm -rf "/etc/netns/$NS"
rm -rf /etc/netns/.vpnkit-* /etc/vpnkit/providers

# Your settings survive a plain uninstall, so a reinstall behaves the same.
# ipv6-profiles.saved holds each profile's IPv6 settings from before the
# install (lib/ipv6.sh says what and how).
V6_SAVED=/etc/vpnkit/ipv6-profiles.saved
if (( RESTORE_V6 )); then
  rm -f /etc/sysctl.d/99-vpnkit-disable-ipv6.conf
  # A kernel started with ipv6.disable=1 has nothing to turn back on.
  if [[ -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ]]; then
    sysctl -qw net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 \
      || fail "could not turn IPv6 back on (sysctl)"
  fi
  if [[ -z "$V6_LIB" ]]; then
    fail "IPv6: lib/ipv6.sh is missing, so no profile was changed; their saved settings stay in $V6_SAVED."
  else
    # shellcheck disable=SC1090
    . "$V6_LIB"
    # Only the profiles the install changed (the ones saved), each applied to
    # its running link; profiles it never changed are left alone.
    if v6_restore_saved; then
      rm -f "$V6_SAVED"
      echo "IPv6 re-enabled."
    else
      fail "IPv6 could not be restored on every profile (see above); kept $V6_SAVED."
    fi
  fi
fi
# Saved IPv6 settings not put back are the only copy of what the install
# cleared (static addresses, gateway, routes): even --purge keeps them (with
# ipv6-profiles.superseded, the lines kept for reference).
[[ -s "$V6_SAVED" ]] && V6_KEEP=1

if (( PURGE )); then
  if (( V6_KEEP )); then
    find /etc/vpnkit -mindepth 1 -maxdepth 1 ! -name 'ipv6-profiles.saved' ! -name 'ipv6-profiles.superseded' \
      -exec rm -rf {} +
  else
    rm -rf /etc/vpnkit
  fi
elif (( ! V6_KEEP )) && [[ -d /etc/vpnkit ]] \
     && [[ -z "$(find /etc/vpnkit -mindepth 1 -maxdepth 1 ! -name 'ipv6-profiles.superseded' -print -quit)" ]]; then
  # An earlier --purge kept only the saved settings, and they are restored now.
  rm -rf /etc/vpnkit
fi
if (( V6_KEEP )); then
  if (( RESTORE_V6 )); then
    echo "[!] Kept $V6_SAVED: the IPv6 settings of the profiles named above, which could not be put back."
  else
    echo "[!] Kept $V6_SAVED: your profiles' IPv6 settings from before the install, not put"
    echo "    back (no --restore-ipv6). IPv6 stays off on those profiles."
  fi
  echo "    To put them back, run uninstall.sh --restore-ipv6 from the plugin folder BEFORE removing the"
  echo "    plugin: once the plugin and this system part are both gone, nothing on this machine reads that file."
fi
rm -f /etc/sudoers.d/99-vpnkit /etc/sudoers.d/10-vpnkit

# Everything of the kit's library folder, except files of yours that could
# not be put back (said above).
if [[ -n "$(ls -A "$VPNKIT_ASIDE" 2>/dev/null)" ]]; then
  find /usr/local/lib/vpnkit -mindepth 1 -maxdepth 1 ! -name "$(basename "$VPNKIT_ASIDE")" -exec rm -rf {} +
  fail "kept $VPNKIT_ASIDE: files of yours that could not be put back"
else
  rm -rf /usr/local/lib/vpnkit
fi
echo "vpnkit system part removed."
exit "$RC"
