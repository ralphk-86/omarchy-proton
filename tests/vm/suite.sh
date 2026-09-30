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
import http.server, socketserver
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
S(("0.0.0.0", 8080), H).serve_forever()
PY
# Detached from this shell's output, or ssh would wait for them to exit.
ip netns exec provider python3 /tmp/whoami.py </dev/null >/dev/null 2>&1 &
ip netns exec provider dnsmasq --no-daemon --no-resolv --no-hosts --bind-interfaces \
  --listen-address=10.2.0.1 --listen-address=10.3.0.1 --address=/#/192.0.2.7 </dev/null >/dev/null 2>&1 &
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
# The real path: the user runs install.sh in a terminal and types the sudo
# password once.
in_terminal "$PLUGIN/install.sh" > /tmp/install.log 2>&1; rc=$?
is "install.sh exits 0" "$rc" "0"
(( rc == 0 )) || sed 's/^/      /' /tmp/install.log | tail -25
yes "missing dependency was installed (wg)" command -v wg
yes "missing dependency was installed (nft)" command -v nft
for f in vpn-status vpn-toggle vpn-import vpn-verify vpn-rescue vpn-diagnose vpnkit-pick vpnkit-sync vpnkit-import vpnkit-killswitch qbt-netns-up qbt-launch qbittorrent; do
  yes "installed /usr/local/bin/$f" test -x /usr/local/bin/$f
done
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
pkill -x qbittorrent; sleep 1
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
section "5. The leak check, the rescue, and deleting a server"
as_user /usr/local/bin/vpn-toggle proton-ca-1 >/dev/null 2>&1
OUT=$(vpn-verify --fail-closed 2>&1); rc=$?
is "vpn-verify --fail-closed passes with a VPN up" "$rc" "0"
(( rc == 0 )) || grep -E "FAIL|Result" <<<"$OUT" | sed 's/^/      /'
echo "      $(grep Result <<<"$OUT")"
OUT=$(as_user sudo -n /usr/local/bin/vpn-verify 2>&1); rc=$?
is "the panel's leak check runs without a password and passes" "$rc" "0"
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
in_terminal "$PLUGIN/install.sh" > /tmp/install2.log 2>&1; rc=$?
is "install.sh can be run again" "$rc" "0"
is "settings survive a reinstall" "$(. /etc/vpnkit/vpnkit.conf; echo "$BYPASS_CIDRS")" "198.51.100.80/32"
is "the running torrent tunnel was left alone" "$(ip netns exec qbtvpn curl -4 -s --max-time 4 $LOOKUP)" "10.2.0.3"
as_user /usr/local/bin/vpn-toggle proton-ca-1 >/dev/null 2>&1
in_terminal "$PLUGIN/uninstall.sh" --restore-ipv6 > /tmp/uninstall.log 2>&1; rc=$?
is "uninstall.sh exits 0" "$rc" "0"
(( rc == 0 )) || sed 's/^/      /' /tmp/uninstall.log | tail -15
is "home address after uninstall" "$(myip)" "$HOME_IP"
no "kill switch gone" nft list table inet vpnkit_kill
no "namespace gone" bash -c "ip netns list | grep -qw qbtvpn"
no "helpers gone" test -e /usr/local/bin/vpn-status
no "sudoers rule gone" test -e /etc/sudoers.d/99-vpnkit
no "dispatcher hook gone" test -e /etc/NetworkManager/dispatcher.d/50-vpnkit
no "service gone" test -e /etc/systemd/system/qbt-netns.service
is "IPv6 back on" "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" "0"
yes "servers are kept by a plain uninstall" nmcli connection show proton-ca-1
yes "settings are kept by a plain uninstall" test -f /etc/vpnkit/vpnkit.conf
in_terminal "$PLUGIN/install.sh" > /tmp/install3.log 2>&1
in_terminal "$PLUGIN/uninstall.sh" --purge > /tmp/uninstall2.log 2>&1; rc=$?
is "uninstall.sh --purge exits 0" "$rc" "0"
no "--purge removes the servers" nmcli connection show proton-ca-1
no "--purge removes the torrent config" test -e /etc/wireguard/vpnkit-torrent.conf
no "--purge removes the settings" test -e /etc/vpnkit
is "home address at the end" "$(myip)" "$HOME_IP"
gateway off
yes "real internet still works" curl -4 -s --max-time 8 -o /tmp/out https://archlinux.org

pkill -f whoami.py; pkill -x dnsmasq
printf '\nResult: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
