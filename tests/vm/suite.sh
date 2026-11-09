#!/usr/bin/env bash
# ============================================================================
#  suite.sh - the integration suite. Runs INSIDE the test VM as root (see
#  vm.sh). Never run it on a machine you care about: it installs the kit, arms
#  the kill switch, pulls tunnels down and uninstalls everything again.
#
#  The "internet" and the "VPN provider" are simulated inside the VM, so the
#  suite needs no account and every answer is known in advance:
#
#    192.0.2.80:8080    "what is my IP" service. It answers with the address
#                       the request came from, which tells the paths apart:
#                         203.0.113.1   straight out, no VPN (the "home IP")
#                         10.2.0.2      desktop server A (CA#1)
#                         10.3.0.2      desktop server B (SE#2)
#                         10.2.0.3      the torrent tunnel
#    198.51.100.80:8080 the same service on a second address, used as a
#                       BYPASS_CIDRS target
#    10.2.0.1 / 10.3.0.1  the in-tunnel DNS resolvers, the only ones that know
#                       the name only-in-tunnel.test
#
#  All of it lives in a network namespace called "provider", reached over a
#  veth pair, with two WireGuard servers in it (endpoints 203.0.113.2:51820
#  and :51821). After the install, the provider becomes the VM's default
#  gateway, the way a home router is: the services are off-link, reached
#  through the default route, exactly like real websites. (A WireGuard
#  profile only diverts the default route; anything on-link would bypass it
#  and the test would prove nothing.)
# ============================================================================
set -uo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/bin"

[[ $EUID -eq 0 ]] || { echo "run as root inside the test VM"; exit 2; }
[[ "$(uname -n)" == "plugin-test" ]] || { echo "refusing to run outside the test VM (hostname is not plugin-test)"; exit 2; }

PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
U=tester
UHOME=/home/$U
UID_T=$(id -u $U)
DROP="$UHOME/Documents/WireGuard"
HOME_IP=203.0.113.1
LOOKUP="http://192.0.2.80:8080/"
BYPASS_URL="http://198.51.100.80:8080/"

pass=0; fail=0
# SUITE_STOP_BEFORE=<n> ends the run before section n, leaving the VM in that
# state for debugging (with `vm.sh up` and `vm.sh ssh`).
section() {
  if [[ -n "${SUITE_STOP_BEFORE:-}" && "$1" == "$SUITE_STOP_BEFORE."* ]]; then
    printf '\nStopped before section %s as asked.\n' "$SUITE_STOP_BEFORE"; exit 0
  fi
  printf '\n== %s\n' "$*"
}
ok()  { printf '  [PASS] %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  [FAIL] %s\n' "$*"; fail=$((fail+1)); }
# is <description> <actual> <expected>
is()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', expected '$3')"; fi; }
# yes/no <description> <command...>: the command must succeed / must fail
yes() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
no()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }

# Run a command as the desktop user on a terminal, typing the sudo password.
in_terminal() { as_user python3 "$PLUGIN/tests/vm/with-password.py" tester "$@"; }
as_user() { runuser -u $U -- env HOME=$UHOME USER=$U XDG_RUNTIME_DIR=/run/user/$UID_T PATH="$PATH" "$@"; }
myip()    { local a; a=$(curl -4 -s --max-time 3 "$@" "$LOOKUP" 2>/dev/null) || a=""; printf '%s' "${a:-none}"; }
status()  { as_user /usr/local/bin/vpn-status --refresh --json | jq -r "$1"; }
resolves() { timeout 5 getent hosts "$1" >/dev/null 2>&1; }
PHYS=$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')

# ---------------------------------------------------------------------------
section "0. Simulated internet and VPN provider"
ip netns add provider
ip link add veth-h type veth peer name veth-s netns provider
ip addr add 203.0.113.1/24 dev veth-h; ip link set veth-h up
ip -n provider addr add 203.0.113.2/24 dev veth-s
ip -n provider addr add 192.0.2.80/32 dev lo; ip -n provider addr add 198.51.100.80/32 dev lo
ip -n provider link set veth-s up; ip -n provider link set lo up
# The provider as the home router (see the header); switched on after the
# install, which still needs the real internet for packages.
gateway() {
  if [[ "$1" == on ]]; then ip route replace default via 203.0.113.2 dev veth-h metric 50
  else ip route del default via 203.0.113.2 dev veth-h metric 50 2>/dev/null || true; fi
}

# The provider needs the wg tool, but the machine under test must not have it:
# the installer has to notice it is missing and install it. So take a private
# copy of the binary out of the package without installing the package.
pacman -Sy >/dev/null 2>&1
pacman -Sw --noconfirm wireguard-tools >/dev/null 2>&1
bsdtar -xOf "$(ls /var/cache/pacman/pkg/wireguard-tools-*.pkg.tar.zst | head -1)" usr/bin/wg > /tmp/wg-static
chmod 755 /tmp/wg-static
WG=$(mktemp -d)
for k in srvA srvB deskA deskB torrent; do
  /tmp/wg-static genkey > "$WG/$k.key"; /tmp/wg-static pubkey < "$WG/$k.key" > "$WG/$k.pub"
done

mk_server() {  # mk_server <if> <port> <key> <addr> <peer-pub>@<peer-ip>...
  local ifn="$1" port="$2" key="$3" addr="$4"; shift 4
  ip -n provider link add "$ifn" type wireguard
  ip -n provider addr add "$addr" dev "$ifn"
  local p
  ip netns exec provider /tmp/wg-static set "$ifn" listen-port "$port" private-key "$key"
  # "@" separates key and address: base64 keys end in "=".
  for p in "$@"; do ip netns exec provider /tmp/wg-static set "$ifn" peer "${p%@*}" allowed-ips "${p#*@}" || echo "SETUP ERROR: peer $p"; done
  ip -n provider link set "$ifn" up
}
mk_server wgA 51820 "$WG/srvA.key" 10.2.0.1/24 "$(cat $WG/deskA.pub)@10.2.0.2/32" "$(cat $WG/torrent.pub)@10.2.0.3/32"
mk_server wgB 51821 "$WG/srvB.key" 10.3.0.1/24 "$(cat $WG/deskB.pub)@10.3.0.2/32"

cat > /tmp/whoami.py <<'PY'
import http.server, socketserver, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        if self.path == "/endless":      # a hostile lookup server: chunked, never stops
            self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
            try:
                while True: self.wfile.write(b"400\r\n" + b"8" * 1024 + b"\r\n")
            except (BrokenPipeError, ConnectionResetError): pass
            return
        body = self.client_address[0].encode()
        self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True; allow_reuse_address = True
S((sys.argv[1] if len(sys.argv) > 1 else "0.0.0.0", 8080), H).serve_forever()
PY
# Detached from this shell's output, or ssh would wait for them to exit.
ip netns exec provider python3 /tmp/whoami.py </dev/null >/dev/null 2>&1 &
ip netns exec provider dnsmasq --no-daemon --no-resolv --no-hosts --bind-interfaces \
  --listen-address=10.2.0.1 --listen-address=10.3.0.1 --address=/#/192.0.2.7 </dev/null >/dev/null 2>&1 &
# On the machine itself: a resolver on loopback, the stand-in for a local
# ad-blocking resolver (Chrome direct's DIRECT_DNS), knowing one name nobody
# else knows; and the "what is my IP" service on loopback, which shows
# whether loopback traffic keeps its 127.0.0.1 source.
dnsmasq --no-daemon --no-resolv --no-hosts --bind-interfaces --listen-address=127.0.0.1 \
  --address=/direct-only.test/192.0.2.9 </dev/null >/dev/null 2>&1 &
python3 /tmp/whoami.py 127.0.0.1 </dev/null >/dev/null 2>&1 &
sleep 1

conf() {  # conf <file> <key> <addr> <dns> <comment> <server-pub> <port>
  install -d -o $U -g $U -m 700 "$(dirname "$1")"
  cat > "$1" <<EOF
[Interface]
PrivateKey = $(cat "$2")
Address = $3/32, 2a07:b944::2:2/128
DNS = $4, 2a07:b944::2:1

[Peer]
# $5
PublicKey = $(cat "$6")
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 203.0.113.2:$7
PersistentKeepalive = 25
EOF
  chown $U:$U "$1"; chmod 600 "$1"
}
# On a real desktop the user is logged in at the seat, and polkit lets an
# active local session control NetworkManager. The suite's user has no seat
# session, so grant the same NetworkManager rights explicitly, and nothing more.
cat > /etc/polkit-1/rules.d/49-suite-desktop-session.rules <<'JS'
polkit.addRule(function(action, subject) {
  if (subject.user == "tester" && action.id.indexOf("org.freedesktop.NetworkManager.") == 0) {
    return polkit.Result.YES;
  }
});
JS


# ---------------------------------------------------------------------------
section "1. Fresh install through install.sh (a stock machine without wireguard-tools)"
no "wg is not installed yet" command -v wg
# Omarchy's DNS picker puts ipv6.dns on every wired/Wi-Fi profile, and
# NetworkManager then refuses ipv6.method=disabled unless it is cleared in the
# same call (seen on a real install, 0.3.5). Recreate that before installing.
PPROF=$(nmcli -g GENERAL.CONNECTION device show "$PHYS" 2>/dev/null | head -1)
nmcli connection modify "$PPROF" ipv6.method auto ipv6.dns "2606:4700:4700::1111" ipv6.ignore-auto-dns yes
is "the physical profile carries an IPv6 DNS server, as Omarchy's DNS picker leaves it" \
  "$(nmcli -g ipv6.dns connection show "$PPROF" | sed 's/\\:/:/g')" "2606:4700:4700::1111"
# The real path: the user runs install.sh in a terminal and types the sudo
# password once.
in_terminal "$PLUGIN/install.sh" > /tmp/install.log 2>&1; rc=$?
is "install.sh exits 0" "$rc" "0"
(( rc == 0 )) || sed 's/^/      /' /tmp/install.log | tail -25
yes "missing dependency was installed (wg)" command -v wg
yes "missing dependency was installed (nft)" command -v nft
for f in vpn-status vpn-toggle vpn-import vpn-verify vpn-check vpn-rescue vpn-diagnose vpnkit-pick vpnkit-sync vpnkit-import vpnkit-killswitch vpnkit-direct vpnkit-direct-rules vpn-direct direct-launch google-chrome-stable qbt-netns-up qbt-launch qbittorrent; do
  yes "installed /usr/local/bin/$f" test -x /usr/local/bin/$f
done
yes "the Chrome direct units are installed" test -f /etc/systemd/system/vpnkit-direct.service -a -f /etc/systemd/system/vpnkitdirect.slice
no "and Chrome direct is not enabled: it is opt-in" systemctl is-enabled --quiet vpnkit-direct.service
yes "sudoers file is valid" visudo -c -f /etc/sudoers.d/99-vpnkit
yes "the AI troubleshooting skill is installed" test -r /usr/local/lib/vpnkit/skills/diagnose-vpn/SKILL.md

# "Troubleshoot with AI": a stub agent records what vpn-diagnose hands it.
STUB=$(mktemp -d); chmod 755 "$STUB"
printf '#!/usr/bin/env bash\necho claude\n' > "$STUB/omarchy-default-agent"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > %s/args\n' "$STUB" > "$STUB/omarchy-agent"
chmod 755 "$STUB"/omarchy-*; chmod 777 "$STUB"
as_user env PATH="$STUB:$PATH" /usr/local/bin/vpn-diagnose "suite problem" >/dev/null 2>&1
yes "vpn-diagnose starts the default agent with --prompt" grep -qx -- --prompt "$STUB/args"
yes "the prompt carries the problem" grep -q "suite problem" "$STUB/args"
yes "the prompt points at the installed skill" grep -q /usr/local/lib/vpnkit/skills/diagnose-vpn/SKILL.md "$STUB/args"
is "vpn-status reports the default agent" "$(as_user env PATH="$STUB:$PATH" /usr/local/bin/vpn-status --json | jq -r .ai_agent)" "claude"
rm -rf "$STUB"
is "sudoers file mode" "$(stat -c %a /etc/sudoers.d/99-vpnkit)" "440"
is "settings pin the desktop user" "$(. /etc/vpnkit/vpnkit.conf; echo "$TARGET_USER")" "$U"
is "installed version matches the repo" "$(cat /usr/local/lib/vpnkit/VERSION)" "$(cat "$PLUGIN/VERSION")"
yes "the drop folder exists" test -d "$DROP/torrent"
is "drop folder is private" "$(stat -c %a "$DROP")" "700"
is "drop folder belongs to the user" "$(stat -c %U "$DROP")" "$U"
is "IPv6 is off on the physical link" "$(sysctl -n net.ipv6.conf.$PHYS.disable_ipv6)" "1"
is "loopback keeps IPv6" "$(sysctl -n net.ipv6.conf.lo.disable_ipv6)" "0"
is "the physical profile has ipv6.method=disabled despite its IPv6 DNS server" \
  "$(nmcli -g ipv6.method connection show "$PPROF")" "disabled"
no "the installer printed no IPv6 warning" grep -q "Could not set ipv6.method=disabled" /tmp/install.log
yes "the profile's IPv6 settings were saved for the uninstall" \
  grep -qF "$(printf '%s\tauto\t2606:4700:4700::1111' "$PPROF")" /etc/vpnkit/ipv6-profiles.saved
no "tester has no passwordless sudo in general" as_user sudo -n true
yes "tester may run the status helper without a password" as_user sudo -n /usr/local/bin/qbt-netns-status
no "tester may NOT run the leak check with arguments" as_user sudo -n /usr/local/bin/vpn-verify --fail-closed

gateway on
is "the lookup service answers with the home address" "$(myip)" "$HOME_IP"
no "only-in-tunnel.test does not resolve without a VPN" resolves only-in-tunnel.test
is "nothing is connected after install" "$(status .desktop_vpn)" "false"
is "no kill switch after install" "$(status .killswitch)" "false"
is "still on the home address after install" "$(myip)" "$HOME_IP"
is "status reports the torrent tunnel as not set up" "$(status .qbt_configured)" "false"
no "qbittorrent refuses to start without a tunnel" as_user /usr/local/bin/qbittorrent

# Point the lookups at the simulated internet and declare a bypass target.
sed -i "s|^IP_LOOKUP_URL=.*|IP_LOOKUP_URL=\"$LOOKUP\"|; s|^BYPASS_CIDRS=.*|BYPASS_CIDRS=\"198.51.100.80/32\"|; s|^IP_CACHE_TTL=.*|IP_CACHE_TTL=1|" /etc/vpnkit/vpnkit.conf

# ---------------------------------------------------------------------------
section "2. Drop folder import"
conf "$DROP/wg-CA-1.conf"          "$WG/deskA.key"   10.2.0.2 10.2.0.1 "CA#1" "$WG/srvA.pub" 51820
conf "$DROP/wg-SE-2.conf"          "$WG/deskB.key"   10.3.0.2 10.3.0.1 "SE#2" "$WG/srvB.pub" 51821
conf "$DROP/torrent/wg-NL-3.conf"  "$WG/torrent.key" 10.2.0.3 10.2.0.1 "NL#3" "$WG/srvA.pub" 51820
echo "this is not a config" > "$DROP/notes.conf"; chown $U:$U "$DROP/notes.conf"
ln -s /etc/shadow "$DROP/evil.conf"
is "status counts the waiting configs" "$(status .inbox)" "4"
OUT=$(as_user sudo -n /usr/local/bin/vpnkit-sync sync); echo "      $OUT"
is "three servers imported" "$(jq -r '.imported | sort | join(",")' <<<"$OUT")" "proton-ca-1,proton-nl-3,proton-se-2"
is "the config from torrent/ is chosen for torrents" "$(jq -r .torrent <<<"$OUT")" "proton-nl-3"
is "status names the torrent server" "$(status .qbt_conn)" "proton-nl-3"
is "the junk file is reported, not imported" "$(jq -r '.skipped[].file' <<<"$OUT")" "notes.conf"
no "imported desktop configs are gone from the folder" test -e "$DROP/wg-CA-1.conf"
no "imported torrent config is gone from the folder" test -e "$DROP/torrent/wg-NL-3.conf"
yes "the junk file is left alone" test -e "$DROP/notes.conf"
yes "a symlink in the folder is ignored" test -L "$DROP/evil.conf"
rm -f "$DROP/notes.conf" "$DROP/evil.conf"
for p in proton-ca-1 proton-se-2 proton-nl-3; do
  is "$p never connects on its own" "$(nmcli -g connection.autoconnect connection show $p)" "no"
  is "$p keyfile is root-only" "$(stat -c '%a %U' /etc/NetworkManager/system-connections/$p.nmconnection)" "600 root"
  is "$p has IPv6 disabled" "$(nmcli -g ipv6.method connection show $p)" "disabled"
done
is "torrent config is root-only" "$(stat -c '%a %U' /etc/wireguard/vpnkit-torrent.conf)" "600 root"
is "importing did not connect anything" "$(myip)" "$HOME_IP"
# ---------------------------------------------------------------------------
section "3. Torrent namespace"
yes "the namespace is up" ip netns list
is "status: tunnel up" "$(status .qbt_tunnel)" "true"
is "namespace exits through the torrent tunnel" "$(ip netns exec qbtvpn curl -4 -s --max-time 4 $LOOKUP)" "10.2.0.3"
is "host still exits from the home address" "$(myip)" "$HOME_IP"
is "only lo and the tunnel are inside" "$(ip -n qbtvpn -o link show | awk -F': ' '{print $2}' | sort | paste -sd,)" "lo,pqbt0"
yes "DNS inside the namespace uses the in-tunnel resolver" ip netns exec qbtvpn getent hosts only-in-tunnel.test
cp /usr/bin/sleep /usr/bin/qbittorrent        # stand-in for the real client
as_user /usr/local/bin/qbittorrent 600 </dev/null >/dev/null 2>&1 &
sleep 2
is "qbittorrent started through the wrapper is inside the namespace" "$(status .qbt_protected)" "true"
is "and runs as the desktop user, not root" "$(ps -o user= -p "$(pgrep -x qbittorrent | head -1)" | tr -d ' ')" "$U"
pkill -x qbittorrent; sleep 1
as_user /usr/bin/qbittorrent 600 </dev/null >/dev/null 2>&1 &
sleep 1
is "a qbittorrent outside the namespace is detected" "$(status .qbt_unprotected)" "true"
# A second qBittorrent hands what it opens to the running one over a socket
# file, which crosses namespaces: with one outside, nothing may start another.
no "with one outside, the wrapper refuses to start qbittorrent" as_user /usr/local/bin/qbittorrent 5
no "with one outside, qbt-launch refuses too" as_user sudo -n /usr/local/bin/qbt-launch 5
no "with one outside, the wrapper refuses even from inside the namespace" ip netns exec qbtvpn runuser -u "$U" -- /usr/local/bin/qbittorrent 5
as_user /usr/local/bin/qbittorrent 600 </dev/null >/dev/null 2>&1 &
sleep 2
is "no second qbittorrent was started" "$(pgrep -c -x qbittorrent)" "1"
pkill -x qbittorrent; sleep 1
# qbittorrent-nox shares the GUI's profile and socket, so it counts the same.
cp /usr/bin/sleep /usr/bin/qbittorrent-nox     # stand-in
as_user /usr/bin/qbittorrent-nox 600 </dev/null >/dev/null 2>&1 &
sleep 1
no "with qbittorrent-nox outside, the wrapper refuses to start qbittorrent" as_user /usr/local/bin/qbittorrent 5
no "with qbittorrent-nox outside, qbt-launch refuses too" as_user sudo -n /usr/local/bin/qbt-launch 5
pkill -x qbittorrent-nox; sleep 1; rm -f /usr/bin/qbittorrent-nox
# A lookup server that never stops answering must not make a helper buffer it.
big=$(as_user timeout 20 bash -c '. /usr/local/lib/vpnkit/common.sh; vpnkit_fetch http://192.0.2.80:8080/endless 5 | wc -c')
is "an endless lookup response is dropped, not buffered" "$big" "0"
big=$(timeout 20 ip netns exec qbtvpn bash -c '. /usr/local/lib/vpnkit/common.sh; out=$(vpnkit_curl 5 http://192.0.2.80:8080/endless) || out=""; printf %s "$out" | wc -c')
is "the same inside the torrent namespace" "$big" "0"
# Other torrent apps are not routed into the namespace; they must be reported.
is "no other torrent app reported when none runs" "$(status '.other_torrent_apps | length')" "0"
is "status names the torrent interface" "$(status .torrent_if)" "pqbt0"
cp /usr/bin/sleep /tmp/transmission-daemon      # longer than 15 characters: tests the cut name
as_user /tmp/transmission-daemon 600 </dev/null >/dev/null 2>&1 &
sleep 1
is "another torrent app outside the tunnel is reported" "$(status '.other_torrent_apps | join(",")')" "transmission-daemon"
yes "and the leak check fails on it" bash -c '/usr/local/bin/vpn-verify | grep -q "FAIL.*transmission-daemon is running outside"'
pkill -x transmission-da; sleep 1
ip netns exec qbtvpn runuser -u $U -- /tmp/transmission-daemon 600 </dev/null >/dev/null 2>&1 &
sleep 1
is "the same app inside the namespace is not reported" "$(status '.other_torrent_apps | length')" "0"
pkill -x transmission-da; sleep 1; rm -f /tmp/transmission-daemon
yes "the torrent tunnel can be moved to another server" as_user sudo -n /usr/local/bin/vpnkit-sync torrent proton-se-2
is "torrents now exit through server B" "$(ip netns exec qbtvpn curl -4 -s --max-time 6 $LOOKUP)" "10.3.0.2"
is "status follows" "$(status .qbt_conn)" "proton-se-2"
yes "and back" as_user sudo -n /usr/local/bin/vpnkit-sync torrent proton-nl-3
is "torrents exit through the torrent server again" "$(ip netns exec qbtvpn curl -4 -s --max-time 6 $LOOKUP)" "10.2.0.3"
no "names outside the kit cannot be chosen" as_user sudo -n /usr/local/bin/vpnkit-sync torrent "Wired connection 1"
as_user /usr/local/bin/qbittorrent 600 </dev/null >/dev/null 2>&1 &
sleep 2
no "the torrent server cannot be switched under a running qBittorrent" as_user sudo -n /usr/local/bin/vpnkit-sync torrent proton-se-2
pkill -x qbittorrent; sleep 1
ip -n qbtvpn link set pqbt0 down
is "tunnel down: nothing leaves the namespace" "$(ip netns exec qbtvpn curl -4 -s --max-time 3 $LOOKUP || echo none)" "none"
no "tunnel down: no DNS in the namespace" ip netns exec qbtvpn timeout 4 getent hosts only-in-tunnel.test
no "tunnel down: qbittorrent refuses to start" as_user /usr/local/bin/qbittorrent 5
ip -n qbtvpn link set pqbt0 up; ip -n qbtvpn route replace default dev pqbt0
is "tunnel restored" "$(ip netns exec qbtvpn curl -4 -s --max-time 4 $LOOKUP)" "10.2.0.3"

# The namespace's resolver files must be in place before anything enters: a
# process that enters without them keeps the host's nsswitch.conf (resolve ->
# systemd-resolved over a Unix socket, outside the tunnel) for its whole life.
# Reported in the marketplace review of 0.3.6.
NSDIR=/etc/netns/qbtvpn; NSBAK=$(mktemp -d)
yes "qbt-netns-up writes the resolver files before the default route" \
  awk '/vpnkit_resolver_safe "\/etc\/netns/ && !r {r=NR} /route add default/ && !d {d=NR} END {exit !(r && d && r < d)}' /usr/local/bin/qbt-netns-up
yes "no temporary files are left in $NSDIR (ip netns exec mounts every entry)" \
  bash -c "[[ \$(ls -A $NSDIR | sort | paste -sd,) == nsswitch.conf,resolv.conf ]]"
mv "$NSDIR/nsswitch.conf" "$NSBAK/"
no "without the namespace's nsswitch.conf, qbt-launch refuses" as_user sudo -n /usr/local/bin/qbt-launch 5
no "and so does the wrapper" as_user /usr/local/bin/qbittorrent 5
no "and the wrapper refuses inside a namespace entered without them" ip netns exec qbtvpn runuser -u "$U" -- /usr/local/bin/qbittorrent 5
# A qBittorrent that entered too early is caught by the leak check.
ip netns exec qbtvpn runuser -u "$U" -- /usr/bin/qbittorrent 600 </dev/null >/dev/null 2>&1 &
sleep 1
mv "$NSBAK/nsswitch.conf" "$NSDIR/"
OUT=$(vpn-verify 2>&1); rc=$?
is "a qBittorrent that entered before the resolver files existed fails the leak check" "$rc" "1"
yes "and is named" grep -q "FAIL.*sees the host's DNS settings" <<<"$OUT"
pkill -x qbittorrent; sleep 1
printf 'hosts: mymachines resolve [!UNAVAIL=return] files myhostname dns\n' > "$NSBAK/unsafe"
cp "$NSDIR/nsswitch.conf" "$NSBAK/nsswitch.conf"; cp "$NSBAK/unsafe" "$NSDIR/nsswitch.conf"
no "with resolve in the namespace's nsswitch.conf, qbt-launch refuses" as_user sudo -n /usr/local/bin/qbt-launch 5
cp "$NSBAK/nsswitch.conf" "$NSDIR/nsswitch.conf"; rm -rf "$NSBAK"
as_user /usr/local/bin/qbittorrent 600 </dev/null >/dev/null 2>&1 &
sleep 2
yes "a qBittorrent started normally resolves only through the tunnel" bash -c '/usr/local/bin/vpn-verify | grep -q "PASS.*resolves names only through the tunnel"'
pkill -x qbittorrent; sleep 1

# ---------------------------------------------------------------------------
section "4. Desktop VPN and kill switch"
nft -f - <<EOF
table inet suite_dns {
  # postrouting, after every filter: counts only packets that really leave.
  chain out { type filter hook postrouting priority 300;
    oifname "$PHYS" meta l4proto { tcp, udp } th dport 53 counter comment "dns-on-physical"
  }
}
EOF
dns_leaks() { nft -j list table inet suite_dns | jq '[.. | objects | select(.counter?) | .counter.packets] | add'; }
no "the torrent server cannot carry regular traffic too" as_user /usr/local/bin/vpn-toggle proton-nl-3
is "and nothing was connected" "$(status .desktop_vpn)" "false"
yes "vpn-toggle connects server A" as_user /usr/local/bin/vpn-toggle proton-ca-1
no "the server carrying regular traffic cannot be chosen for torrents" as_user sudo -n /usr/local/bin/vpnkit-sync torrent proton-ca-1
is "the torrent tunnel stayed where it was" "$(status .qbt_conn)" "proton-nl-3"
is "regular traffic exits through server A" "$(myip)" "10.2.0.2"
is "kill switch is armed" "$(status .killswitch)" "true"
is "status shows the VPN address" "$(status .external_ip)" "10.2.0.2"
resolvectl flush-caches
before=$(dns_leaks)
yes "a name only the tunnel resolver knows resolves" resolves only-in-tunnel.test
resolves example.org; resolves archlinux.org
is "no DNS packet left through the physical interface" "$(( $(dns_leaks) - before ))" "0"
is "a program bound to the physical interface cannot get out" "$(myip --interface veth-h)" "none"
is "the bypass address still uses the normal connection" "$(curl -4 -s --max-time 3 $BYPASS_URL)" "$HOME_IP"
is "the torrent tunnel is untouched" "$(ip netns exec qbtvpn curl -4 -s --max-time 4 $LOOKUP)" "10.2.0.3"

# Switching servers must have no moment on the home address.
( end=$((SECONDS+12)); while (( SECONDS < end )); do myip; echo; sleep 0.05; done ) > /tmp/switch.log &
probe=$!
sleep 1
yes "vpn-toggle switches to server B" as_user /usr/local/bin/vpn-toggle proton-se-2
sleep 1
yes "and back to server A" as_user /usr/local/bin/vpn-toggle proton-ca-1
wait "$probe"
is "requests seen from the home address while switching" "$(grep -c "^$HOME_IP$" /tmp/switch.log)" "0"
yes "both servers were really used during the switch" bash -c "grep -q '^10.3.0.2$' /tmp/switch.log && grep -q '^10.2.0.2$' /tmp/switch.log"

# The profile disappears (what NetworkManager does on errors or suspend).
nmcli connection down proton-ca-1 >/dev/null 2>&1; sleep 1
is "VPN dropped: regular traffic is blocked, not sent from home" "$(myip)" "none"
resolvectl flush-caches
no "VPN dropped: no DNS" resolves example.net
is "status says blocked" "$(status .blocked)" "true"
is "status shows no address while blocked" "$(status .external_ip)" "blocked"
is "the bypass address still works while blocked" "$(curl -4 -s --max-time 3 $BYPASS_URL)" "$HOME_IP"
yes "picking a server again recovers" as_user /usr/local/bin/vpn-toggle proton-se-2
is "now on server B" "$(myip)" "10.3.0.2"

# The server itself dies while the profile stays up.
ip -n provider link set wgB down
is "server dead: nothing reaches the internet" "$(myip)" "none"
no "vpn-toggle reports a server that does not answer" as_user /usr/local/bin/vpn-toggle proton-se-2
is "and traffic stays blocked" "$(myip)" "none"
ip -n provider link set wgB up

yes "vpn-toggle off" as_user /usr/local/bin/vpn-toggle off
is "back on the home address" "$(myip)" "$HOME_IP"
is "kill switch removed" "$(status .killswitch)" "false"
no "the kill switch table is gone" nft list table inet vpnkit_kill

nmcli connection up proton-ca-1 >/dev/null 2>&1; sleep 2
is "a VPN started with plain nmcli is armed by the hook" "$(status .killswitch)" "true"
as_user /usr/local/bin/vpn-toggle off >/dev/null 2>&1

# ---------------------------------------------------------------------------
section "4b. Chrome direct: rules"
# Opt-in: one app keeps the normal connection while a server is selected.
# Whatever root starts in the system's vpnkitdirect.slice is that app here;
# the launcher that puts Chrome there is tested on its own.
DSLICE=/sys/fs/cgroup/vpnkitdirect.slice
VCONF=/etc/vpnkit/vpnkit.conf
direct()      { as_user sudo -n /usr/local/bin/vpnkit-direct "$@"; }
direct_dns()  { sed -i '/^DIRECT_DNS=/d' "$VCONF"; printf 'DIRECT_DNS="%s"\n' "$1" >> "$VCONF"; }
direct_rule() { ip -4 rule | grep -q 0xca6d; }
tailnet_rule() { ip -4 rule list priority 89 | grep -q 'to 100.64.0.0/10 fwmark 0xca6d lookup 52'; }
ks_line()     { nft list table inet vpnkit_kill 2>/dev/null | grep -q 'meta mark 0x0000ca6d accept'; }
in_slice()    { systemd-run --quiet --wait --pipe --slice=vpnkitdirect.slice --uid=$U "$@" 2>/dev/null; }
slice_ip()    { local a; a=$(in_slice curl -4 -s --max-time 4 "$LOOKUP") || a=""; printf '%s' "${a:-none}"; }
user_slice()  { as_user systemd-run --user --quiet --wait --pipe --slice=vpnkitdirect.slice "$@" 2>/dev/null; }
# sudo_refuses <description> <command...>: sudo itself turns the command down
# (the tester's wheel rule wants a password for anything not listed), so the
# helper never runs. `sudo -l` cannot tell this apart: wheel allows everything.
sudo_refuses() {
  local d="$1" out rc; shift
  out=$(as_user sudo -n "$@" 2>&1 </dev/null); rc=$?
  if (( rc != 0 )) && grep -q "a password is required" <<<"$out"; then ok "$d"; else bad "$d (rc $rc: ${out:0:160})"; fi
}
# refuses <description> <pattern> <command...>: exits 1 within 15 s, saying
# <pattern>. Run as the user. (A start that is not refused would hang on the
# stand-in Chrome, so this times out rather than waiting.)
ASU=(runuser -u $U -- env HOME=$UHOME USER=$U XDG_RUNTIME_DIR=/run/user/$UID_T PATH="$PATH")
refuses() {
  local d="$1" p="$2" out rc; shift 2
  out=$(timeout 15 "${ASU[@]}" "$@" 2>&1 </dev/null); rc=$?
  if (( rc == 1 )) && grep -q -- "$p" <<<"$out"; then ok "$d"; else bad "$d (rc $rc: $(head -c 200 <<<"$out" | tr '\n' ' '))"; fi
}

as_user /usr/local/bin/vpn-toggle proton-ca-1 >/dev/null 2>&1
is "server A is selected" "$(myip)" "10.2.0.2"
no "off: nothing installed" nft list table inet vpnkit_direct
no "off: no fwmark rule" direct_rule
no "off: no slice" test -d "$DSLICE"
no "off: the kill switch has no direct line" ks_line
is "off: status" "$(direct status | jq -c .)" '{"enabled":false,"unit":false,"rules":false,"dns_ok":true}'
sudo_refuses "the passwordless rule allows only on, off and status" /usr/local/bin/vpnkit-direct bogus
sudo_refuses "and nothing after them" /usr/local/bin/vpnkit-direct on now
sudo_refuses "the rules helper is not passwordless" /usr/local/bin/vpnkit-direct-rules up
/usr/local/bin/vpnkit-direct bogus >/dev/null 2>&1; rc=$?
is "the helper itself refuses anything else" "$rc" "2"

direct_dns 127.0.0.1
is "on" "$(direct on 2>&1)" "direct: on"
yes "the slice's cgroup exists" test -d "$DSLICE"
is "status: on" "$(direct status | jq -c .)" '{"enabled":true,"unit":true,"rules":true,"dns_ok":true}'
is "a probe in the slice exits from the home address" "$(slice_ip)" "$HOME_IP"
is "the host still exits through the server" "$(myip)" "10.2.0.2"
is "loopback traffic from the slice keeps its 127.0.0.1 source" \
  "$(in_slice curl -4 -s --max-time 4 http://127.0.0.1:8080/)" "127.0.0.1"
# A user can make a slice of the same name under their own service manager;
# it is not the system's, so it gets nothing.
yes "a user's own vpnkitdirect.slice lives under the user's manager" \
  grep -q '^0::/user.slice/.*/vpnkitdirect.slice/' <<<"$(user_slice cat /proc/self/cgroup)"
is "and a probe started there exits through the server" "$(user_slice curl -4 -s --max-time 4 "$LOOKUP")" "10.2.0.2"
no "a user cannot move itself into the slice" as_user sh -c 'echo $$ > /sys/fs/cgroup/vpnkitdirect.slice/cgroup.procs'
no "a user cannot have the system manager start a service in the slice" \
  as_user systemd-run --no-ask-password --quiet --wait --slice=vpnkitdirect.slice true
no "nor a scope" as_user systemd-run --no-ask-password --quiet --scope --slice=vpnkitdirect.slice true
yes "the kill switch has the direct line after the DNS reject" bash -c \
  "nft list table inet vpnkit_kill | awk '/dport \{ 53, 853 \}.*reject/ && !r {r=NR} /meta mark 0x0000ca6d accept/ && !m {m=NR} END {exit !(r && m && r < m)}'"
# 10.0.2.3 is QEMU's resolver, on the physical link the DNS counter watches.
before=$(dns_leaks)
in_slice bash -c 'printf x > /dev/udp/10.0.2.3/53'
is "plain DNS from the slice still cannot leave outside a tunnel" "$(( $(dns_leaks) - before ))" "0"

nmcli connection down proton-ca-1 >/dev/null 2>&1; sleep 1
is "blocked: the host does not get out" "$(myip)" "none"
is "blocked: the slice still gets out" "$(slice_ip)" "$HOME_IP"
as_user /usr/local/bin/vpn-toggle proton-ca-1 >/dev/null 2>&1
is "server A again" "$(myip)" "10.2.0.2"
yes "the re-armed kill switch keeps the direct line" ks_line

# nftables resolves the slice's path to a cgroup id when the rules load, so a
# recreated cgroup needs the rules loaded again.
ino=$(stat -c %i "$DSLICE")
systemctl restart vpnkit-direct.service
ino2=$(stat -c %i "$DSLICE" 2>/dev/null)
yes "restarting the unit recreates the cgroup" test -n "$ino2" -a "$ino2" != "$ino"
is "rules follow a recreated cgroup" "$(slice_ip)" "$HOME_IP"

# Tailnet addresses stay on Tailscale's table, only when that table exists.
no "no tailnet rule without Tailscale's table" tailnet_rule
ip route add 100.100.100.100/32 dev lo table 52
/etc/NetworkManager/dispatcher.d/50-vpnkit "$PHYS" up
yes "after a link comes up with Tailscale's table there, tailnet addresses use it" tailnet_rule
ip route flush table 52
/usr/local/bin/vpnkit-direct-rules up
no "the tailnet rule goes when the table does" tailnet_rule

systemd-run --quiet --slice=vpnkitdirect.slice --uid=$U --unit=suite-in-slice sleep 120
no "off is refused while something runs in the slice" direct off
yes "and the exemption stays" nft list table inet vpnkit_direct
systemctl stop suite-in-slice.service

direct_dns 192.0.2.53
OUT=$(direct on 2>&1); rc=$?
is "a DIRECT_DNS outside loopback is refused" "$rc" "1"
yes "and the reason is given" grep -q "127.0.0.0/8" <<<"$OUT"
direct_dns 127.0.0.9
OUT=$(direct on 2>&1); rc=$?
is "a DIRECT_DNS that does not answer is refused" "$rc" "1"
yes "and the reason is given" grep -q "does not answer" <<<"$OUT"
is "status flags the resolver" "$(direct status | jq -r .dns_ok)" "false"
direct_dns 127.0.0.1

# --- Chrome itself: the wrapper, the root launcher, the private resolver ----
# Stand-ins: "Chrome" writes where it landed (exit address, what the loopback
# resolver and the in-tunnel one answer, who it runs as) and stays; a copy of
# sleep under /opt/google/chrome is a Chrome process for the "outside" checks.
cat > /usr/bin/google-chrome-stable <<EOF
#!/usr/bin/env bash
echo \$\$ > /tmp/chrome-probe.pid
echo "HOME=\$HOME XDG_CONFIG_HOME=\${XDG_CONFIG_HOME:-} ARGS=\$*" > /tmp/chrome-probe.env
echo "\$(curl -4 -s --max-time 4 $LOOKUP) \$(getent hosts direct-only.test | awk '{print \$1}') \$(getent hosts only-in-tunnel.test >/dev/null && echo leak || echo noleak) \$(id -un)" > /tmp/chrome-probe
exec sleep 600
EOF
chmod 755 /usr/bin/google-chrome-stable
install -d /opt/google/chrome; cp /usr/bin/sleep /opt/google/chrome/chrome
CHROME_PID=""
chrome_start() {  # start "Chrome" as the user through the wrapper; wait for its probe
  rm -f /tmp/chrome-probe /tmp/chrome-probe.pid /tmp/chrome-probe.env
  as_user /usr/local/bin/google-chrome-stable "$@" </dev/null >/dev/null 2>&1 &
  local i; for i in $(seq 1 40); do [[ -s /tmp/chrome-probe ]] && break; sleep 0.5; done
  CHROME_PID=$(cat /tmp/chrome-probe.pid 2>/dev/null)
}
chrome_stop() { [[ -n "$CHROME_PID" ]] && kill "$CHROME_PID" 2>/dev/null; CHROME_PID=""; sleep 1; }
in_ns() { [[ -n "$CHROME_PID" ]] && nsenter -t "$CHROME_PID" -m "$@"; }

# The launcher entry follows the opt-in (vpn-direct writes it).
DESK_SYS=/usr/share/applications/google-chrome.desktop
DESK=$UHOME/.local/share/applications/google-chrome.desktop
MARK='# Written by omarchy-proton (Chrome direct). Removed when it is turned off.'
cat > "$DESK_SYS" <<'EOF'
[Desktop Entry]
Version=1.0
Name=Google Chrome
Exec=/usr/bin/google-chrome-stable %U
Type=Application
Actions=new-window;new-private-window;

[Desktop Action new-window]
Name=New Window
Exec=/usr/bin/google-chrome-stable

[Desktop Action new-private-window]
Name=New Incognito Window
Exec=/usr/bin/google-chrome-stable --incognito
EOF
install -d -o $U -g $U "$UHOME/.local" "$UHOME/.local/share" "$UHOME/.local/share/applications"
printf '[Desktop Entry]\nName=My own Chrome\nExec=/usr/bin/google-chrome-stable --my-flag\n' > "$DESK"
chown $U:$U "$DESK"
OUT=$(as_user /usr/local/bin/vpn-direct on 2>&1); rc=$?
is "vpn-direct on (already on: same result)" "$rc" "0"
is "the override carries the marker" "$(head -1 "$DESK" 2>/dev/null)" "$MARK"
is "override points at the wrapper" "$(grep '^Exec=' "$DESK" 2>/dev/null | paste -sd'|' -)" \
  "Exec=/usr/local/bin/google-chrome-stable %U|Exec=/usr/local/bin/google-chrome-stable|Exec=/usr/local/bin/google-chrome-stable --incognito"
yes "a user's own file is backed up" bash -c "grep -l 'My own Chrome' $DESK.bak.* | grep -q ."

# A Chrome already in the slice is fine: a new start only hands over to it.
systemd-run --quiet --slice=vpnkitdirect.slice --uid=$U --unit=suite-chrome-inside /opt/google/chrome/chrome 600
chrome_start https://example.test/
is "Chrome direct: probe" "$(cat /tmp/chrome-probe 2>/dev/null)" "$HOME_IP 192.0.2.9 noleak $U"
yes "and it runs in the slice" grep -q '^0::/vpnkitdirect.slice/' "/proc/${CHROME_PID:-none}/cgroup"
is "with the user's HOME and XDG_CONFIG_HOME, and its arguments" "$(cat /tmp/chrome-probe.env 2>/dev/null)" \
  "HOME=$UHOME XDG_CONFIG_HOME=$UHOME/.config ARGS=https://example.test/"
is "its resolv.conf names DIRECT_DNS only" "$(in_ns grep '^nameserver' /etc/resolv.conf 2>/dev/null | paste -sd, -)" "nameserver 127.0.0.1"
yes "its nsswitch.conf asks plain DNS, not resolved" in_ns grep -qE '^hosts:[[:space:]]+files myhostname dns$' /etc/nsswitch.conf
# systemd-resolved replaces its files by renaming a new one over them.
cp /run/systemd/resolve/stub-resolv.conf /run/systemd/resolve/.suite-new
mv /run/systemd/resolve/.suite-new /run/systemd/resolve/stub-resolv.conf
is "resolver override survives a host-side rename" "$(in_ns grep '^nameserver' /etc/resolv.conf 2>/dev/null | paste -sd, -)" "nameserver 127.0.0.1"
yes "and the host's own resolver settings are untouched" grep -q '^nameserver 127.0.0.53' /etc/resolv.conf
chrome_stop
direct_dns ""
chrome_start
is "with DIRECT_DNS empty, Chrome still goes direct" "$(cut -d' ' -f1 /tmp/chrome-probe 2>/dev/null)" "$HOME_IP"
is "and uses the system resolver" "$(in_ns grep '^nameserver' /etc/resolv.conf 2>/dev/null | paste -sd, -)" "nameserver 127.0.0.53"
chrome_stop
direct_dns 127.0.0.1

# Flags that make Chrome run another program as its child are refused.
for f in --renderer-cmd-prefix=/bin/sh "--gpu-launcher /bin/sh" --browser-subprocess-path=/bin/sh \
         --foo-cmd-prefix=x --utility-cmd-prefix -ppapi-plugin-launcher=/bin/sh; do
  # shellcheck disable=SC2086
  refuses "${f%% *} is refused" "refus" sudo -n /usr/local/bin/direct-launch $f
done
refuses "and through the wrapper too" "refus" /usr/local/bin/google-chrome-stable --renderer-cmd-prefix=/bin/sh
install -d -o $U -g $U "$UHOME/.config"
printf -- '--ozone-platform=wayland\n--gpu-launcher=/bin/sh\n' > "$UHOME/.config/chrome-flags.conf"
chown $U:$U "$UHOME/.config/chrome-flags.conf"
refuses "and in the user's chrome-flags.conf" "chrome-flags.conf" sudo -n /usr/local/bin/direct-launch
rm -f "$UHOME/.config/chrome-flags.conf"
# The environment that reaches the launcher is what the sudoers file keeps.
OUT=$(timeout 15 "${ASU[@]}" sudo -n -E /usr/local/bin/direct-launch 2>&1 </dev/null)
yes "sudo does not hand direct-launch the caller's environment (-E)" grep -q "not allowed to preserve the environment" <<<"$OUT"
OUT=$(timeout 15 "${ASU[@]}" sudo -n XDG_CONFIG_HOME=/tmp /usr/local/bin/direct-launch 2>&1 </dev/null)
yes "nor variables set on its command line" grep -q "not allowed to set the following environment variables" <<<"$OUT"

# Chrome hands new windows to a running instance, so one outside the slice
# would get them: nothing starts then.
systemctl stop suite-chrome-inside.service 2>/dev/null
as_user /opt/google/chrome/chrome 600 </dev/null >/dev/null 2>&1 &
sleep 1
OPID=$(pgrep -u $U -x chrome | head -1)
rm -f /tmp/chrome-probe
refuses "with Chrome outside, the wrapper refuses" "pid ${OPID:-none}" /usr/local/bin/google-chrome-stable
refuses "and direct-launch refuses" "pid ${OPID:-none}" sudo -n /usr/local/bin/direct-launch
no "and no Chrome was started" test -e /tmp/chrome-probe
[[ -n "$OPID" ]] && kill "$OPID"; sleep 1

# Turning it off must never leave the exemption loaded while it says off.
install -d /run/systemd/system/vpnkit-direct.service.d
printf '[Unit]\nRefuseManualStop=yes\n' > /run/systemd/system/vpnkit-direct.service.d/suite.conf
systemctl daemon-reload
OUT=$(direct off 2>&1); rc=$?
is "off fails when the unit cannot be stopped" "$rc" "1"
is "and status then still says on, with the rules" "$(direct status | jq -c '[.enabled, .rules]')" "[true,true]"
rm -rf /run/systemd/system/vpnkit-direct.service.d; systemctl daemon-reload

is "off" "$(direct off 2>&1)" "direct: off"
no "off: nothing installed" nft list table inet vpnkit_direct
no "off: no fwmark rule" direct_rule
no "off: no slice" test -d "$DSLICE"
no "kill switch line gone" ks_line
yes "the kill switch itself stays armed" nft list table inet vpnkit_kill
no "off: the unit is not enabled" systemctl is-enabled --quiet vpnkit-direct.service
no "off: no state file" test -e /etc/vpnkit/direct-apps
is "off: status" "$(direct status | jq -c .)" '{"enabled":false,"unit":false,"rules":false,"dns_ok":true}'
is "off: a process in a slice of that name follows the bar" "$(slice_ip)" "10.2.0.2"
systemctl start vpnkitdirect.slice
OUT=$(/usr/local/bin/vpnkit-direct-rules up 2>&1); rc=$?
is "the rules helper refuses to load while Chrome direct is off" "$rc" "1"
no "and loads nothing" nft list table inet vpnkit_direct
/usr/local/bin/vpnkit-direct-rules down >/dev/null 2>&1
systemctl stop vpnkitdirect.slice
chrome_start
is "off: wrapper passes through" "$(cut -d' ' -f1 /tmp/chrome-probe 2>/dev/null)" "10.2.0.2"
yes "off: and Chrome is not in the slice" bash -c "[[ -n '$CHROME_PID' ]] && ! grep -q '^0::/vpnkitdirect.slice/' /proc/$CHROME_PID/cgroup"
chrome_stop
refuses "off: direct-launch refuses" "off" sudo -n /usr/local/bin/direct-launch
as_user /usr/local/bin/vpn-direct off >/dev/null 2>&1
no "override removed when off" test -e "$DESK"
cp "$(ls "$DESK".bak.* 2>/dev/null | head -1)" "$DESK" 2>/dev/null; chown $U:$U "$DESK" 2>/dev/null
as_user /usr/local/bin/vpn-direct launcher >/dev/null 2>&1
yes "a launcher file without the marker is never removed" grep -q 'My own Chrome' "$DESK"
rm -f "$DESK" "$DESK".bak.*

# A unit that cannot start: on rolls everything back.
install -d /run/systemd/system/vpnkit-direct.service.d
printf '[Service]\nExecStartPre=/usr/bin/false\n' > /run/systemd/system/vpnkit-direct.service.d/suite.conf
systemctl daemon-reload
OUT=$(direct on 2>&1); rc=$?
is "on fails when its unit cannot start" "$rc" "1"
no "and leaves no state file" test -e /etc/vpnkit/direct-apps
no "no table" nft list table inet vpnkit_direct
no "no fwmark rule" direct_rule
no "no slice" test -d "$DSLICE"
no "no kill switch line" ks_line
no "and the unit is not enabled" systemctl is-enabled --quiet vpnkit-direct.service
rm -rf /run/systemd/system/vpnkit-direct.service.d; systemctl daemon-reload
systemctl reset-failed vpnkit-direct.service 2>/dev/null
as_user /usr/local/bin/vpn-toggle off >/dev/null 2>&1
before=$(dns_leaks)
bash -c 'printf x > /dev/udp/10.0.2.3/53'
yes "(the DNS counter does count a packet that leaves)" test "$(( $(dns_leaks) - before ))" -ge 1

# ---------------------------------------------------------------------------
section "5. The leak check, the rescue, and deleting a server"
as_user /usr/local/bin/vpn-toggle proton-ca-1 >/dev/null 2>&1
OUT=$(vpn-verify --fail-closed 2>&1); rc=$?
is "vpn-verify --fail-closed passes with a VPN up" "$rc" "0"
(( rc == 0 )) || grep -E "FAIL|Result" <<<"$OUT" | sed 's/^/      /'
echo "      $(grep Result <<<"$OUT")"
OUT=$(as_user sudo -n /usr/local/bin/vpn-verify 2>&1); rc=$?
is "the panel's leak check runs without a password and passes" "$rc" "0"
# The desktop VPN's own checks: handshake, where DNS really goes.
yes "the leak check sees the desktop tunnel's handshake" grep -q "PASS.*desktop tunnel: last handshake" <<<"$OUT"
yes "it follows the VPN's DNS server into the tunnel" grep -q "PASS.*DNS server 10.2.0.1 is reached through proton-ca-1" <<<"$OUT"
VPHYS=$(ip -4 route show default table main | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
yes "and sees that $VPHYS cannot take DNS questions away" grep -q "PASS.*$VPHYS cannot take DNS questions away" <<<"$OUT"

# A DNS server slipped onto the physical link (what a DHCP renewal or another
# tool could do) must fail the check.
prevdns=$(resolvectl dns "$VPHYS" 2>/dev/null | sed 's/^[^:]*: *//')
prevdr=$(resolvectl default-route "$VPHYS" 2>/dev/null | sed 's/^[^:]*: *//')
resolvectl dns "$VPHYS" 192.0.2.53; resolvectl default-route "$VPHYS" yes
OUT=$(vpn-verify 2>&1); rc=$?
is "a DNS server on $VPHYS fails the leak check" "$rc" "1"
yes "and is named" grep -q "FAIL.*$VPHYS can answer DNS questions outside the VPN" <<<"$OUT"
if [[ -n "${prevdns// /}" ]]; then resolvectl dns "$VPHYS" $prevdns; resolvectl default-route "$VPHYS" "${prevdr:-no}"
else resolvectl revert "$VPHYS"; fi

# A global DNS server (what `omarchy dns Cloudflare` writes into resolved.conf)
# overrides the VPN's resolver: the check must fail and name it.
yes "with no global DNS server, the check says so" grep -q "PASS.*no global DNS servers override" <<<"$(vpn-verify 2>&1)"
mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nDNS=192.0.2.53\n' > /etc/systemd/resolved.conf.d/99-suite-global.conf
systemctl restart systemd-resolved; sleep 2
OUT=$(vpn-verify 2>&1); rc=$?
is "a global DNS server fails the leak check" "$rc" "1"
yes "and is named" grep -q "FAIL.*global DNS servers override the VPN's DNS: 192.0.2.53" <<<"$OUT"
rm -f /etc/systemd/resolved.conf.d/99-suite-global.conf
systemctl restart systemd-resolved; sleep 2
as_user /usr/local/bin/vpn-toggle proton-ca-1 >/dev/null 2>&1
yes "after removing it the leak check passes again" vpn-verify

# A server that never answers (its side no longer knows our key, as when a
# config is revoked) while NetworkManager still shows the profile as up.
ip netns exec provider /tmp/wg-static set wgA peer "$(cat "$WG/deskA.pub")" remove
nmcli connection down proton-ca-1 >/dev/null 2>&1; nmcli connection up proton-ca-1 >/dev/null 2>&1; sleep 2
OUT=$(vpn-verify 2>&1); rc=$?
is "a server that never answers fails the leak check" "$rc" "1"
yes "the handshake check names it" grep -q "FAIL.*desktop tunnel: no handshake recorded" <<<"$OUT"
ip netns exec provider /tmp/wg-static set wgA peer "$(cat "$WG/deskA.pub")" allowed-ips 10.2.0.2/32
as_user /usr/local/bin/vpn-toggle proton-ca-1 >/dev/null 2>&1
is "server A answers again" "$(myip)" "10.2.0.2"

# With IPv6 kept on (install --keep-ipv6), the check must test it, not just note it.
sed -i 's/^DISABLE_IPV6=.*/DISABLE_IPV6=0/' /etc/vpnkit/vpnkit.conf
OUT=$(vpn-verify 2>&1)
yes "with IPv6 kept on, the leak check proves it cannot get out" grep -q "PASS.*IPv6 cannot get out while the VPN is up" <<<"$OUT"
sed -i 's/^DISABLE_IPV6=.*/DISABLE_IPV6=1/' /etc/vpnkit/vpnkit.conf

# Saved reports: vpn-check (the panel's "Check for leaks") keeps each one as
# the desktop user in a folder they can browse.
REPORTS="$UHOME/Documents/VPN leak checks"
OUT=$(as_user /usr/local/bin/vpn-check 2>&1); rc=$?
is "vpn-check passes with a VPN up" "$rc" "0"
NEWEST=$(ls -1 "$REPORTS"/leak-check-*.txt 2>/dev/null | sort | tail -1)
yes "vpn-check saved a report" test -s "$NEWEST"
is "the report belongs to the desktop user" "$(stat -c %U "$NEWEST")" "$U"
is "the reports folder is private" "$(stat -c %a "$REPORTS")" "700"
yes "the report names the selected server" grep -q "^Regular traffic: proton-ca-1 (kill switch on)" "$NEWEST"
yes "the report ends with the summary" grep -q "^Result: .* 0 failed" "$NEWEST"
yes "latest.txt is the newest report" cmp -s "$NEWEST" "$REPORTS/latest.txt"
yes "vpn-check says where it saved it" grep -qF "Report saved: $NEWEST" <<<"$OUT"
is "vpn-status names the reports folder" "$(status .report_dir)" "$REPORTS"
RED=$(printf 'exit 8.8.8.8 via 10.2.0.2\nkey %s\n' "$(cat "$WG/deskA.key")" | as_user /usr/local/bin/vpn-check --redact -)
no "the redacted copy hides a public address" grep -q "8\.8\.8\.8" <<<"$RED"
yes "and keeps private addresses readable" grep -q "10\.2\.0\.2" <<<"$RED"
no "and hides a private key" grep -qF "$(cat "$WG/deskA.key")" <<<"$RED"
no "latest-redacted.txt holds nothing key-like" grep -qE '[A-Za-z0-9+/]{43}=' "$REPORTS/latest-redacted.txt"
for i in $(seq -w 1 25); do as_user touch "$REPORTS/leak-check-2000-01-01_00-00-$i.txt"; done
as_user /usr/local/bin/vpn-check >/dev/null 2>&1
is "only the newest 20 reports are kept" "$(ls -1 "$REPORTS"/leak-check-*.txt | wc -l)" "20"
no "the oldest went first" test -e "$REPORTS/leak-check-2000-01-01_00-00-01.txt"
STUB=$(mktemp -d)
printf '#!/usr/bin/env bash\necho claude\n' > "$STUB/omarchy-default-agent"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > %s/args\n' "$STUB" > "$STUB/omarchy-agent"
chmod 755 "$STUB"/omarchy-*; chmod 777 "$STUB"
as_user env PATH="$STUB:$PATH" /usr/local/bin/vpn-diagnose "suite problem" >/dev/null 2>&1
yes "vpn-diagnose hands the agent the saved report" grep -q "VPN leak checks/latest.txt" "$STUB/args"
rm -rf "$STUB"
# An autostart entry that calls the real binary would start qBittorrent outside
# the namespace. The leak check has to catch it.
install -d -o $U -g $U "$UHOME/.config/autostart"
printf '[Desktop Entry]\nType=Application\nName=qb\nExec=/usr/bin/qbittorrent\n' > "$UHOME/.config/autostart/qb.desktop"
OUT=$(vpn-verify 2>&1); rc=$?
is "the leak check fails on a launcher that skips the wrapper" "$rc" "1"
yes "and names it" grep -q "qb.desktop" <<<"$OUT"
rm -f "$UHOME/.config/autostart/qb.desktop"
no "a server in use cannot be deleted" as_user sudo -n /usr/local/bin/vpnkit-sync remove proton-ca-1
yes "an unused server can be deleted" as_user sudo -n /usr/local/bin/vpnkit-sync remove proton-se-2
no "its profile is gone" nmcli connection show proton-se-2
no "its stored config is gone" test -e /etc/wireguard/proton-se-2.conf
no "names outside the kit are refused" as_user sudo -n /usr/local/bin/vpnkit-sync remove "Wired connection 1"
no "the torrent server cannot be deleted" as_user sudo -n /usr/local/bin/vpnkit-sync remove proton-nl-3
nmcli connection down proton-ca-1 >/dev/null 2>&1; sleep 1
is "blocked before the rescue" "$(myip)" "none"
yes "vpn-rescue succeeds" as_user env PATH="$PATH" /usr/local/bin/vpn-rescue
is "home address after the rescue" "$(myip)" "$HOME_IP"

# ---------------------------------------------------------------------------
section "6. Reinstall keeps settings; uninstall removes the kit"
direct on >/dev/null 2>&1
in_terminal "$PLUGIN/install.sh" > /tmp/install2.log 2>&1; rc=$?
is "install.sh can be run again" "$rc" "0"
is "settings survive a reinstall" "$(. /etc/vpnkit/vpnkit.conf; echo "$BYPASS_CIDRS")" "198.51.100.80/32"
is "the running torrent tunnel was left alone" "$(ip netns exec qbtvpn curl -4 -s --max-time 4 $LOOKUP)" "10.2.0.3"
yes "Chrome direct stays on through a reinstall" systemctl is-active --quiet vpnkit-direct.service
yes "with its rules" nft list table inet vpnkit_direct
is "a reinstall writes the launcher override while it is on" "$(head -1 "$DESK" 2>/dev/null)" "$MARK"
as_user /usr/local/bin/vpn-toggle proton-ca-1 >/dev/null 2>&1
is "and a probe in the slice still exits from the home address" "$(slice_ip)" "$HOME_IP"
in_terminal "$PLUGIN/uninstall.sh" --restore-ipv6 > /tmp/uninstall.log 2>&1; rc=$?
is "uninstall.sh exits 0" "$rc" "0"
(( rc == 0 )) || sed 's/^/      /' /tmp/uninstall.log | tail -15
is "home address after uninstall" "$(myip)" "$HOME_IP"
no "kill switch gone" nft list table inet vpnkit_kill
no "Chrome direct rules gone" nft list table inet vpnkit_direct
no "Chrome direct fwmark rules gone" direct_rule
no "Chrome direct slice gone" test -d "$DSLICE"
no "Chrome direct units gone" bash -c 'ls /etc/systemd/system/vpnkit-direct.service /etc/systemd/system/vpnkitdirect.slice 2>/dev/null | grep -q .'
no "Chrome direct state gone" test -e /etc/vpnkit/direct-apps
no "namespace gone" bash -c "ip netns list | grep -qw qbtvpn"
no "helpers gone" test -e /usr/local/bin/vpn-status
no "Chrome direct helpers gone" bash -c 'ls /usr/local/bin/vpnkit-direct /usr/local/bin/vpnkit-direct-rules /usr/local/bin/vpn-direct /usr/local/bin/direct-launch /usr/local/bin/google-chrome-stable 2>/dev/null | grep -q .'
no "uninstall removes the launcher override" test -e "$DESK"
no "sudoers rule gone" test -e /etc/sudoers.d/99-vpnkit
no "dispatcher hook gone" test -e /etc/NetworkManager/dispatcher.d/50-vpnkit
no "service gone" test -e /etc/systemd/system/qbt-netns.service
is "IPv6 back on" "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" "0"
is "the physical profile's IPv6 method is back" "$(nmcli -g ipv6.method connection show "$PPROF")" "auto"
is "and its IPv6 DNS server is back" "$(nmcli -g ipv6.dns connection show "$PPROF" | sed 's/\\:/:/g')" "2606:4700:4700::1111"
no "the saved IPv6 settings are cleared" test -e /etc/vpnkit/ipv6-profiles.saved
yes "servers are kept by a plain uninstall" nmcli connection show proton-ca-1
yes "settings are kept by a plain uninstall" test -f /etc/vpnkit/vpnkit.conf
yes "the leak-check reports are kept by a plain uninstall" test -s "$REPORTS/latest.txt"
in_terminal "$PLUGIN/install.sh" > /tmp/install3.log 2>&1
in_terminal "$PLUGIN/uninstall.sh" --purge > /tmp/uninstall2.log 2>&1; rc=$?
is "uninstall.sh --purge exits 0" "$rc" "0"
no "--purge removes the servers" nmcli connection show proton-ca-1
no "--purge removes the torrent config" test -e /etc/wireguard/vpnkit-torrent.conf
no "--purge removes the settings" test -e /etc/vpnkit
no "--purge removes the leak-check reports" test -e "$REPORTS"
is "home address at the end" "$(myip)" "$HOME_IP"
gateway off
yes "real internet still works" curl -4 -s --max-time 8 -o /tmp/out https://archlinux.org

pkill -f whoami.py; pkill -x dnsmasq
printf '\nResult: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
