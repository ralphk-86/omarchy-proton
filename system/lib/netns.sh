# shellcheck shell=bash
# ============================================================================
#  netns.sh - build and tear down a network namespace containing ONLY a
#             WireGuard tunnel, for one app to run inside.
#
#  Installed to /usr/local/lib/vpnkit/netns.sh. Sourced, after common.sh, by
#  the scripts that build a tunnel namespace (qbt-netns-up, qbt-netns-down).
#  Root only. Defines functions and nothing else: sourcing it changes nothing.
#  The callers set a fixed PATH before sourcing anything.
#
#  WHY THIS DESIGN:
#  A network namespace has its own routing table, its own interfaces and its
#  own /etc/resolv.conf. If the WireGuard interface is not up inside it, the
#  namespace has NO default route and NO reachable resolver - so nothing can
#  escape, including DNS. Leaks are not "filtered", they are impossible,
#  because there is no path out other than the tunnel.
#
#  This is independent of the desktop VPN connection, so that can be toggled
#  freely without ever exposing the app inside.
#
#  Log lines go through the caller's log() (qbt-netns-up prints "[qbt-netns]").
# ============================================================================

_vpnkit_netns_log() {
  if declare -F log >/dev/null; then log "$@"; else echo "[vpnkit-netns] $*"; fi
}

# vpnkit_netns_up <ns> <wg_if> <conf> <guard_table>
#   Builds namespace <ns> whose only way out is WireGuard interface <wg_if>,
#   configured from <conf>, with the nftables table `inet <guard_table>` inside
#   it. Exits the calling script non-zero on any failure: call it as a plain
#   statement from a script running under `set -e`, never inside `if`, `&&`,
#   `||` or `!` (bash switches errexit off for the whole function there, and a
#   failing step would no longer stop the build). The temporary files (the
#   resolver files before they are moved into place, the key files) are made
#   and removed in subshells with their own EXIT traps, so a caller's EXIT trap
#   is never replaced.
vpnkit_netns_up() {
  local ns="${1:-}" wg_if="${2:-}" conf="${3:-}" guard="${4:-}"
  local ADDRESS DNS PRIVKEY PEERKEY ENDPOINT ALLOWED PSK a
  local -a ADDRS

  # Fail closed on a bad call. <ns> ends up in a path (/etc/netns/<ns>);
  # <wg_if> is an interface name (at most 15 characters) and is written into
  # the nftables rules below; <guard_table> is an nftables table name. Each is
  # checked to be exactly that. (An empty <conf> fails the check after this.)
  if [[ ! "$ns" =~ ^[A-Za-z0-9._-]{1,32}$ || "$ns" == . || "$ns" == .. \
        || ! "$wg_if" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,14}$ \
        || ! "$guard" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    _vpnkit_netns_log "ERROR: vpnkit_netns_up needs <ns> <wg_if> <conf> <guard_table>."
    exit 1
  fi

  if [[ ! -r "$conf" ]]; then
    _vpnkit_netns_log "ERROR: $conf not found."
    _vpnkit_netns_log "Download a WireGuard config from your provider, save it there as"
    _vpnkit_netns_log "$(basename "$conf"), and chmod 600 it."
    exit 1
  fi

  # --- parse the config -----------------------------------------------------
  # We configure the interface by hand rather than using wg-quick, because
  # wg-quick cannot place an interface inside a namespace.
  ADDRESS=$(vpnkit_wg_get "$conf" interface Address)
  DNS=$(vpnkit_wg_get "$conf" interface DNS)
  PRIVKEY=$(vpnkit_wg_get "$conf" interface PrivateKey)
  PEERKEY=$(vpnkit_wg_get "$conf" peer PublicKey)
  ENDPOINT=$(vpnkit_wg_get "$conf" peer Endpoint)
  ALLOWED=$(vpnkit_wg_get "$conf" peer AllowedIPs)
  PSK=$(vpnkit_wg_get "$conf" peer PresharedKey)

  : "${ALLOWED:=0.0.0.0/0,::/0}"
  : "${DNS:=$FALLBACK_DNS}"
  ALLOWED=${ALLOWED// /}

  if [[ -z "$ADDRESS" || -z "$PRIVKEY" || -z "$PEERKEY" || -z "$ENDPOINT" ]]; then
    _vpnkit_netns_log "ERROR: could not parse $conf (need Address, PrivateKey, peer PublicKey, Endpoint)."
    exit 1
  fi

  # --- tear down any previous state (idempotent) ----------------------------
  vpnkit_netns_down "$ns" "$wg_if"

  # --- namespace-local DNS: written BEFORE the namespace has any route -------
  # `ip netns exec` bind-mounts /etc/netns/<ns>/* over /etc for the process it
  # starts, but only the files that exist at that moment, and a running process
  # keeps those mounts for life. So the resolver files must be complete before
  # the tunnel has a default route (the launcher, e.g. qbt-launch, starts the
  # app as soon as it sees one): otherwise an app entering in between would
  # keep the host's nsswitch.conf, whose `resolve` module reaches
  # systemd-resolved over a Unix socket and resolves outside the tunnel. Each
  # file is written to a temporary name and renamed into place, so a reader
  # never sees a partial file.
  #
  # resolv.conf: processes inside the namespace read /etc/netns/<ns>/resolv.conf
  # as their /etc/resolv.conf. Pointing it at the in-tunnel resolver means DNS
  # is only reachable THROUGH the tunnel. No tunnel, no DNS. No leak.
  mkdir -p "/etc/netns/$ns"
  # Temporary files live next to the folder, not in it: `ip netns exec`
  # bind-mounts every entry of /etc/netns/<ns>/ over /etc. Same filesystem, so
  # the renames are atomic. A subshell, so its EXIT trap (the temporary folder
  # is not left behind when a step fails) is its own.
  (
    NSDNS_TMP=$(mktemp -d "/etc/netns/.vpnkit-$ns.XXXXXX")
    trap 'rm -rf "$NSDNS_TMP"' EXIT
    {
      echo "# In-tunnel DNS. Only reachable via the WireGuard tunnel."
      echo "# No tunnel => no resolver => no DNS leak, by construction."
      for d in ${DNS//,/ }; do
        [[ "$d" == *:* && "${DISABLE_IPV6:-1}" == "1" ]] && continue
        echo "nameserver $d"
      done
      echo "options edns0 trust-ad"
    } > "$NSDNS_TMP/resolv.conf"

    # --- CRITICAL: namespace-local nsswitch.conf ----------------------------
    # Without `resolve` and `mdns`: systemd-resolved answers over a Unix
    # socket, which a network namespace does not isolate (see
    # vpnkit_ns_nsswitch). glibc then speaks plain DNS to the nameservers in
    # the namespace's resolv.conf, which are only reachable through the
    # tunnel. No tunnel => no DNS.
    vpnkit_ns_nsswitch > "$NSDNS_TMP/nsswitch.conf"
    chmod 644 "$NSDNS_TMP/resolv.conf" "$NSDNS_TMP/nsswitch.conf"
    mv -f "$NSDNS_TMP/nsswitch.conf" "/etc/netns/$ns/nsswitch.conf"
    mv -f "$NSDNS_TMP/resolv.conf" "/etc/netns/$ns/resolv.conf"
    rmdir "$NSDNS_TMP"; trap - EXIT
  )
  if ! vpnkit_resolver_safe "/etc/netns/$ns"; then
    _vpnkit_netns_log "ERROR: the namespace resolver files in /etc/netns/$ns are not safe - not building the tunnel."
    exit 1
  fi

  # --- build the namespace --------------------------------------------------
  _vpnkit_netns_log "creating namespace $ns"
  ip netns add "$ns"
  if [[ "${DISABLE_IPV6:-1}" == "1" && -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ]]; then
    # A fresh namespace starts from the kernel's defaults, not the host's
    # sysctl, so IPv6 has to be switched off here as well. (A kernel started
    # with ipv6.disable=1 has no IPv6 and no such keys: nothing to switch off.)
    ip netns exec "$ns" sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
  fi
  ip -n "$ns" link set lo up

  # --- default-deny firewall INSIDE the namespace ---------------------------
  # Belt and braces. The namespace already contains only lo and the WireGuard
  # interface, so there is no other path out. This ruleset guarantees that even
  # if some other interface ever appeared inside the namespace, traffic still
  # could not use it: egress is permitted ONLY via the tunnel or loopback.
  # Loaded before the tunnel interface is moved in (interfaces are matched by
  # name, so it need not exist yet): there is never a moment without it.
  ip netns exec "$ns" nft -f - <<NFT
table inet $guard {
    chain output {
        type filter hook output priority filter; policy drop;
        oifname "lo"      accept
        oifname "$wg_if"  accept
    }
    chain input {
        type filter hook input priority filter; policy drop;
        iifname "lo"      accept
        iifname "$wg_if"  accept
        ct state established,related accept
    }
}
NFT
  _vpnkit_netns_log "in-namespace firewall active (egress only via $wg_if)"

  # Create the WireGuard interface in the ROOT namespace (so it can reach the
  # internet to establish the tunnel), then move it into the namespace. The
  # encrypted socket stays bound to the root namespace - this is the standard
  # WireGuard netns pattern and is what makes the isolation airtight.
  _vpnkit_netns_log "creating wireguard interface $wg_if"
  ip link add "$wg_if" type wireguard

  # The key files exist only inside this subshell; its EXIT trap removes them
  # whether `wg set` succeeds or not.
  (
    KEYDIR=$(mktemp -d); chmod 700 "$KEYDIR"
    trap 'rm -rf "$KEYDIR"' EXIT
    printf '%s\n' "$PRIVKEY" > "$KEYDIR/key"
    WG_ARGS=(private-key "$KEYDIR/key")
    # The mark makes the desktop VPN's policy routing skip this tunnel's
    # encrypted packets, so the tunnel always rides the normal connection
    # directly.
    [[ -n "${VPN_FWMARK:-}" && "$VPN_FWMARK" != "0" ]] && WG_ARGS+=(fwmark "$VPN_FWMARK")
    WG_ARGS+=(peer "$PEERKEY" endpoint "$ENDPOINT" allowed-ips "$ALLOWED" persistent-keepalive 25)
    if [[ -n "$PSK" ]]; then
      printf '%s\n' "$PSK" > "$KEYDIR/psk"
      WG_ARGS+=(preshared-key "$KEYDIR/psk")
    fi
    wg set "$wg_if" "${WG_ARGS[@]}"
  )

  _vpnkit_netns_log "moving $wg_if into $ns"
  ip link set "$wg_if" netns "$ns"

  # --- address and routes inside the namespace ------------------------------
  # IPv6 addresses are skipped when DISABLE_IPV6=1. An absent IPv6 stack
  # cannot leak.
  IFS=',' read -ra ADDRS <<< "$ADDRESS"
  for a in "${ADDRS[@]}"; do
    a=$(echo "$a" | tr -d ' ')
    [[ -z "$a" ]] && continue
    if [[ "$a" == *:* && "${DISABLE_IPV6:-1}" == "1" ]]; then
      _vpnkit_netns_log "skipping IPv6 address $a (IPv6 disabled)"
      continue
    fi
    ip -n "$ns" addr add "$a" dev "$wg_if"
  done

  ip -n "$ns" link set "$wg_if" up
  ip -n "$ns" route add default dev "$wg_if"

  _vpnkit_netns_log "namespace $ns is up"
  ip netns exec "$ns" ip -brief addr show
}

# vpnkit_netns_down <ns> <wg_if>
#   Deletes the namespace (which destroys the WireGuard interface inside it)
#   and an interface of that name left in the root namespace. Never fails.
vpnkit_netns_down() {
  [[ -n "${1:-}" ]] && { ip netns del "$1" 2>/dev/null || true; }
  [[ -n "${2:-}" ]] && { ip link del "$2" 2>/dev/null || true; }
  return 0
}
