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
#                         10.3.0.4      the Firefox tunnel (server B)
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
# A stand-in notify-send (put first in PATH) that records who sent what, to
# check the refusals that reach the desktop; notified prints the record when
# there is exactly one, else how many there were (a duplicate is a failure).
fake_notify() {
  rm -f /tmp/suite-notify.log
  if [[ "$1" == on ]]; then
    printf '#!/bin/sh\nprintf "%%s|%%s\\n" "$(id -un)" "$*" >> /tmp/suite-notify.log\n' > /usr/local/bin/notify-send
    chmod 755 /usr/local/bin/notify-send
  else
    rm -f /usr/local/bin/notify-send
  fi
}
notified() {
  local n; n=$({ wc -l < /tmp/suite-notify.log; } 2>/dev/null) || n=0
  if [[ "$n" == 1 ]]; then cat /tmp/suite-notify.log; else printf '%s records: %s' "$n" "$(paste -sd'#' /tmp/suite-notify.log 2>/dev/null)"; fi
}
# The Firefox part of a leak-check report (vpn-verify's section 10b).
ffsect()  { sed -n '/^10b\. Firefox tunnel/,/^11\. /p' <<<"$1"; }
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
for k in srvA srvB deskA deskB torrent ff ffx; do
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
# ffx: a server on the torrent tunnel's endpoint (server A), refused for Firefox.
mk_server wgA 51820 "$WG/srvA.key" 10.2.0.1/24 "$(cat $WG/deskA.pub)@10.2.0.2/32" "$(cat $WG/torrent.pub)@10.2.0.3/32" \
  "$(cat $WG/ffx.pub)@10.2.0.5/32"
mk_server wgB 51821 "$WG/srvB.key" 10.3.0.1/24 "$(cat $WG/deskB.pub)@10.3.0.2/32" "$(cat $WG/ff.pub)@10.3.0.4/32"

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
S((sys.argv[1] if len(sys.argv) > 1 else "0.0.0.0", int(sys.argv[2]) if len(sys.argv) > 2 else 8080), H).serve_forever()
PY
# Detached from this shell's output, or ssh would wait for them to exit.
ip netns exec provider python3 /tmp/whoami.py </dev/null >/dev/null 2>&1 &
ip netns exec provider dnsmasq --no-daemon --no-resolv --no-hosts --bind-interfaces \
  --listen-address=10.2.0.1 --listen-address=10.3.0.1 --address=/#/192.0.2.7 </dev/null >/dev/null 2>&1 &
# On the machine itself: a resolver on loopback, the stand-in for a local
# ad-blocking resolver (Chrome direct's DIRECT_DNS), knowing one name nobody
# else knows; and the "what is my IP" service on loopback, which shows
# whether loopback traffic keeps its 127.0.0.1 source.
lo_dns_start() {
  dnsmasq --no-daemon --no-resolv --no-hosts --bind-interfaces --listen-address=127.0.0.1 \
    --address=/direct-only.test/192.0.2.9 </dev/null >/dev/null 2>&1 &
  LO_DNS_PID=$!
}
lo_dns_start
python3 /tmp/whoami.py 127.0.0.1 </dev/null >/dev/null 2>&1 &
sleep 1
# HTTPServer looks up its own name between bind() and listen(); in the
# provider namespace that lookup can take seconds. Wait until both answer.
for i in $(seq 1 60); do
  ip netns exec provider curl -s --max-time 1 http://192.0.2.80:8080/ >/dev/null 2>&1 \
    && curl -s --max-time 1 http://127.0.0.1:8080/ >/dev/null 2>&1 && break
  sleep 0.5
done

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
# Firefox's packaged launcher entry, as Arch ships it: four Exec= lines, the
# actions with their arguments. (The VM is thrown away after the run.)
install -d /usr/share/applications
cat > /usr/share/applications/firefox.desktop <<'EOF'
[Desktop Entry]
Version=1.0
Name=Firefox
Exec=/usr/lib/firefox/firefox %u
Icon=firefox
Type=Application
Actions=new-window;new-private-window;open-profile-manager;

[Desktop Action new-window]
Name=New Window
Exec=/usr/lib/firefox/firefox --new-window %u

[Desktop Action new-private-window]
Name=New Private Window
Exec=/usr/lib/firefox/firefox --private-window %u

[Desktop Action open-profile-manager]
Name=Open the Profile Manager
Exec=/usr/lib/firefox/firefox --ProfileManager
EOF
FDESK=$UHOME/.local/share/applications/firefox.desktop
FMARK='# Written by omarchy-proton (Firefox tunnel). Removed when the tunnel is turned off.'


# ---------------------------------------------------------------------------
section "1. Fresh install through install.sh (a stock machine without wireguard-tools)"
no "wg is not installed yet" command -v wg
XDBUS_BEFORE=$(command -v xdg-dbus-proxy || true)
# Omarchy's DNS picker puts ipv6.dns on every wired/Wi-Fi profile, and
# NetworkManager then refuses ipv6.method=disabled unless it is cleared in the
# same call (seen on a real install, 0.3.5). Recreate that before installing.
PPROF=$(nmcli -g GENERAL.CONNECTION device show "$PHYS" 2>/dev/null | head -1)
nmcli connection modify "$PPROF" ipv6.method auto ipv6.dns "2606:4700:4700::1111" ipv6.ignore-auto-dns yes
is "the physical profile carries an IPv6 DNS server, as Omarchy's DNS picker leaves it" \
  "$(nmcli -g ipv6.dns connection show "$PPROF" | sed 's/\\:/:/g')" "2606:4700:4700::1111"
# A wired profile with static IPv6 (documentation addresses only): two
# addresses, a gateway, two routes (one with a metric and attributes), DNS and search
# domains. Not in use (no such interface): only its settings matter. The
# install must save every field it clears, and the rollback and the uninstall
# must put each one back exactly.
SPROF="suite: static6"   # a colon: names are escaped by nmcli -g; profiles go by uuid
nmcli connection add type ethernet con-name "$SPROF" ifname suitest0 autoconnect no ipv4.method disabled \
  ipv6.method manual ipv6.addresses "2001:db8:1::10/64, 2001:db8:1::11/64" ipv6.gateway 2001:db8:1::1 \
  ipv6.routes "2001:db8:2::/48 2001:db8:1::2, 2001:db8:3::/48 2001:db8:1::3 50 table=100 onlink=true" \
  ipv6.dns "2001:db8::53,2001:db8::54" ipv6.dns-search "example.test,lab.example.test" >/dev/null
SUUID=$(nmcli -g connection.uuid connection show "$SPROF")
V6F=(method dns dns-search addresses gateway routes)
declare -A SBEFORE
for f in "${V6F[@]}"; do SBEFORE[$f]=$(nmcli -g "ipv6.$f" connection show uuid "$SUUID"); done
SDUMP=$(nmcli -e no -f ipv6 connection show uuid "$SUUID")
is "the static profile has two addresses" "${SBEFORE[addresses]}" '2001\:db8\:1\:\:10/64, 2001\:db8\:1\:\:11/64'
is "and two routes, one with a metric and attributes" "${SBEFORE[routes]}" '2001\:db8\:2\:\:/48 2001\:db8\:1\:\:2, 2001\:db8\:3\:\:/48 2001\:db8\:1\:\:3 50 onlink=true table=100'
# same_static <description>: every IPv6 field of the static profile is as before.
same_static() {
  local f
  for f in "${V6F[@]}"; do
    is "$1: ipv6.$f" "$(nmcli -g "ipv6.$f" connection show uuid "$SUUID")" "${SBEFORE[$f]}"
  done
  is "$1: every other ipv6.* setting too" "$(nmcli -e no -f ipv6 connection show uuid "$SUUID")" "$SDUMP"
}
# A profile NetworkManager will not change (a stand-in nmcli in front of the
# real one refuses to modify it, for the install only): the install must
# warn, leave it exactly as it is and save nothing for it.
LPROF="suite locked"
nmcli connection add type ethernet con-name "$LPROF" ifname suitest1 autoconnect no ipv4.method disabled \
  ipv6.method auto ipv6.dns 2001:db8::53 >/dev/null
LUUID=$(nmcli -g connection.uuid connection show "$LPROF")
LDUMP=$(nmcli -e no -f ipv6 connection show uuid "$LUUID")
cat > /usr/local/sbin/nmcli <<EOF
#!/usr/bin/env bash
# suite.sh: NetworkManager refuses to change one profile.
if [[ " \$* " == *" modify "* && " \$* " == *" $LUUID "* ]]; then echo "Error: profile is locked (suite)" >&2; exit 1; fi
exec /usr/bin/nmcli "\$@"
EOF
chmod 755 /usr/local/sbin/nmcli
# An admin's own wrapper where the kit puts its Chrome wrapper: not the kit's,
# so setup must not replace it unless asked (--move-aside), and the
# uninstaller must put it back. And a qBittorrent launcher entry of the
# user's own, which setup must leave alone without --qbt-launcher.
BIN_MARK=$(bash -c '. "$1"; printf %s "$VPNKIT_BIN_MARK"' _ "$PLUGIN/system/lib/owned.sh")
printf '#!/bin/sh\n# the admin wrapper (suite)\nexec /usr/bin/google-chrome-stable --suite-admin-flag "$@"\n' > /usr/local/bin/google-chrome-stable
chmod 755 /usr/local/bin/google-chrome-stable
ADMIN_SUM=$(sha256sum < /usr/local/bin/google-chrome-stable)
QDESK=$UHOME/.local/share/applications/org.qbittorrent.qBittorrent.desktop
install -d -o $U -g $U "$UHOME/.local" "$UHOME/.local/share" "$UHOME/.local/share/applications"
printf '[Desktop Entry]\nType=Application\nName=My qBittorrent\nExec=/usr/bin/qbittorrent --suite-flag %%U\n' > "$QDESK"
chown $U:$U "$QDESK"
QDESK_SUM=$(sha256sum < "$QDESK")
in_terminal "$PLUGIN/install.sh" > /tmp/install0.log 2>&1; rc=$?
is "setup refuses to replace a file in /usr/local/bin that is not the kit's" "$rc" "1"
yes "and names it" grep -q "^    /usr/local/bin/google-chrome-stable" <(tr -d '\r' < /tmp/install0.log)
yes "and says how to go on, with the full path of install.sh" grep -qF -- "    $PLUGIN/install.sh --move-aside" /tmp/install0.log
yes "and that an edited copy of a kit command is to be deleted instead" grep -q "edited copy of omarchy-proton's own command" /tmp/install0.log
no "having changed nothing: no helpers" test -e /usr/local/lib/vpnkit
no "no sudoers rules" test -e /etc/sudoers.d/99-vpnkit
no "no packages (wg is still missing)" command -v wg
is "and the admin's file is untouched" "$(sha256sum < /usr/local/bin/google-chrome-stable)" "$ADMIN_SUM"
# The real path: the user runs install.sh in a terminal and types the sudo
# password once.
in_terminal "$PLUGIN/install.sh" --move-aside > /tmp/install.log 2>&1; rc=$?
is "install.sh --move-aside exits 0" "$rc" "0"
(( rc == 0 )) || sed 's/^/      /' /tmp/install.log | tail -25
rm -f /usr/local/sbin/nmcli
yes "missing dependency was installed (wg)" command -v wg
yes "missing dependency was installed (nft)" command -v nft
yes "Chrome direct's dependency is installed (xdg-dbus-proxy${XDBUS_BEFORE:+, was there before})" command -v xdg-dbus-proxy
yes "Chrome direct's xdg-open is installed, outside PATH" test -x /usr/local/lib/vpnkit/direct-bin/xdg-open
yes "Chrome direct's library is installed" test -r /usr/local/lib/vpnkit/direct.sh
for f in vpn-status vpn-toggle vpn-import vpn-verify vpn-check vpn-rescue vpn-diagnose vpnkit-pick vpnkit-sync vpnkit-import vpnkit-killswitch vpnkit-direct vpnkit-direct-rules vpn-direct direct-launch google-chrome-stable qbt-netns-up qbt-launch qbittorrent ff-netns-up ff-netns-down; do
  yes "installed /usr/local/bin/$f" test -x /usr/local/bin/$f
done
yes "the Firefox tunnel's library and unit are installed" test -r /usr/local/lib/vpnkit/netns.sh -a -f /etc/systemd/system/ff-netns.service
no "and the Firefox tunnel is not enabled: it is opt-in" systemctl is-enabled --quiet ff-netns.service
yes "the Chrome direct units are installed" test -f /etc/systemd/system/vpnkit-direct.service -a -f /etc/systemd/system/vpnkitdirect.slice
no "and Chrome direct is not enabled: it is opt-in" systemctl is-enabled --quiet vpnkit-direct.service
yes "sudoers file is valid" visudo -c -f /etc/sudoers.d/99-vpnkit
yes "the AI troubleshooting skill is installed" test -r /usr/local/lib/vpnkit/skills/diagnose-vpn/SKILL.md
is "--move-aside kept the admin's wrapper" "$(sha256sum < /usr/local/lib/vpnkit/moved-aside/google-chrome-stable)" "$ADMIN_SUM"
yes "and said so" grep -q "moved /usr/local/bin/google-chrome-stable (not the kit's)" /tmp/install.log
is "the kit's wrapper is in its place, with the kit's marker" "$(sed -n 2p /usr/local/bin/google-chrome-stable)" "$BIN_MARK"
is "the user's own qBittorrent launcher entry is left as it was" "$(sha256sum < "$QDESK")" "$QDESK_SUM"
yes "with a warning that it skips the tunnel" grep -q "which skips the torrent tunnel" /tmp/install.log
yes "and how to have it replaced" grep -q -- "install.sh --qbt-launcher" /tmp/install.log
no "this sudo has secure_path: no warning about it" grep -q "sudo has no secure_path" /tmp/install.log
LOGF=/run/user/$UID_T/vpnkit-install.log
is "the install log is readable by the user only" "$(stat -c '%a %U' "$LOGF" 2>/dev/null)" "600 $U"
# The user points their entry at the wrapper, as the warning says.
printf '[Desktop Entry]\nType=Application\nName=My qBittorrent\nExec=qbittorrent --suite-flag %%U\n' > "$QDESK"
QDESK_SUM=$(sha256sum < "$QDESK")

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
is "the only profile the installer could not change is the locked one" \
  "$(tr -d '\r' < /tmp/install.log | sed -n 's/.*Could not set ipv6.method=disabled on: \(.*\) (left unchanged)$/\1/p')" "$LPROF"
# saved <uuid> <field>: a field of the saved entry, through the kit's own reader.
saved() { bash -c '. /usr/local/lib/vpnkit/ipv6.sh; v6_field "$(v6_entry "$1" "$(v6_get "$1" connection.id)")" "$2"' _ "$@"; }
PUUID=$(nmcli -g connection.uuid connection show "$PPROF")
is "the physical profile's IPv6 method was saved for the uninstall" "$(saved "$PUUID" method)" "auto"
is "and its IPv6 DNS server" "$(saved "$PUUID" dns)" "2606:4700:4700::1111"
is "the static profile has ipv6.method=disabled" "$(nmcli -g ipv6.method connection show uuid "$SUUID")" "disabled"
is "and its addresses are cleared" "$(nmcli -g ipv6.addresses connection show uuid "$SUUID")" ""
for f in "${V6F[@]}"; do
  is "the static profile's ipv6.$f was saved exactly" "$(saved "$SUUID" "$f")" "$(sed 's/\\:/:/g' <<<"${SBEFORE[$f]}")"
done
yes "the installer says the static profile's settings are saved" grep -qF "\"$SPROF\" had static IPv6" /tmp/install.log
is "that profile is left exactly as it was" "$(nmcli -e no -f ipv6 connection show uuid "$LUUID")" "$LDUMP"
no "and nothing is saved for it" grep -qF -e "$LUUID" -e "$LPROF" /etc/vpnkit/ipv6-profiles.saved
is "the saved IPv6 settings are readable by all, writable by root" "$(stat -c '%a %U' /etc/vpnkit/ipv6-profiles.saved)" "644 root"
no "tester has no passwordless sudo in general" as_user sudo -n true
yes "tester may run the status helper without a password" as_user sudo -n /usr/local/bin/qbt-netns-status
no "tester may NOT run the leak check with arguments" as_user sudo -n /usr/local/bin/vpn-verify --fail-closed

# Real Google Chrome (from the [omarchy] repository) and a virtual X display,
# for the Chrome direct checks with the real browser (4c), while the VM still
# has the real internet. Chrome is installed after the kit, as a user would.
pacman -S --needed --noconfirm google-chrome xorg-server-xvfb > /tmp/chrome-install.log 2>&1
yes "real Google Chrome is installed for the Chrome direct checks" test -x /opt/google/chrome/chrome
yes "and Xvfb" command -v Xvfb
# Real Firefox (official repositories), for the Firefox tunnel checks with the
# real browser (end of 3b). Its launcher entry replaces the suite's fixture
# (section 0), which is put back: 3b checks the override against it.
cp /usr/share/applications/firefox.desktop /root/suite-firefox.desktop
pacman -S --needed --noconfirm --overwrite /usr/share/applications/firefox.desktop firefox > /tmp/firefox-install.log 2>&1
cp /root/suite-firefox.desktop /usr/share/applications/firefox.desktop; rm -f /root/suite-firefox.desktop
yes "real Firefox is installed for the Firefox tunnel checks" test -x /usr/lib/firefox/firefox

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
is "no Firefox server without a config in firefox/" "$(jq -r .firefox <<<"$OUT")" ""
is "the drop folder has a firefox/ subfolder, private" "$(stat -c '%a %U' "$DROP/firefox" 2>/dev/null)" "700 $U"
yes "and its README explains it" grep -q '^  firefox/' "$DROP/README.txt"
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
fake_notify on
no "tunnel down: qbittorrent refuses to start" as_user /usr/local/bin/qbittorrent 5
# Started without a terminal (the launcher, the panel), nobody sees stderr:
# qbt-launch's refusal is a desktop notification too, sent as the user.
is "and says so in a desktop notification, as the user" "$(notified)" \
  "$U|-a qBittorrent qBittorrent was not started tunnel is DOWN - refusing to launch qBittorrent."
fake_notify off
ip -n qbtvpn link set pqbt0 up; ip -n qbtvpn route replace default dev pqbt0
is "tunnel restored" "$(ip netns exec qbtvpn curl -4 -s --max-time 4 $LOOKUP)" "10.2.0.3"

# The namespace's resolver files must be in place before anything enters: a
# process that enters without them keeps the host's nsswitch.conf (resolve ->
# systemd-resolved over a Unix socket, outside the tunnel) for its whole life.
# Reported in the marketplace review of 0.3.6.
NSDIR=/etc/netns/qbtvpn; NSBAK=$(mktemp -d)
yes "vpnkit_netns_up writes the resolver files before the default route" \
  awk '/vpnkit_resolver_safe "\/etc\/netns/ && !r {r=NR} /route add default/ && !d {d=NR} END {exit !(r && d && r < d)}' /usr/local/lib/vpnkit/netns.sh
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

# A kernel started with ipv6.disable=1 has no /proc/sys/net/ipv6/conf (here it
# is hidden under a tmpfs, in a mount namespace of the test's own), and sysctl
# fails on those keys: the namespace must be built all the same. Checked from
# inside that mount namespace, where the new namespace's mount lives.
OUT=$(unshare --mount --propagation slave bash -c 'mount -t tmpfs suite-noipv6 /proc/sys/net/ipv6 || exit 9
  [[ -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ]] && exit 8
  /usr/local/bin/qbt-netns-up >/dev/null 2>&1 || exit 1
  ip netns exec qbtvpn curl -4 -s --max-time 6 "$1"' _ "$LOOKUP" 2>&1); rc=$?
is "on a kernel without IPv6, qbt-netns-up still builds a working namespace" "$rc:$OUT" "0:10.2.0.3"
# The builder is a library function (netns.sh): it must leave a caller's own
# EXIT trap in place (its temporary files are cleaned up in subshells), and
# refuse names that are not what they claim to be before building anything.
OUT=$(bash -c 'export PATH="/usr/local/sbin:/usr/local/bin:/usr/bin"; set -euo pipefail
  . /usr/local/lib/vpnkit/common.sh; . /usr/local/lib/vpnkit/netns.sh
  trap "echo caller-trap-ran" EXIT
  vpnkit_netns_up "$NS" "$WG_IF" "$QBT_CONF" qbtguard >/dev/null 2>&1' 2>&1); rc=$?
is "vpnkit_netns_up leaves its caller's EXIT trap in place" "$rc:$OUT" "0:caller-trap-ran"
is "(and built the torrent namespace)" "$(ip netns exec qbtvpn curl -4 -s --max-time 6 $LOOKUP)" "10.2.0.3"
OUT=$(bash -c 'export PATH="/usr/local/sbin:/usr/local/bin:/usr/bin"; set -euo pipefail
  . /usr/local/lib/vpnkit/common.sh; . /usr/local/lib/vpnkit/netns.sh
  trap "echo caller-trap-ran" EXIT
  vpnkit_netns_up suitebad "p\"x" "$QBT_CONF" qbtguard' 2>&1); rc=$?
is "vpnkit_netns_up refuses an interface name that is not one, and the caller's trap runs" "$rc:$(tail -1 <<<"$OUT")" "1:caller-trap-ran"
no "(nothing was built for it)" bash -c 'ip netns list | grep -qw suitebad || [[ -e /etc/netns/suitebad ]] && exit 0; exit 1'
systemctl restart qbt-netns.service
is "(rebuilt the normal way)" "$(ip netns exec qbtvpn curl -4 -s --max-time 6 $LOOKUP)" "10.2.0.3"
no "no temporary folder is left in /etc/netns" bash -c 'ls -d /etc/netns/.vpnkit-* 2>/dev/null | grep -q .'

# ---------------------------------------------------------------------------
section "3b. Firefox namespace"
# Opt-in: nothing exists for Firefox until a Firefox server is chosen.
no "no Firefox namespace before opt-in" ip netns exec ffvpn true
is "unit not enabled before opt-in" "$(systemctl is-enabled ff-netns.service 2>/dev/null)" "disabled"
no "no Firefox config before opt-in" test -e /etc/wireguard/vpnkit-firefox.conf
no "no Firefox launcher override before opt-in (setup wrote none)" test -e "$FDESK"
# The builder on its own: a config put where a chosen Firefox server goes.
conf /root/suite-ff.conf "$WG/ff.key" 10.3.0.4 10.3.0.1 "SE#4" "$WG/srvB.pub" 51821
install -m 600 /root/suite-ff.conf /etc/wireguard/vpnkit-firefox.conf; rm -f /root/suite-ff.conf
yes "with a Firefox config, ff-netns.service builds the namespace" systemctl start ff-netns.service
is "only lo and the tunnel are inside" "$(ip -n ffvpn -o link show | awk -F': ' '{print $2}' | sort | paste -sd,)" "lo,pff0"
is "Firefox namespace exits through its own server" "$(ip netns exec ffvpn curl -4 -s --max-time 4 $LOOKUP)" "10.3.0.4"
yes "DNS inside uses the in-tunnel resolver" ip netns exec ffvpn getent hosts only-in-tunnel.test
yes "its own default-deny table is loaded inside" ip netns exec ffvpn nft list table inet ffguard
is "its resolver files are in place, and nothing else" "$(ls -A /etc/netns/ffvpn | sort | paste -sd,)" "nsswitch.conf,resolv.conf"
is "unit retries" "$(systemctl show -p Restart --value ff-netns.service)" "on-failure"
is "the torrent tunnel is untouched" "$(ip netns exec qbtvpn curl -4 -s --max-time 4 $LOOKUP)" "10.2.0.3"
is "the host still exits from the home address" "$(myip)" "$HOME_IP"
ip -n ffvpn link set pff0 down
is "tunnel down: nothing leaves" "$(ip netns exec ffvpn curl -4 -s --max-time 3 $LOOKUP || echo none)" "none"
no "tunnel down: no DNS" ip netns exec ffvpn timeout 4 getent hosts only-in-tunnel.test
ip -n ffvpn link set pff0 up; ip -n ffvpn route replace default dev pff0
is "tunnel restored" "$(ip netns exec ffvpn curl -4 -s --max-time 4 $LOOKUP)" "10.3.0.4"
# Settings that would make the Firefox tunnel the torrent tunnel's are refused,
# and the torrent tunnel survives the attempt.
cp /etc/vpnkit/vpnkit.conf /root/suite-vpnkit.conf
printf 'FF_NS="qbtvpn"\n' >> /etc/vpnkit/vpnkit.conf
no "ff-netns-up refuses the torrent tunnel's namespace name" /usr/local/bin/ff-netns-up
/usr/local/bin/ff-netns-down >/dev/null 2>&1
is "(and ff-netns-down leaves the torrent namespace alone)" "$(ip netns exec qbtvpn curl -4 -s --max-time 4 $LOOKUP)" "10.2.0.3"
cp /root/suite-vpnkit.conf /etc/vpnkit/vpnkit.conf
printf 'FF_CONF="/etc/wireguard/vpnkit-torrent.conf"\n' >> /etc/vpnkit/vpnkit.conf
no "ff-netns-up refuses the torrent tunnel's config" /usr/local/bin/ff-netns-up
cp /root/suite-vpnkit.conf /etc/vpnkit/vpnkit.conf; rm -f /root/suite-vpnkit.conf
yes "stopping the unit removes the namespace" bash -c 'systemctl stop ff-netns.service && ! ip netns exec ffvpn true 2>/dev/null'
is "and leaves the torrent tunnel up" "$(ip netns exec qbtvpn curl -4 -s --max-time 4 $LOOKUP)" "10.2.0.3"
rm -f /etc/wireguard/vpnkit-firefox.conf
no "without its config, the unit fails: no namespace, nothing to fall back to" systemctl start ff-netns.service
no "(no Firefox namespace)" ip netns exec ffvpn true
systemctl reset-failed ff-netns.service 2>/dev/null; systemctl stop ff-netns.service 2>/dev/null

# Opting in: a config put in the drop folder's firefox/ becomes a server and is
# chosen for Firefox, which turns the tunnel on.
conf "$DROP/firefox/se-4.conf" "$WG/ff.key" 10.3.0.4 10.3.0.1 "SE#4" "$WG/srvB.pub" 51821
# A Firefox launcher entry of the user's own: kept aside, never lost.
install -d -o $U -g $U "$UHOME/.local" "$UHOME/.local/share" "$UHOME/.local/share/applications"
printf '[Desktop Entry]\nName=My own Firefox\nExec=/usr/lib/firefox/firefox -P work\n' > "$FDESK"; chown $U:$U "$FDESK"
is "status counts a config waiting in firefox/" "$(status .inbox)" "1"
OUT=$(as_user /usr/local/bin/vpn-import 2>&1); echo "$OUT" | sed 's/^/      /'
yes "import from firefox/ selects it for Firefox" grep -qx "Firefox tunnel: proton-se-4" <<<"$OUT"
is "the Firefox server is recorded" "$(cat /etc/vpnkit/firefox-server 2>/dev/null)" "proton-se-4"
no "the imported config is gone from firefox/" test -e "$DROP/firefox/se-4.conf"
is "the Firefox config is root-only" "$(stat -c '%a %U' /etc/wireguard/vpnkit-firefox.conf 2>/dev/null)" "600 root"
# The launcher entry follows the opt-in: the launcher, its actions and links
# from other apps start the wrapper, so they land in the namespace.
is "the launcher override carries the marker" "$(head -1 "$FDESK" 2>/dev/null)" "$FMARK"
is "the override's Exec is the wrapper" "$(grep -c '^Exec=' "$FDESK" 2>/dev/null):$(grep -cE '^Exec=/usr/local/bin/firefox( |$)' "$FDESK" 2>/dev/null)" "4:4"
is "actions keep their arguments" "$(grep '^Exec=' "$FDESK" 2>/dev/null | paste -sd'|' -)" \
  "Exec=/usr/local/bin/firefox %u|Exec=/usr/local/bin/firefox --new-window %u|Exec=/usr/local/bin/firefox --private-window %u|Exec=/usr/local/bin/firefox --ProfileManager"
is "the override is the user's file" "$(stat -c %U "$FDESK" 2>/dev/null)" "$U"
yes "a user's own launcher is backed up, not lost" bash -c "grep -l 'My own Firefox' $FDESK.bak.* | grep -q ."
is "the unit is enabled: the tunnel comes up at boot" "$(systemctl is-enabled ff-netns.service 2>/dev/null)" "enabled"
is "Firefox namespace exits through its own server" "$(ip netns exec ffvpn curl -4 -s --max-time 6 $LOOKUP)" "10.3.0.4"
is "only lo and the tunnel are inside" "$(ip -n ffvpn -o link show | awk -F': ' '{print $2}' | sort | paste -sd,)" "lo,pff0"
yes "DNS inside uses the in-tunnel resolver" ip netns exec ffvpn getent hosts only-in-tunnel.test
is "the torrent tunnel is untouched" "$(ip netns exec qbtvpn curl -4 -s --max-time 4 $LOOKUP)" "10.2.0.3"
OUT=$(as_user /usr/local/bin/vpn-toggle list 2>&1)
yes "vpn-toggle list names it as used for Firefox" bash -c 'grep -A1 "^Used for Firefox" <<<"$1" | grep -qx "  proton-se-4"' _ "$OUT"
# One server, one use; and the two tunnels never share an exit.
no "the Firefox server cannot carry regular traffic" as_user /usr/local/bin/vpn-toggle proton-se-4
no "(nothing was connected)" bash -c 'nmcli -t -f NAME connection show --active | grep -qx proton-se-4'
no "the Firefox server cannot carry torrents" as_user sudo -n /usr/local/bin/vpnkit-sync torrent proton-se-4
is "(the torrent tunnel stays on its server)" "$(cat /etc/vpnkit/torrent-server)" "proton-nl-3"
no "the torrent server cannot be chosen for Firefox" as_user sudo -n /usr/local/bin/vpnkit-sync firefox proton-nl-3
is "(Firefox stays on its server)" "$(cat /etc/vpnkit/firefox-server)" "proton-se-4"
# nl-5: another key on the torrent tunnel's endpoint; se-6: the key of
# proton-se-2 on the Firefox tunnel's endpoint.
conf "$DROP/nl-5.conf" "$WG/ffx.key"   10.2.0.5 10.2.0.1 "NL#5" "$WG/srvA.pub" 51820
conf "$DROP/se-6.conf" "$WG/deskB.key" 10.3.0.6 10.3.0.1 "SE#6" "$WG/srvB.pub" 51821
is "(two more servers imported)" "$(as_user sudo -n /usr/local/bin/vpnkit-sync sync | jq -r '.imported | sort | join(",")')" "proton-nl-5,proton-se-6"
OUT=$(as_user sudo -n /usr/local/bin/vpnkit-sync firefox proton-nl-5 2>&1); rc=$?
is "a server on the torrent tunnel's endpoint is refused for Firefox" "$rc" "1"
yes "and says why" grep -q "the torrent tunnel's exit" <<<"$OUT"
OUT=$(as_user sudo -n /usr/local/bin/vpnkit-sync firefox proton-se-6 2>&1); rc=$?
is "a server with another server's key is refused for Firefox" "$rc" "1"
yes "and names that server" grep -q "same key as the server proton-se-2" <<<"$OUT"
OUT=$(as_user sudo -n /usr/local/bin/vpnkit-sync torrent proton-se-6 2>&1); rc=$?
is "a server on the Firefox tunnel's endpoint is refused for torrents" "$rc" "1"
yes "and says why" grep -q "the Firefox tunnel's exit" <<<"$OUT"
is "(neither tunnel moved)" "$(cat /etc/vpnkit/torrent-server) $(cat /etc/vpnkit/firefox-server)" "proton-nl-3 proton-se-4"
as_user sudo -n /usr/local/bin/vpnkit-sync remove proton-nl-5 >/dev/null
as_user sudo -n /usr/local/bin/vpnkit-sync remove proton-se-6 >/dev/null
# A config carrying a tunnel's key is not imported at all: as a server it
# could be picked for regular traffic, and vpn-toggle (as the user) cannot read
# keys to stop that. Same key, other names and endpoints.
conf "$DROP/se-7.conf"         "$WG/ff.key"      10.3.0.7 10.3.0.1 "SE#7" "$WG/srvB.pub" 51821
conf "$DROP/nl-8.conf"         "$WG/torrent.key" 10.2.0.8 10.2.0.1 "NL#8" "$WG/srvA.pub" 51820
conf "$DROP/torrent/se-9.conf" "$WG/ff.key"      10.3.0.9 10.3.0.1 "SE#9" "$WG/srvB.pub" 51821
conf "$DROP/firefox/nl-10.conf" "$WG/torrent.key" 10.2.0.10 10.2.0.1 "NL#10" "$WG/srvA.pub" 51820
OUT=$(as_user sudo -n /usr/local/bin/vpnkit-sync sync)
is "configs with a tunnel's key are not imported" "$(jq -r '.imported | length' <<<"$OUT")" "0"
is "(and choose nothing)" "$(jq -r '.torrent + "|" + .firefox' <<<"$OUT")" "|"
is "a desktop config with the Firefox tunnel's key is refused, naming it" \
  "$(jq -r '.skipped[] | select(.file == "se-7.conf") | .reason' <<<"$OUT" | grep -c "same private key as the Firefox tunnel (server proton-se-4)")" "1"
is "a desktop config with the torrent tunnel's key is refused, naming it" \
  "$(jq -r '.skipped[] | select(.file == "nl-8.conf") | .reason' <<<"$OUT" | grep -c "same private key as the torrent tunnel (server proton-nl-3)")" "1"
is "a torrent config with the Firefox tunnel's key is refused" \
  "$(jq -r '.skipped[] | select(.file == "torrent/se-9.conf") | .reason' <<<"$OUT" | grep -c "the Firefox tunnel")" "1"
is "a Firefox config with the torrent tunnel's key is refused" \
  "$(jq -r '.skipped[] | select(.file == "firefox/nl-10.conf") | .reason' <<<"$OUT" | grep -c "the torrent tunnel")" "1"
no "(no server was made from them)" bash -c 'nmcli -g NAME connection show | grep -qxE "proton-(se-7|nl-8|se-9|nl-10)"'
is "(both tunnels stayed where they were)" "$(cat /etc/vpnkit/torrent-server) $(cat /etc/vpnkit/firefox-server)" "proton-nl-3 proton-se-4"
rm -f "$DROP/se-7.conf" "$DROP/nl-8.conf" "$DROP/torrent/se-9.conf" "$DROP/firefox/nl-10.conf"
no "the Firefox server cannot be removed" as_user sudo -n /usr/local/bin/vpnkit-sync remove proton-se-4
yes "(it is still there)" nmcli connection show proton-se-4
# Arguments of the passwordless rule: names only, validated.
no "names outside the kit cannot be chosen for Firefox" as_user sudo -n /usr/local/bin/vpnkit-sync firefox "Wired connection 1"
no "a path is not a name" as_user sudo -n /usr/local/bin/vpnkit-sync firefox ../../etc/shadow
no "nor an absolute one" as_user sudo -n /usr/local/bin/vpnkit-sync firefox /etc/wireguard/vpnkit-torrent.conf
no "no name at all is refused" as_user sudo -n /usr/local/bin/vpnkit-sync firefox
no "extra arguments are refused" as_user sudo -n /usr/local/bin/vpnkit-sync firefox off now
is "(Firefox stays on its server)" "$(cat /etc/vpnkit/firefox-server)" "proton-se-4"
# A Firefox inside the namespace would be stranded by a rebuild; one outside
# is not (it is refused at its next start instead). Stand-in binary.
FFBAK=""; [[ -e /usr/lib/firefox/firefox ]] && { FFBAK=$(mktemp); cp -a /usr/lib/firefox/firefox "$FFBAK"; }
install -D -m 755 /usr/bin/sleep /usr/lib/firefox/firefox
ip netns exec ffvpn runuser -u $U -- /usr/lib/firefox/firefox 600 </dev/null >/dev/null 2>&1 &
sleep 1
OUT=$(as_user sudo -n /usr/local/bin/vpnkit-sync firefox proton-se-4 2>&1); rc=$?
is "the Firefox server cannot be switched under a Firefox inside" "$rc:$(grep -c 'close Firefox first' <<<"$OUT")" "1:1"
OUT=$(as_user sudo -n /usr/local/bin/vpnkit-sync firefox off 2>&1); rc=$?
is "and the tunnel cannot be turned off under it" "$rc:$(grep -c 'close Firefox first' <<<"$OUT")" "1:1"
# A package update replaces the binary under a running Firefox: its program
# then reads "/usr/lib/firefox/firefox (deleted)", and still counts.
install -m 755 /usr/bin/sleep /usr/lib/firefox/firefox.suite-new
mv /usr/lib/firefox/firefox.suite-new /usr/lib/firefox/firefox
yes "(its program now shows as deleted)" bash -c 'for p in $(pgrep -x -u tester firefox); do readlink /proc/$p/exe; done | grep -qx "/usr/lib/firefox/firefox (deleted)"'
OUT=$(as_user sudo -n /usr/local/bin/vpnkit-sync firefox off 2>&1); rc=$?
is "an updated Firefox inside still blocks turning the tunnel off" "$rc:$(grep -c 'close Firefox first' <<<"$OUT")" "1:1"
pkill -x -u $U firefox; sleep 1
as_user /usr/lib/firefox/firefox 600 </dev/null >/dev/null 2>&1 &
sleep 1
yes "a Firefox outside the namespace does not stop a switch" as_user sudo -n /usr/local/bin/vpnkit-sync firefox proton-se-4
pkill -x -u $U firefox; sleep 1
if [[ -n "$FFBAK" ]]; then cp -a "$FFBAK" /usr/lib/firefox/firefox; rm -f "$FFBAK"; else rm -rf /usr/lib/firefox; fi
# Opting out, without uninstalling.
is "firefox off" "$(as_user sudo -n /usr/local/bin/vpnkit-sync firefox off 2>&1)" "firefox: off"
no "the Firefox namespace is gone" ip netns exec ffvpn true
is "the unit is disabled" "$(systemctl is-enabled ff-netns.service 2>/dev/null)" "disabled"
no "the Firefox config is gone" test -e /etc/wireguard/vpnkit-firefox.conf
no "the record of its server is gone" test -e /etc/vpnkit/firefox-server
no "the namespace's resolver files are gone" test -e /etc/netns/ffvpn
no "no launcher override while off" grep -qxF "$FMARK" "$FDESK"
is "and the user's own launcher entry is back, unchanged" "$(cat "$FDESK" 2>/dev/null)" \
  "$(printf '[Desktop Entry]\nName=My own Firefox\nExec=/usr/lib/firefox/firefox -P work')"
no "(its backup was moved back, not copied)" bash -c "ls $FDESK.bak.* 2>/dev/null | grep -q ."
as_user /usr/local/bin/vpn-firefox-launcher >/dev/null 2>&1
yes "a launcher entry without the marker is never removed" grep -q 'My own Firefox' "$FDESK"
rm -f "$FDESK" "$FDESK".bak.*
yes "the server itself stays" nmcli connection show proton-se-4
is "the torrent tunnel is untouched" "$(ip netns exec qbtvpn curl -4 -s --max-time 4 $LOOKUP)" "10.2.0.3"
yes "firefox off again changes nothing and succeeds" as_user sudo -n /usr/local/bin/vpnkit-sync firefox off
# Back on for the rest of the suite: a server chosen directly.
is "a server can be chosen for Firefox directly" "$(as_user sudo -n /usr/local/bin/vpnkit-sync firefox proton-se-4 2>&1)" "firefox: proton-se-4"
is "Firefox exits through it again" "$(ip netns exec ffvpn curl -4 -s --max-time 6 $LOOKUP)" "10.3.0.4"
is "choosing it directly (as from a terminal) writes the launcher override too" "$(head -1 "$FDESK" 2>/dev/null)" "$FMARK"

# Starting Firefox: the wrapper (/usr/local/bin/firefox) and the root launcher
# (ff-launch). Stand-in binary again; processes are found by their program.
FFBAK=""; [[ -e /usr/lib/firefox/firefox ]] && { FFBAK=$(mktemp); cp -a /usr/lib/firefox/firefox "$FFBAK"; }
install -D -m 755 /usr/bin/sleep /usr/lib/firefox/firefox
ffpids() { local p; for p in $(pgrep -u $U); do [[ "$(readlink /proc/$p/exe 2>/dev/null)" == /usr/lib/firefox/firefox ]] && echo "$p"; done; return 0; }
ffkill() { local p; for p in $(ffpids); do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done; sleep 1; }
FFNSINO=$(stat -Lc %i /run/netns/ffvpn)
HOSTINO=$(stat -Lc %i /proc/self/ns/net)
as_user /usr/local/bin/firefox 600 </dev/null >/dev/null 2>&1 &
sleep 2
P=$(ffpids | head -1)
is "Firefox started through the wrapper is inside the namespace" "$(stat -Lc %i /proc/${P:-none}/ns/net 2>/dev/null)" "$FFNSINO"
is "and runs as the desktop user, not root" "$(ps -o user= -p "${P:-1}" | tr -d ' ')" "$U"
yes "and sees the namespace's resolver files" bash -c '. /usr/local/lib/vpnkit/common.sh; vpnkit_resolver_safe "/proc/$1/root/etc"' _ "${P:-none}"
as_user /usr/local/bin/firefox 600 </dev/null >/dev/null 2>&1 &
sleep 2
is "a second start lands inside too (nothing outside)" "$(for p in $(ffpids); do stat -Lc %i /proc/$p/ns/net; done | sort -u | paste -sd, -)" "$FFNSINO"
# The status and the leak check: the Firefox tunnel and where Firefox runs.
is "status: Firefox tunnel up" "$(status .ff_tunnel)" "true"
is "status: Firefox exit" "$(status .ff_ip)" "10.3.0.4"
is "status: its server" "$(status .ff_conn)" "proton-se-4"
is "status: its interface and namespace" "$(status '.firefox_if + " " + .firefox_ns')" "pff0 ffvpn"
is "status: Firefox runs, inside, protected" "$(status '[.ff_running, .ff_protected, .ff_unprotected] | map(tostring) | join(",")')" "true,true,false"
OUT=$(as_user /usr/local/bin/vpn-status 2>&1)
yes "vpn-status shows the Firefox tunnel" grep -q "^Firefox tunnel     : UP · se-4 · exit 10.3.0.4 · interface pff0 (inside ffvpn)" <<<"$OUT"
yes "and Firefox verified inside it" grep -q "^Firefox app        : running, VERIFIED inside the Firefox namespace" <<<"$OUT"
OUT=$(vpn-verify 2>&1)
is "the leak check passes the Firefox tunnel with Firefox inside" "$(ffsect "$OUT" | grep -c FAIL)" "0"
ffsect "$OUT" | grep FAIL | sed 's/^/      /'
yes "(it checked Firefox's resolver files)" grep -qE "PASS.*Firefox \(pid [0-9]+\) runs inside the Firefox namespace and resolves names only through the tunnel" <<<"$OUT"
yes "(and its own exit)" grep -q "PASS.*Firefox exits from its own address (10.3.0.4), not the host's nor the torrent tunnel's" <<<"$OUT"
yes "(and that the launcher reaches the wrapper)" grep -q "PASS.*the Firefox launcher and links reach the wrapper (/usr/local/bin/firefox)" <<<"$OUT"
ffkill
# Firefox starts its sandboxed children (content, RDD, utility, extension
# processes: the same program) in network namespaces of their own. They are
# not a Firefox outside the tunnel, so a second start must not be refused.
# A bash stand-in with such a child (unshare -Urn, as Firefox's sandbox does).
install -m 755 /usr/bin/bash /usr/lib/firefox/firefox
as_user /usr/local/bin/firefox -c 'unshare -Urn /usr/lib/firefox/firefox -c "sleep 600; :"; :' </dev/null >/dev/null 2>&1 &
sleep 2
FFMAIN=""; FFCHILD=""
for p in $(ffpids); do
  pp=$(awk '/^PPid:/ {print $2}' /proc/$p/status 2>/dev/null)
  if [[ "$(readlink /proc/${pp:-0}/exe 2>/dev/null)" == /usr/lib/firefox/firefox ]]; then FFCHILD=$p; else FFMAIN=$p; fi
done
is "(the stand-in runs inside the namespace)" "$(stat -Lc %i /proc/${FFMAIN:-none}/ns/net 2>/dev/null)" "$FFNSINO"
yes "(and its sandboxed child has a network namespace of its own)" bash -c '[[ -n "$1" ]] && i=$(stat -Lc %i /proc/$1/ns/net) && [[ "$i" != "$2" && "$i" != "$3" ]]' _ "$FFCHILD" "$FFNSINO" "$HOSTINO"
OUT=$(as_user /usr/local/bin/firefox -c 'exit 0' 2>&1); rc=$?
is "a sandboxed child is not a Firefox outside: the wrapper starts Firefox" "$rc:$(grep -c 'NOT started' <<<"$OUT")" "0:0"
OUT=$(as_user sudo -n /usr/local/bin/ff-launch -c 'exit 0' 2>&1); rc=$?
is "and so does ff-launch" "$rc:$(grep -c 'ff-launch:' <<<"$OUT")" "0:0"
is "status: protected, nothing outside" "$(status '[.ff_protected, .ff_unprotected] | map(tostring) | join(",")')" "true,false"
OUT=$(vpn-verify 2>&1)
is "the leak check does not count the sandboxed child" "$(ffsect "$OUT" | grep -c FAIL)" "0"
ffsect "$OUT" | grep FAIL | sed 's/^/      /'
ffkill
as_user /usr/lib/firefox/firefox -c 'sleep 600; :' </dev/null >/dev/null 2>&1 &
sleep 1
OUT=$(as_user /usr/local/bin/firefox -c 'exit 0' 2>&1); rc=$?
is "(a stand-in started outside is still refused)" "$rc:$(grep -c 'already running outside' <<<"$OUT")" "1:1"
ffkill
install -m 755 /usr/bin/sleep /usr/lib/firefox/firefox
# A Firefox already outside the namespace would be handed what a new one opens.
as_user /usr/lib/firefox/firefox 600 </dev/null >/dev/null 2>&1 &
sleep 1
P=$(ffpids | head -1)
OUT=$(as_user /usr/local/bin/firefox 5 2>&1); rc=$?
is "with one outside, the wrapper refuses" "$rc" "1"
yes "and names its pid" grep -q "pid $P" <<<"$OUT"
OUT=$(as_user sudo -n /usr/local/bin/ff-launch 5 2>&1); rc=$?
is "with one outside, ff-launch refuses, naming it" "$rc:$(grep -c "already running outside the namespace (pid $P)" <<<"$OUT")" "1:1"
no "with one outside, the wrapper refuses even from inside the namespace" ip netns exec ffvpn runuser -u "$U" -- /usr/local/bin/firefox 5
is "(no second Firefox was started)" "$(ffpids | wc -l)" "1"
is "status: a Firefox outside the namespace is unprotected" "$(status .ff_unprotected)" "true"
is "(and named)" "$(status '.ff_pids | join(",")')" "$P"
OUT=$(vpn-verify 2>&1); rc=$?
is "the leak check fails on a Firefox outside" "$rc" "1"
yes "and names its pid" grep -q "FAIL.*Firefox is running OUTSIDE the Firefox tunnel (pid $P)" <<<"$OUT"
ffkill
# Any Firefox build counts, not only the packaged one: here a stand-in named
# firefox in /opt/firefox (where Mozilla's tarball would be), outside.
install -D -m 755 /usr/bin/bash /opt/firefox/firefox
as_user /opt/firefox/firefox -c 'sleep 600; :' </dev/null >/dev/null 2>&1 &
sleep 1
OP=$(pgrep -u $U -f '^/opt/firefox/firefox -c' | head -1)
OUT=$(as_user /usr/local/bin/firefox 5 2>&1); rc=$?
is "another Firefox build outside: the wrapper refuses, naming it" "$rc:$(grep -c "pid ${OP:-none}" <<<"$OUT")" "1:1"
OUT=$(as_user sudo -n /usr/local/bin/ff-launch 5 2>&1); rc=$?
is "and ff-launch refuses" "$rc:$(grep -c "already running outside the namespace (pid ${OP:-none})" <<<"$OUT")" "1:1"
is "status: it is unprotected, and named" "$(status '[.ff_unprotected, (.ff_pids | join(","))] | @json')" "[true,\"${OP:-none}\"]"
OUT=$(vpn-verify 2>&1); rc=$?
is "the leak check fails on it" "$rc" "1"
yes "and names it" grep -q "FAIL.*Firefox is running OUTSIDE the Firefox tunnel (pid ${OP:-none})" <<<"$OUT"
[[ -n "$OP" ]] && { pkill -P "$OP" 2>/dev/null; kill "$OP" 2>/dev/null; }
sleep 1; rm -rf /opt/firefox
# Fail closed: no route, no resolver files, no namespace: no Firefox.
ip -n ffvpn link set pff0 down
fake_notify on
no "tunnel down: Firefox refuses to start" as_user /usr/local/bin/firefox 5
# From the launcher or a link nobody sees stderr: ff-launch's refusal is a
# desktop notification too, sent as the user, never as root.
is "and says so in a desktop notification, as the user" "$(notified)" \
  "$U|-a Firefox Firefox was not started the Firefox tunnel is DOWN - refusing to launch Firefox."
fake_notify on
no "tunnel down: ff-launch refuses" as_user sudo -n /usr/local/bin/ff-launch 5
is "(ff-launch on its own too)" "$(notified)" \
  "$U|-a Firefox Firefox was not started the Firefox tunnel is DOWN - refusing to launch Firefox."
# From a terminal the refusal is on the screen: no notification then.
fake_notify on
OUT=$(as_user script -qec "/usr/local/bin/firefox 5" /dev/null 2>&1)
yes "(on a terminal, the wrapper refuses too)" grep -q "refusing to launch Firefox" <<<"$OUT"
is "and sends no notification" "$(notified)" "0 records: "
fake_notify off
ip -n ffvpn link set pff0 up; ip -n ffvpn route replace default dev pff0
is "(tunnel restored)" "$(ip netns exec ffvpn curl -4 -s --max-time 4 $LOOKUP)" "10.3.0.4"
# One server can sit behind several endpoints: the leak check compares the
# addresses the two tunnels really leave from. Here the provider makes the
# torrent tunnel's requests arrive from the Firefox tunnel's address.
ip netns exec provider nft -f - <<'EOF'
table ip suite_sameexit {
  chain in { type nat hook input priority 100; ip saddr 10.2.0.3 snat to 10.3.0.4; }
}
EOF
is "(torrents now seem to leave from the Firefox tunnel's address)" "$(ip netns exec qbtvpn curl -4 -s --max-time 4 $LOOKUP)" "10.3.0.4"
OUT=$(vpn-verify 2>&1); rc=$?
is "the leak check fails when both tunnels share an exit" "$rc" "1"
yes "and says so" grep -q "FAIL.*Firefox and torrents leave from the same address (10.3.0.4)" <<<"$OUT"
ip netns exec provider nft delete table ip suite_sameexit
is "(torrents leave from their own address again)" "$(ip netns exec qbtvpn curl -4 -s --max-time 4 $LOOKUP)" "10.2.0.3"
NSBAK=$(mktemp -d); mv /etc/netns/ffvpn/nsswitch.conf "$NSBAK/"
no "without the namespace's nsswitch.conf, ff-launch refuses" as_user sudo -n /usr/local/bin/ff-launch 5
no "and so does the wrapper" as_user /usr/local/bin/firefox 5
no "and the wrapper refuses inside a namespace entered without them" ip netns exec ffvpn runuser -u "$U" -- /usr/local/bin/firefox 5
# A Firefox that entered too early (not through the kit) is caught by the leak check.
ip netns exec ffvpn runuser -u "$U" -- /usr/lib/firefox/firefox 600 </dev/null >/dev/null 2>&1 &
sleep 1
mv "$NSBAK/nsswitch.conf" /etc/netns/ffvpn/; rm -rf "$NSBAK"
OUT=$(vpn-verify 2>&1); rc=$?
is "a Firefox that entered before the resolver files existed fails the leak check" "$rc" "1"
yes "and is named" grep -qE "FAIL.*Firefox \(pid [0-9]+\) sees the host's DNS settings" <<<"$OUT"
ffkill
yes "inside the namespace, the wrapper starts Firefox directly" ip netns exec ffvpn runuser -u "$U" -- /usr/local/bin/firefox 1
systemctl stop ff-netns.service
fake_notify on
OUT=$(as_user /usr/local/bin/firefox 5 2>&1); rc=$?
is "no namespace (tunnel on): the wrapper refuses" "$rc" "1"
is "(and notifies)" "$(notified)" \
  "$U|-a Firefox Firefox was not started The Firefox tunnel is not running. Start it: sudo systemctl start ff-netns.service"
fake_notify off
yes "and says how to start it" grep -q "systemctl start ff-netns.service" <<<"$OUT"
no "and so does ff-launch" as_user sudo -n /usr/local/bin/ff-launch 5
is "(nothing was started)" "$(ffpids | wc -l)" "0"
systemctl start ff-netns.service
is "(namespace back)" "$(ip netns exec ffvpn curl -4 -s --max-time 6 $LOOKUP)" "10.3.0.4"
FFNSINO=$(stat -Lc %i /run/netns/ffvpn)
# Without its config the tunnel is off for ff-launch, even with the namespace up.
mv /etc/wireguard/vpnkit-firefox.conf /root/suite-ffconf
OUT=$(as_user sudo -n /usr/local/bin/ff-launch 5 2>&1); rc=$?
is "without its config, ff-launch refuses (the tunnel is off), namespace up or not" "$rc:$(grep -c 'tunnel is off' <<<"$OUT")" "1:1"
mv /root/suite-ffconf /etc/wireguard/vpnkit-firefox.conf
# vpnkit.conf naming the torrent namespace for Firefox.
cp /etc/vpnkit/vpnkit.conf /root/suite-vpnkit.conf
printf 'FF_NS="qbtvpn"\n' >> /etc/vpnkit/vpnkit.conf
OUT=$(as_user sudo -n /usr/local/bin/ff-launch 5 2>&1); rc=$?
is "ff-launch refuses FF_NS naming the torrent namespace" "$rc:$(grep -c "other than the torrent tunnel's" <<<"$OUT")" "1:1"
cp /root/suite-vpnkit.conf /etc/vpnkit/vpnkit.conf; rm -f /root/suite-vpnkit.conf
is "(nothing was started)" "$(ffpids | wc -l)" "0"
# Any one of record, namespace and boot unit means on: a half-removed tunnel
# never lets Firefox out.
mv /etc/vpnkit/firefox-server /root/suite-ffrec
as_user /usr/local/bin/firefox 600 </dev/null >/dev/null 2>&1 &
sleep 2
is "without the record (namespace and unit left), the wrapper still enters the namespace" \
  "$(for p in $(ffpids); do stat -Lc %i /proc/$p/ns/net; done | sort -u | paste -sd, -)" "$FFNSINO"
ffkill
systemctl stop ff-netns.service
OUT=$(as_user /usr/local/bin/firefox 5 2>&1); rc=$?
is "with only the boot unit left, the wrapper refuses" "$rc:$(grep -c 'NOT started' <<<"$OUT")" "1:1"
is "(nothing was started)" "$(ffpids | wc -l)" "0"
mv /root/suite-ffrec /etc/vpnkit/firefox-server
systemctl start ff-netns.service
FFNSINO=$(stat -Lc %i /run/netns/ffvpn)
# The passwordless rule: the binary is fixed, and it runs as the user. A
# stand-in that takes any arguments and keeps running (yes) shows what ran.
install -m 755 /usr/bin/yes /usr/lib/firefox/firefox
as_user sudo -n /usr/local/bin/ff-launch -- /usr/bin/touch /root/suite-ff-abuse </dev/null >/dev/null 2>&1 &
sleep 2
P=$(ffpids | head -1)
is "ff-launch cannot run another binary" "$(readlink /proc/${P:-none}/exe 2>/dev/null)" "/usr/lib/firefox/firefox"
is "(it runs as the desktop user, not root)" "$(ps -o user= -p "${P:-1}" | tr -d ' ')" "$U"
is "(inside the namespace)" "$(stat -Lc %i /proc/${P:-none}/ns/net 2>/dev/null)" "$FFNSINO"
no "(the program it was given did not run)" test -e /root/suite-ff-abuse
ffkill
install -m 755 /usr/bin/sleep /usr/lib/firefox/firefox
# Opted out: Firefox is plain Firefox again, as before the kit.
as_user sudo -n /usr/local/bin/vpnkit-sync firefox off >/dev/null 2>&1
as_user /usr/local/bin/firefox 600 </dev/null >/dev/null 2>&1 &
sleep 1
P=$(ffpids | head -1)
no "no override while off" test -e "$FDESK"
is "firefox off: the wrapper execs the real binary" "$(stat -Lc %i /proc/${P:-none}/ns/net 2>/dev/null)" "$HOSTINO"
is "(directly, as the user)" "$(ps -o user= -p "${P:-1}" | tr -d ' ')" "$U"
is "firefox off: status says the Firefox tunnel is off" "$(status '[.ff_configured, .ff_unprotected] | map(tostring) | join(",")')" "false,false"
yes "and vpn-status says it is not set up" bash -c 'grep -q "^Firefox tunnel     : not set up" <<<"$1"' _ "$(as_user /usr/local/bin/vpn-status 2>&1)"
OUT=$(vpn-verify 2>&1)
is "firefox off: no Firefox FAIL lines in the leak check (a Firefox runs, on the regular connection)" "$(ffsect "$OUT" | grep -c FAIL)" "0"
yes "(one line says it is off)" grep -q "SKIP.*no Firefox tunnel" <<<"$OUT"
ffkill
no "firefox off: ff-launch refuses" as_user sudo -n /usr/local/bin/ff-launch 5
is "(back on for the rest of the suite)" "$(as_user sudo -n /usr/local/bin/vpnkit-sync firefox proton-se-4 2>&1)" "firefox: proton-se-4"
if [[ -n "$FFBAK" ]]; then cp -a "$FFBAK" /usr/lib/firefox/firefox; rm -f "$FFBAK"; else rm -rf /usr/lib/firefox; fi

# Real Firefox, headed on a virtual X display, started the way the user
# starts it (the wrapper on PATH). Its sandboxed children (content, RDD,
# utility processes) have network namespaces of their own: none of them may
# count as a Firefox outside the tunnel, anywhere.
cat > /tmp/fflog.py <<'PYLOG'
import http.server, socketserver
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open("/tmp/ff-seen.log", "a") as f:
            f.write("%s %s\n" % (self.client_address[0], self.path))
        body = b"<html><body>ok</body></html>"
        self.send_response(200); self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body))); self.send_header("Connection", "close")
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True; allow_reuse_address = True
S(("0.0.0.0", 8082), H).serve_forever()
PYLOG
rm -f /tmp/ff-seen.log /tmp/ff-real.log
ip netns exec provider python3 /tmp/fflog.py </dev/null >/dev/null 2>&1 &
FFLOG_PID=$!
as_user Xvfb :98 -nolisten tcp </dev/null >/dev/null 2>&1 &
FFX_PID=$!
sleep 1
FFNSINO=$(stat -Lc %i /run/netns/ffvpn)
ffseen() {  # ffseen <path>: the client address of the first request for <path>, waiting up to 60 s
  local i; for i in $(seq 1 120); do grep -q " $1\$" /tmp/ff-seen.log 2>/dev/null && break; sleep 0.5; done
  awk -v p="$1" '$2 == p {print $1; exit}' /tmp/ff-seen.log 2>/dev/null
}
ffmain() {  # Firefox's main processes: its program, with a parent that is not Firefox
  local p pp; for p in $(ffpids); do
    pp=$(awk '/^PPid:/ {print $2}' /proc/$p/status 2>/dev/null)
    [[ "$(readlink /proc/${pp:-0}/exe 2>/dev/null)" == /usr/lib/firefox/firefox ]] || echo "$p"
  done
}
FFENV=(HOME=$UHOME USER=$U XDG_RUNTIME_DIR=/run/user/$UID_T PATH="$PATH" DISPLAY=:98 MOZ_ENABLE_WAYLAND=0)
runuser -u $U -- env "${FFENV[@]}" /usr/local/bin/firefox http://192.0.2.80:8082/ff-first </dev/null >>/tmp/ff-real.log 2>&1 &
is "real Firefox: a page it opens leaves through the Firefox server" "$(ffseen /ff-first)" "10.3.0.4"
is "real Firefox: one main process, inside the namespace" "$(for p in $(ffmain); do stat -Lc %i /proc/$p/ns/net; done | paste -sd, -)" "$FFNSINO"
FFNSES=$(for p in $(ffpids); do stat -Lc %i /proc/$p/ns/net; done)
echo "      (real Firefox: $(ffpids | wc -l) processes in $(sort -u <<<"$FFNSES" | wc -l) network namespaces)"
no "real Firefox: none of its processes is in the host's network namespace" grep -qx "$HOSTINO" <<<"$FFNSES"
is "status: real Firefox protected, nothing outside" "$(status '[.ff_running, .ff_protected, .ff_unprotected] | map(tostring) | join(",")')" "true,true,false"
OUT=$(vpn-verify 2>&1)
is "the leak check passes real Firefox and its children" "$(ffsect "$OUT" | grep -c FAIL)" "0"
ffsect "$OUT" | grep FAIL | sed 's/^/      /'
# A second start (a new window, or a link from another app) goes to the
# running Firefox and is not refused.
OUT=$(timeout 90 runuser -u $U -- env "${FFENV[@]}" /usr/local/bin/firefox --new-window http://192.0.2.80:8082/ff-second </dev/null 2>&1); rc=$?
is "real Firefox: a second start is not refused" "$rc:$(grep -cE 'NOT started|ff-launch:' <<<"$OUT")" "0:0"
is "its page leaves through the Firefox server too" "$(ffseen /ff-second)" "10.3.0.4"
is "(handed to the running Firefox: still one main process)" "$(ffmain | wc -l)" "1"
(( rc == 0 )) || { echo "      second start: $OUT" | head -5; tail -5 /tmp/ff-real.log | sed 's/^/      /'; }
for p in $(ffmain); do kill "$p" 2>/dev/null; done
for i in $(seq 1 20); do [[ -z "$(ffpids)" ]] && break; sleep 0.5; done
ffkill
kill "$FFX_PID" "$FFLOG_PID" 2>/dev/null

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
OUT=$(as_user sudo -n /usr/local/bin/vpnkit-sync firefox proton-ca-1 2>&1); rc=$?
is "the server carrying regular traffic cannot be chosen for Firefox" "$rc" "1"
yes "(refused because it carries regular traffic)" grep -q "carries your regular traffic" <<<"$OUT"
is "the Firefox tunnel stayed where it was" "$(cat /etc/vpnkit/firefox-server)" "proton-se-4"
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
is "the Firefox tunnel is untouched" "$(ip netns exec ffvpn curl -4 -s --max-time 4 $LOOKUP)" "10.3.0.4"

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
is "off: status" "$(direct status | jq -c .)" '{"enabled":false,"unit":false,"rules":false,"dns_ok":true,"ssh":{"enabled":false,"ports":"22","rules":false}}'
sudo_refuses "the passwordless rule allows only on, off and status" /usr/local/bin/vpnkit-direct bogus
sudo_refuses "and nothing after them" /usr/local/bin/vpnkit-direct on now
sudo_refuses "the rules helper is not passwordless" /usr/local/bin/vpnkit-direct-rules up
/usr/local/bin/vpnkit-direct bogus >/dev/null 2>&1; rc=$?
is "the helper itself refuses anything else" "$rc" "2"

direct_dns 127.0.0.1
is "on" "$(direct on 2>&1)" "direct: on"
yes "the slice's cgroup exists" test -d "$DSLICE"
is "status: on" "$(direct status | jq -c .)" '{"enabled":true,"unit":true,"rules":true,"dns_ok":true,"ssh":{"enabled":false,"ports":"22","rules":false}}'
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

# Tailnet addresses stay on Tailscale's table: the rule is there while on,
# also when Tailscale (table 52) is not, and is part of "rules loaded".
no "(no Tailscale table here)" bash -c 'ip -4 route show table 52 2>/dev/null | grep -q .'
yes "the tailnet rule is there anyway" tailnet_rule
is "and the slice still gets out from home (the empty table falls through)" "$(slice_ip)" "$HOME_IP"
ip -4 rule del priority 89 fwmark 51821 to 100.64.0.0/10 table 52
is "without the tailnet rule, the rules count as not loaded" "$(direct status | jq -r .rules)" "false"
/etc/NetworkManager/dispatcher.d/50-vpnkit "$PHYS" up
yes "a link coming up loads it again" tailnet_rule
is "status: rules loaded again" "$(direct status | jq -r .rules)" "true"

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
# The real Chrome (installed in section 1) waits aside until 4c.
mv /usr/bin/google-chrome-stable /usr/bin/google-chrome-stable.real
mv /opt/google/chrome /opt/google/chrome.real
cat > /usr/bin/google-chrome-stable <<EOF
#!/usr/bin/env bash
echo \$\$ > /tmp/chrome-probe.pid
echo "HOME=\$HOME XDG_CONFIG_HOME=\${XDG_CONFIG_HOME:-} ARGS=\$*" > /tmp/chrome-probe.env
env > /tmp/chrome-probe.fullenv
echo "\$(curl -4 -s --max-time 4 $LOOKUP) \$(getent hosts direct-only.test | awk '{print \$1}') \$(getent hosts only-in-tunnel.test >/dev/null && echo leak || echo noleak) \$(id -un)" > /tmp/chrome-probe
exec /opt/google/chrome/chrome 600
EOF
chmod 755 /usr/bin/google-chrome-stable
install -d /opt/google/chrome; cp /usr/bin/sleep /opt/google/chrome/chrome
CHROME_PID=""
CHROME_ENV=()   # extra NAME=value for the caller's environment
chrome_start() {  # start "Chrome" as the user through the wrapper; wait for its probe
  rm -f /tmp/chrome-probe /tmp/chrome-probe.pid /tmp/chrome-probe.env /tmp/chrome-probe.fullenv
  as_user env "${CHROME_ENV[@]}" /usr/local/bin/google-chrome-stable "$@" </dev/null >/dev/null 2>&1 &
  local i; for i in $(seq 1 40); do [[ -s /tmp/chrome-probe ]] && break; sleep 0.5; done
  CHROME_PID=$(cat /tmp/chrome-probe.pid 2>/dev/null)
  # Until the script has become "Chrome", it is a shell in the slice.
  for i in $(seq 1 20); do
    [[ "$(readlink "/proc/${CHROME_PID:-none}/exe" 2>/dev/null)" == /opt/google/chrome/chrome ]] && break; sleep 0.25
  done
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

# Chrome's session bus is a filtered proxy without the user's service manager
# (real Chrome would ask it to move Chrome out of the slice), and the first
# xdg-open in its PATH is the kit's.
envof() { sed -n "s/^$1=//p" /tmp/chrome-probe.fullenv 2>/dev/null; }
BUSA=$(envof DBUS_SESSION_BUS_ADDRESS); BUSS=${BUSA#unix:path=}
yes "Chrome's session bus is the kit's proxy" grep -qE "^unix:path=/run/user/$UID_T/vpnkit-direct/bus-[0-9]+$" <<<"$BUSA"
yes "its socket is there while Chrome runs" test -S "$BUSS"
PROXY_PID=$(pgrep -u $U -x xdg-dbus-proxy | head -1)
yes "the proxy runs as the user" test -n "$PROXY_PID"
no "outside Chrome direct's slice" grep -q vpnkitdirect.slice "/proc/${PROXY_PID:-none}/cgroup"
yes "(the user's service manager is on the real session bus)" \
  as_user busctl --user call org.freedesktop.systemd1 /org/freedesktop/systemd1 org.freedesktop.DBus.Peer Ping
yes "the bus proxy relays the bus itself" \
  as_user busctl --address="$BUSA" call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus ListNames
no "but Chrome cannot reach the user's service manager through it" \
  as_user busctl --address="$BUSA" call org.freedesktop.systemd1 /org/freedesktop/systemd1 org.freedesktop.DBus.Peer Ping
NAMES=$(as_user busctl --address="$BUSA" call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus ListNames 2>&1)
no "nor see it" grep -q systemd1 <<<"$NAMES"
is "Chrome's PATH starts with the kit's xdg-open" "$(envof PATH | cut -d: -f1)" "/usr/local/lib/vpnkit/direct-bin"
chrome_stop
no "the bus proxy ends with Chrome" test -d "/proc/${PROXY_PID:-none}"
no "and its socket is gone" test -e "$BUSS"
# Without its bus proxy or its xdg-open, Chrome is not started.
rm -f /tmp/chrome-probe
mv /usr/bin/xdg-dbus-proxy /usr/bin/xdg-dbus-proxy.real
refuses "without xdg-dbus-proxy, direct-launch refuses" "xdg-dbus-proxy" sudo -n /usr/local/bin/direct-launch
printf '#!/bin/sh\nexit 1\n' > /usr/bin/xdg-dbus-proxy; chmod 755 /usr/bin/xdg-dbus-proxy
refuses "and when the bus proxy does not start" "did not start" sudo -n /usr/local/bin/direct-launch
mv -f /usr/bin/xdg-dbus-proxy.real /usr/bin/xdg-dbus-proxy
mv /usr/local/lib/vpnkit/direct-bin/xdg-open /tmp/suite-xdg-open
refuses "and without the kit's xdg-open" "xdg-open is missing" sudo -n /usr/local/bin/direct-launch
mv /tmp/suite-xdg-open /usr/local/lib/vpnkit/direct-bin/xdg-open
no "no Chrome was started meanwhile" test -e /tmp/chrome-probe
no "and no bus proxy is left behind" pgrep -u $U -x xdg-dbus-proxy
chrome_start

# An app opened through the kit's xdg-open (what Chrome runs for links,
# downloads and mailto:) starts outside the slice and follows the bar. The
# handler writes where it ran and where it exits.
cat > /usr/local/sbin/suite-handler <<'SH'
#!/usr/bin/env bash
{ echo "args: $*"; cat /proc/self/cgroup; echo "exit-ip=$(curl -4 -s --max-time 4 http://192.0.2.80:8080/)"; } > /tmp/handler.out 2>&1
SH
chmod 755 /usr/local/sbin/suite-handler
printf '[Desktop Entry]\nType=Application\nName=Suite handler\nExec=/usr/local/sbin/suite-handler %%u\nMimeType=x-scheme-handler/vpntest;\nNoDisplay=true\n' \
  > "$UHOME/.local/share/applications/suite-handler.desktop"
chown $U:$U "$UHOME/.local/share/applications/suite-handler.desktop"
as_user xdg-mime default suite-handler.desktop x-scheme-handler/vpntest
handler_out() {  # wait for the handler's report
  local i; for i in $(seq 1 30); do grep -q '^exit-ip=' /tmp/handler.out 2>/dev/null && break; sleep 0.5; done
  cat /tmp/handler.out 2>/dev/null
}
open_in_slice() {  # open_in_slice <xdg-open> <url>: as the user, from a scope in the slice
  # xdg-open uses scheme handlers only with a display set (none is needed).
  rm -f /tmp/handler.out
  systemd-run --scope --quiet --slice=vpnkitdirect.slice --uid=$U -- \
    env HOME=$UHOME XDG_RUNTIME_DIR=/run/user/$UID_T DISPLAY=:99 "$1" "$2" </dev/null >/dev/null 2>&1
  handler_out
}
H=$(open_in_slice /usr/bin/xdg-open vpntest://plain)
is "(the plain xdg-open, run in the slice, leaves the app there: home address)" "$(sed -n 's/^exit-ip=//p' <<<"$H")" "$HOME_IP"
H=$(open_in_slice /usr/local/lib/vpnkit/direct-bin/xdg-open vpntest://kit)
yes "the kit's xdg-open starts the app in a scope of the user's manager" grep -q "^0::/user.slice/.*/user@$UID_T.service/" <<<"$H"
no "outside Chrome direct's slice" grep -q vpnkitdirect.slice <<<"$H"
is "so the app follows the bar (server A)" "$(sed -n 's/^exit-ip=//p' <<<"$H")" "10.2.0.2"

# --- What the status and the leak check say about it ------------------------
# The Chrome started straight into the slice above skipped the launcher, so it
# has no resolver override of its own; only Chrome from the launcher runs now.
systemctl stop suite-chrome-inside.service 2>/dev/null
DNSCACHE=/run/vpnkit/direct-dns
NMH=/etc/opt/chrome/native-messaging-hosts
UNMH=$UHOME/.config/google-chrome/NativeMessagingHosts
host_manifest() {  # host_manifest <file> <program>: a native-messaging manifest
  printf '{"name":"com.example.suite","description":"suite","path":"%s","type":"stdio","allowed_origins":["chrome-extension://abcdefghijklmnopabcdefghijklmnop/"]}\n' "$2" > "$1"
}
is "status: direct on" "$(status .direct_enabled)" "true"
is "status: chrome inside" "$(status .direct_chrome_inside)" "true"
is "status: no Chrome outside the slice" "$(status .direct_chrome_outside)" "false"
is "status: the unit, the rules and DIRECT_DNS" "$(status '[.direct_unit, .direct_rules, .direct_dns, .direct_dns_ok] | @json')" '[true,true,"127.0.0.1",true]'
is "status: Chrome's resolver override holds" "$(status .direct_override_ok)" "true"
is "status: nothing else in the slice" "$(status '[.direct_helpers, .direct_others] | @json')" '[[],[]]'
yes "vpn-status says it in words" grep -q '^Chrome direct *: on · home IP · DNS 127.0.0.1$' <<<"$(as_user /usr/local/bin/vpn-status)"
OUT=$(vpn-verify 2>&1); rc=$?
is "the leak check passes with Chrome direct on" "$rc" "0"
(( rc == 0 )) || grep -E "FAIL" <<<"$OUT" | sed 's/^/      /'
yes "it proves a probe in the slice leaves from the normal connection" grep -q "PASS.*a probe in Chrome direct's slice exits from the normal connection" <<<"$OUT"
yes "that only Chrome runs in the slice" grep -q "PASS.*only Chrome runs in Chrome direct's slice" <<<"$OUT"
yes "that Chrome's resolver override holds" grep -q "PASS.*Chrome uses DIRECT_DNS (127.0.0.1) only" <<<"$OUT"
yes "and that DIRECT_DNS answers" grep -q "PASS.*the resolver at DIRECT_DNS (127.0.0.1) answers" <<<"$OUT"
# A scan of the slice that cannot finish says nothing, not "only Chrome": with
# no writable /tmp the resolver check cannot stage Chrome's files.
mount -t tmpfs -o ro,size=64k tmpfs /tmp
is "status: a scan that could not finish reads as unknown" "$(status '[.direct_known, .direct_enabled, .direct_others, .direct_chrome_inside] | @json')" '[false,true,[],null]'
yes "vpn-status says unknown in words" grep -q 'state unknown' <<<"$(as_user /usr/local/bin/vpn-status)"
OUT=$(vpn-verify 2>&1); rc=$?
umount /tmp
is "the leak check fails when it cannot look into the slice" "$rc" "1"
yes "and says so" grep -q "FAIL.*could not look into Chrome direct's slice" <<<"$OUT"
no "and does not claim that only Chrome runs there" grep -q "PASS.*only Chrome runs in Chrome direct's slice" <<<"$OUT"
is "status: known again once the scan can run" "$(status '[.direct_known, .direct_others] | @json')" '[true,[]]'

# Anything else in the slice uses the home IP too: the check names it.
systemd-run --scope --quiet --slice=vpnkitdirect.slice --unit=suite-other /usr/bin/sleep 300 </dev/null >/dev/null 2>&1 &
sleep 1
is "status: a program in the slice that is not Chrome is named" "$(status '.direct_others | join(",")')" "sleep"
OUT=$(vpn-verify 2>&1); rc=$?
is "the leak check fails on a non-Chrome process in the slice" "$rc" "1"
yes "and names it" grep -q "FAIL.*sleep runs in Chrome direct's slice" <<<"$OUT"
# A native-messaging host is Chrome's own helper: it is meant to go along.
install -d "$NMH"; host_manifest "$NMH/com.example.suite.json" /usr/bin/sleep
is "status: a registered native host is a helper" "$(status '[.direct_helpers, .direct_others] | @json')" '[["sleep"],[]]'
OUT=$(vpn-verify 2>&1); rc=$?
is "a registered native host is a warning, not a failure" "$rc" "0"
yes "the warning names it" grep -q "WARN.*sleep is a Chrome native-messaging host" <<<"$OUT"
rm -f "$NMH/com.example.suite.json"
# The user's own manifests are read with the user's rights: one the user
# cannot read registers nothing, one the user owns does.
install -d -o $U -g $U "$UHOME/.config/google-chrome" "$UNMH"
host_manifest "$UNMH/com.example.suite.json" /usr/bin/sleep; chown root:root "$UNMH/com.example.suite.json"; chmod 600 "$UNMH/com.example.suite.json"
is "a manifest in the user's folder that the user cannot read counts for nothing" "$(status '[.direct_helpers, .direct_others] | @json')" '[[],["sleep"]]'
chown $U:$U "$UNMH/com.example.suite.json"; chmod 644 "$UNMH/com.example.suite.json"
is "the user's own manifest registers a helper" "$(status '[.direct_helpers, .direct_others] | @json')" '[["sleep"],[]]'
rm -rf "$UHOME/.config/google-chrome"
systemctl stop suite-other.scope 2>/dev/null; sleep 1
is "status: and it is gone again" "$(status '[.direct_helpers, .direct_others] | @json')" '[[],[]]'
# Chrome's start script sends its output through `cat`s whose parent is
# Chrome, and bash runs Chrome's scripts while it starts: those are Chrome.
# A `cat` with another parent is not.
mkfifo /tmp/suite-fifo
printf 'read -r _ <> /tmp/suite-fifo\n' > /opt/google/chrome/suite-script
wrap() { systemd-run --scope --quiet --slice=vpnkitdirect.slice --unit="$1" -- "${@:2}" </dev/null >/dev/null 2>&1 & }
wrap suite-wrap1 bash -c 'exec > >(exec cat); exec /opt/google/chrome/chrome 300'
wrap suite-wrap2 /usr/bin/bash /opt/google/chrome/suite-script
sleep 1
is "status: Chrome's cat and a bash on Chrome's script count as Chrome" "$(status '[.direct_helpers, .direct_others] | @json')" '[[],[]]'
yes "(the cat is there)" bash -c "systemctl show -p ControlGroup --value suite-wrap1.scope | xargs -I{} cat /sys/fs/cgroup{}/cgroup.procs | xargs -I{} readlink /proc/{}/exe | grep -qx /usr/bin/cat"
wrap suite-wrap3 bash -c 'exec > >(exec cat); exec sleep 300'
sleep 1
is "status: a cat whose parent is not Chrome is named" "$(status '.direct_others | join(",")')" "cat,sleep"
systemctl stop suite-wrap1.scope suite-wrap2.scope suite-wrap3.scope 2>/dev/null
rm -f /tmp/suite-fifo /opt/google/chrome/suite-script; sleep 1

# A resolver that stops answering. The bar polls the status every few
# seconds, so the status asks at most every 30 s (cached in DNSCACHE); the
# leak check always asks.
kill "$LO_DNS_PID"; wait "$LO_DNS_PID" 2>/dev/null; rm -f "$DNSCACHE"
is "dns_ok false" "$(status .direct_dns_ok)" "false"
OUT=$(vpn-verify 2>&1); rc=$?
is "the leak check fails on a dead DIRECT_DNS" "$rc" "1"
yes "and says why" grep -q "FAIL.*the resolver at DIRECT_DNS (127.0.0.1) does not answer" <<<"$OUT"
# Worse than a closed port: one that takes questions and never answers, so
# each question waits for its timeout.
python3 -c 'import socket, time; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("127.0.0.1", 53)); time.sleep(600)' </dev/null >/dev/null 2>&1 &
MUTE_PID=$!; sleep 1; rm -f "$DNSCACHE"
is "a resolver that never answers: dns_ok false" "$(status .direct_dns_ok)" "false"
t0=$(date +%s%N); NSJ=$(as_user sudo -n /usr/local/bin/qbt-netns-status); t1=$(date +%s%N)
is "and the next status answers from the cache" "$(jq -r .direct.dns_ok <<<"$NSJ")" "false"
yes "without waiting for it ($(( (t1 - t0) / 1000000 )) ms)" test $(( (t1 - t0) / 1000000 )) -lt 2000
kill "$MUTE_PID"; wait "$MUTE_PID" 2>/dev/null
lo_dns_start; sleep 1
OUT=$(vpn-verify 2>&1)
yes "the leak check asks again at once" grep -q "PASS.*the resolver at DIRECT_DNS (127.0.0.1) answers" <<<"$OUT"
rm -f "$DNSCACHE"
is "status: dns_ok again after the cache runs out" "$(status .direct_dns_ok)" "true"

# The override can come undone while Chrome runs (pacman replaces
# /etc/nsswitch.conf by renaming over it): status and the leak check notice.
in_ns umount /etc/nsswitch.conf
is "status: an override without its nsswitch.conf is not ok" "$(status .direct_override_ok)" "false"
OUT=$(vpn-verify 2>&1); rc=$?
is "the leak check fails on it" "$rc" "1"
yes "and names the process" grep -q "FAIL.*Chrome (pid $CHROME_PID) no longer uses DIRECT_DNS only" <<<"$OUT"
chrome_stop; chrome_start
is "a restarted Chrome has it again" "$(status .direct_override_ok)" "true"
in_ns umount -l /run/systemd/resolve
is "status: an override without its resolv.conf is not ok" "$(status .direct_override_ok)" "false"
chrome_stop; chrome_start
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
refuses "and in the user's chrome-flags.conf" "chrome-flags.conf has the flag" sudo -n /usr/local/bin/direct-launch
# The package script reads the whole file and globs each word, so the check
# fails closed on what it cannot see whole.
FC="$UHOME/.config/chrome-flags.conf"
{ for i in $(seq 1 1200); do printf '# %s\n' "$(printf 'x%.0s' $(seq 1 60))"; done
  printf -- '--gpu-launcher=/bin/sh\n'; } > "$FC"; chown $U:$U "$FC"
refuses "a chrome-flags.conf too large to check is refused" "larger than" sudo -n /usr/local/bin/direct-launch
printf -- '--ozone-platform=wayland\n' > "$FC"; chmod 000 "$FC"
refuses "one that cannot be read is refused" "could not be read" sudo -n /usr/local/bin/direct-launch
chmod 644 "$FC"
printf -- '--gpu-launche?=/bin/sh\n' > "$FC"
refuses "a wildcard word in it is refused" "wildcard" sudo -n /usr/local/bin/direct-launch
printf -- '# Omarchy\n--ozone-platform=wayland\n--enable-features=TouchpadOverscrollHistoryNavigation\n' > "$FC"
chrome_start
is "an ordinary chrome-flags.conf starts Chrome" "$(cut -d' ' -f1 /tmp/chrome-probe 2>/dev/null)" "$HOME_IP"
chrome_stop
rm -f "$FC"
# Language, data folders and input method reach Chrome; a language value
# with a slash does not even reach the launcher (sudo keeps only safe ones).
CHROME_ENV=(LANG=de_DE.UTF-8 LC_TIME=en_GB.UTF-8 XDG_DATA_DIRS=/usr/local/share:/usr/share:/opt/suite
            GTK_IM_MODULE=fcitx QT_IM_MODULE=fcitx XMODIFIERS=@im=fcitx SDL_IM_MODULE=fcitx)
chrome_start
is "Chrome gets the caller's language, data folders and input method" \
  "$(for v in LANG LC_TIME XDG_DATA_DIRS GTK_IM_MODULE QT_IM_MODULE XMODIFIERS SDL_IM_MODULE; do printf '%s=%s ' $v "$(envof $v)"; done)" \
  "LANG=de_DE.UTF-8 LC_TIME=en_GB.UTF-8 XDG_DATA_DIRS=/usr/local/share:/usr/share:/opt/suite GTK_IM_MODULE=fcitx QT_IM_MODULE=fcitx XMODIFIERS=@im=fcitx SDL_IM_MODULE=fcitx "
chrome_stop
CHROME_ENV=(LANG=../../../tmp/suite-locale LC_ALL=/tmp/suite-locale)
chrome_start
is "a language value with a slash is dropped" "$(envof LANG)|$(envof LC_ALL)" "|"
chrome_stop
CHROME_ENV=()
# Without its rules loaded (one went missing), nothing starts.
rm -f /tmp/chrome-probe
ip -4 rule del priority 90 fwmark 51821 table main
refuses "direct-launch refuses while the rules are not loaded" "rules are not loaded" sudo -n /usr/local/bin/direct-launch
/usr/local/bin/vpnkit-direct-rules up
no "and no Chrome was started" test -e /tmp/chrome-probe
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
is "status: a Chrome outside the slice is seen" "$(status .direct_chrome_outside)" "true"
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
no "off: no tailnet rule" tailnet_rule
no "off: no slice" test -d "$DSLICE"
no "kill switch line gone" ks_line
yes "the kill switch itself stays armed" nft list table inet vpnkit_kill
no "off: the unit is not enabled" systemctl is-enabled --quiet vpnkit-direct.service
no "off: no state file" test -e /etc/vpnkit/direct-apps
is "off: status" "$(direct status | jq -c .)" '{"enabled":false,"unit":false,"rules":false,"dns_ok":true,"ssh":{"enabled":false,"ports":"22","rules":false}}'
is "status: off" "$(status .direct_enabled)" "false"
yes "vpn-status says off in words" grep -q '^Chrome direct *: off$' <<<"$(as_user /usr/local/bin/vpn-status)"
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
no "override removed when off" grep -qxF "$MARK" "$DESK"
is "and the user's own entry is put back, unchanged" "$(cat "$DESK" 2>/dev/null)" \
  "$(printf '[Desktop Entry]\nName=My own Chrome\nExec=/usr/bin/google-chrome-stable --my-flag')"
no "its backup was moved back, not copied" bash -c "ls $DESK.bak.* 2>/dev/null | grep -q ."
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
section "4c. Chrome direct: real Chrome"
# The stand-ins above cannot show what real Chrome does on its own: it asks
# the user's service manager for a scope of its own (which would move it out
# of the slice), its start script leaves two `cat`s running, and it opens
# other apps through xdg-open. Real Google Chrome, headed on a virtual X
# display, started the way the user starts it: the wrapper on PATH.
rm -rf /opt/google/chrome
mv /opt/google/chrome.real /opt/google/chrome
mv -f /usr/bin/google-chrome-stable.real /usr/bin/google-chrome-stable
# A second web service: logs every request (time, client address, path), and
# /launch is a page that opens vpntest:// (the suite's handler) by itself.
cat > /tmp/logsrv.py <<'PY'
import http.server, socketserver, time
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open("/tmp/seen.log", "a") as f:
            f.write("%s %s %s\n" % (time.strftime("%H:%M:%S"), self.client_address[0], self.path))
        if self.path.startswith("/launch"):
            body = b'<html><body><script>location.href = "vpntest://from-chrome";</script></body></html>'
        else:
            body = ("<html><body><pre>%s</pre></body></html>" % self.client_address[0]).encode()
        self.send_response(200); self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body))); self.send_header("Connection", "close")
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True; allow_reuse_address = True
S(("0.0.0.0", 8081), H).serve_forever()
PY
rm -f /tmp/seen.log
ip netns exec provider python3 /tmp/logsrv.py </dev/null >/dev/null 2>&1 &
LOGSRV_PID=$!
# Let pages open vpntest:// without asking (a managed policy, as an admin would set it).
install -d /etc/opt/chrome/policies/managed
printf '{"AutoLaunchProtocolsFromOrigins":[{"protocol":"vpntest","allowed_origins":["*"]}]}\n' \
  > /etc/opt/chrome/policies/managed/suite.json
as_user Xvfb :99 -nolisten tcp </dev/null >/dev/null 2>&1 &
XVFB_PID=$!
direct_dns 127.0.0.1
is "on" "$(direct on 2>&1)" "direct: on"
as_user /usr/local/bin/vpn-toggle proton-ca-1 >/dev/null 2>&1
is "server A is selected" "$(myip)" "10.2.0.2"
sleep 1
real_chrome() {  # real_chrome <url> [handover]: through the wrapper, as the user on display :99
  # A hand-over start exits at once; it gets a time limit, the first one not
  # (a limit would end Chrome with it).
  local t=(); [[ "${2:-}" == handover ]] && t=(timeout --foreground 60)
  "${t[@]}" "${ASU[@]}" DISPLAY=:99 /usr/local/bin/google-chrome-stable \
    --no-first-run --no-default-browser-check "$1" </dev/null >>/tmp/chrome-real.log 2>&1
}
seen() {  # seen <path>: the client address of the first request for <path>, waiting up to 30 s
  local i; for i in $(seq 1 60); do grep -q " $1\$" /tmp/seen.log 2>/dev/null && break; sleep 0.5; done
  awk -v p="$1" '$3 == p {print $2; exit}' /tmp/seen.log 2>/dev/null
}
chrome_procs() {  # pid of every Chrome process of the user (binary under /opt/google/chrome)
  local p; for p in $(pgrep -u $U); do
    [[ "$(readlink /proc/$p/exe 2>/dev/null)" == /opt/google/chrome/* ]] && echo "$p"
  done
}
browser_pid() {  # the browser process: Chrome's binary without --type=
  local p; for p in $(chrome_procs); do
    [[ "$(readlink /proc/$p/exe)" == /opt/google/chrome/chrome ]] || continue
    tr '\0' '\n' < /proc/$p/cmdline 2>/dev/null | grep -q '^--type=' || { echo "$p"; return; }
  done
}
netsvc_pid() {
  local p; for p in $(chrome_procs); do
    tr '\0' '\n' < /proc/$p/cmdline 2>/dev/null | grep -q 'network.mojom.NetworkService' && { echo "$p"; return; }
  done
}
not_in_slice() {  # pids of the given ones that are not in the slice
  local p; for p in "$@"; do grep -q '^0::/vpnkitdirect.slice/' /proc/$p/cgroup 2>/dev/null || echo "$p"; done
}
rm -f /tmp/chrome-real.log
real_chrome http://192.0.2.80:8081/first &
T0=$SECONDS
is "real Chrome loads a page from the home address" "$(seen /first)" "$HOME_IP"
# Chrome asks for its own scope within a second of starting; give it a minute.
sleep $(( 60 - (SECONDS - T0) > 0 ? 60 - (SECONDS - T0) : 0 ))
BROWSER=$(browser_pid)
yes "the browser runs after a minute" test -n "$BROWSER"
yes "and it is still in Chrome direct's slice" grep -q '^0::/vpnkitdirect.slice/' "/proc/${BROWSER:-none}/cgroup"
is "every Chrome process is in the slice" "$(not_in_slice $(chrome_procs) | paste -sd' ' -)" ""
is "the user's manager made no scope for Chrome" \
  "$(as_user systemctl --user list-units --all --no-legend 'app-com.google.Chrome*' 2>&1)" ""
PROXY_PID=$(pgrep -u $U -x xdg-dbus-proxy | head -1)
yes "Chrome's bus proxy runs" test -n "$PROXY_PID"
no "outside the slice" grep -q vpnkitdirect.slice "/proc/${PROXY_PID:-none}/cgroup"
# The network service Chrome restarts after it dies is started by the
# browser: it would land wherever the browser is.
NS1=$(netsvc_pid)
yes "Chrome's network service runs" test -n "$NS1"
[[ -n "$NS1" ]] && kill -9 "$NS1"
sleep 2
# A second start through the wrapper hands the URL to the running Chrome.
real_chrome http://192.0.2.80:8081/after-restart handover; rc=$?
is "a second start through the wrapper hands over to the running Chrome" "$rc" "0"
is "the page after the restart comes from the home address too" "$(seen /after-restart)" "$HOME_IP"
NS2=$(netsvc_pid)
yes "the network service was restarted" test -n "$NS2" -a "$NS2" != "$NS1"
yes "inside the slice" grep -q '^0::/vpnkitdirect.slice/' "/proc/${NS2:-none}/cgroup"
is "the hand-over left no extra bus proxy behind" "$(sleep 2; pgrep -u $U -x xdg-dbus-proxy | wc -l)" "1"
# Its start script's `cat`s and its other helpers count as Chrome.
is "status: Chrome inside, nothing outside" "$(status '[.direct_chrome_inside, .direct_chrome_outside] | @json')" '[true,false]'
is "status: nothing in the slice that is not Chrome" "$(status '[.direct_helpers, .direct_others] | @json')" '[[],[]]'
yes "(the start script's cat processes are there)" bash -c "pgrep -u $U -x cat | grep -q ."
OUT=$(vpn-verify 2>&1); rc=$?
is "the leak check passes with real Chrome running" "$rc" "0"
(( rc == 0 )) || grep -E "FAIL" <<<"$OUT" | sed 's/^/      /'
yes "only Chrome runs in the slice" grep -q "PASS.*only Chrome runs in Chrome direct's slice" <<<"$OUT"
yes "and the probe in it leaves from the normal connection" grep -q "PASS.*a probe in Chrome direct's slice exits from the normal connection" <<<"$OUT"
yes "and every Chrome process uses DIRECT_DNS only" grep -q "PASS.*Chrome uses DIRECT_DNS (127.0.0.1) only" <<<"$OUT"
# An app Chrome opens (here: a page that opens vpntest://) runs outside the
# slice and follows the bar.
rm -f /tmp/handler.out
real_chrome http://192.0.2.80:8081/launch handover
is "the launch page was loaded from the home address" "$(seen /launch)" "$HOME_IP"
H=$(handler_out)
yes "Chrome ran the app it opened" grep -q '^args: vpntest://from-chrome' <<<"$H"
no "outside Chrome direct's slice" grep -q vpnkitdirect.slice <<<"$H"
is "so it exits through server A, not the home address" "$(sed -n 's/^exit-ip=//p' <<<"$H")" "10.2.0.2"
# Closing Chrome ends its bus proxy too.
[[ -n "$BROWSER" ]] && kill "$BROWSER"
for i in $(seq 1 40); do [[ -z "$(chrome_procs)" ]] && break; sleep 0.5; done
is "Chrome closed" "$(chrome_procs | wc -l)" "0"
sleep 1
no "its bus proxy ended with it" pgrep -u $U -x xdg-dbus-proxy
is "and left no socket" "$(ls -A /run/user/$UID_T/vpnkit-direct 2>/dev/null)" ""
for i in $(seq 1 20); do grep -qx 'populated 0' "$DSLICE/cgroup.events" && break; sleep 0.5; done
is "off once Chrome is closed" "$(direct off 2>&1)" "direct: off"
as_user /usr/local/bin/vpn-toggle off >/dev/null 2>&1
kill "$XVFB_PID" "$LOGSRV_PID" 2>/dev/null
rm -f /etc/opt/chrome/policies/managed/suite.json

# ---------------------------------------------------------------------------
section "4d. Passwordless helpers never run a command from the caller's PATH"
# With env_reset, sudo replaces PATH only when sudoers sets secure_path (this
# sudo has it built in); an older or edited /etc/sudoers may not, and then the
# caller's PATH reaches root. Switch it off here, so it is that case. Then put
# a fake of every command in /usr/bin first in the caller's PATH: each fake
# notes its name when it runs as root, then runs the real command, so every
# helper still does its job. (Read by "sorts late": after the wheel rule.)
NOSP=/etc/sudoers.d/zz-suite-no-secure-path
printf 'Defaults !secure_path\n%s ALL=(root) NOPASSWD: /usr/local/sbin/suite-path-probe\n' "$U" > "$NOSP"
chmod 440 "$NOSP"
yes "(sudoers without secure_path is valid)" visudo -c
no "(and sudo has no secure_path now)" bash -c 'sudo -V | grep -q "override user.s \$PATH"'
FAKE=$(mktemp -d /tmp/suite-fakebin.XXXXXX); chmod 755 "$FAKE"
cat > "$FAKE/.fake" <<'EOF'
#!/usr/bin/bash
[[ $EUID -eq 0 ]] && printf '%s\n' "${0##*/}" >> /run/suite-fake-ran
exec "/usr/bin/${0##*/}" "$@"
EOF
chmod 755 "$FAKE/.fake"
for c in /usr/bin/*; do ln -s .fake "$FAKE/${c##*/}"; done
# A root script that does NOT set its PATH (test-only, its own sudo rule):
# the control that shows the fakes catch exactly what B1 is about.
printf '#!/usr/bin/bash\nid -u >/dev/null\nprintf "%%s" "$PATH"\n' > /usr/local/sbin/suite-path-probe
chmod 755 /usr/local/sbin/suite-path-probe
asfake() { runuser -u $U -- env HOME=$UHOME USER=$U XDG_RUNTIME_DIR=/run/user/$UID_T PATH="$FAKE:$PATH" "$@"; }
rm -f /run/suite-fake-ran
OUT=$(asfake sudo -n /usr/local/sbin/suite-path-probe 2>&1)
is "control: sudo now hands the caller's PATH to root" "${OUT%%:*}" "$FAKE"
is "control: and a root script without a PATH of its own runs the caller's fake" "$(sort -u /run/suite-fake-ran 2>/dev/null | paste -sd, -)" "id"
# fake_free <description> <check> <helper and arguments...>: run the helper
# through passwordless sudo with the fakes first in PATH; nothing of them may
# run as root, and <check> (a jq-free shell test on $OUT and $rc) must hold,
# which shows the helper really ran.
fake_free() {
  local d="$1" chk="$2" ran; shift 2
  rm -f /run/suite-fake-ran
  OUT=$(asfake timeout 120 sudo -n "$@" 2>&1 </dev/null); rc=$?
  ran=$(sort -u /run/suite-fake-ran 2>/dev/null | paste -sd, -)
  if [[ -n "$ran" ]]; then bad "$d: ran the caller's $ran as root"
  elif ! eval "$chk"; then bad "$d: did not run as expected (rc $rc: $(head -c 160 <<<"$OUT" | tr '\n' ' '))"
  else ok "$d"; fi
}
fake_free "qbt-netns-status runs none of the caller's commands" 'jq -e .exists <<<"$OUT" >/dev/null' \
  /usr/local/bin/qbt-netns-status
fake_free "qbt-launch neither (it started qBittorrent in the namespace)" '(( rc == 0 ))' \
  /usr/local/bin/qbt-launch 1
fake_free "vpnkit-killswitch on neither" '[[ $OUT == "kill switch on (proton-ca-1)" ]]' \
  /usr/local/bin/vpnkit-killswitch on proton-ca-1
fake_free "vpnkit-killswitch off neither" '[[ $OUT == "kill switch off" ]]' \
  /usr/local/bin/vpnkit-killswitch off
fake_free "vpnkit-sync neither" 'jq -e ".imported | type == \"array\"" <<<"$OUT" >/dev/null' \
  /usr/local/bin/vpnkit-sync sync
fake_free "vpnkit-direct neither" 'jq -e ".enabled == false" <<<"$OUT" >/dev/null' \
  /usr/local/bin/vpnkit-direct status
fake_free "vpnkit-direct ssh on neither" '[[ $OUT == "ssh direct: on (port 22)" ]]' \
  /usr/local/bin/vpnkit-direct ssh on
fake_free "vpnkit-direct ssh off neither" '[[ $OUT == "ssh direct: off" ]]' \
  /usr/local/bin/vpnkit-direct ssh off
fake_free "direct-launch neither (it refuses: Chrome direct is off)" '(( rc == 1 )) && grep -q "Chrome direct is off" <<<"$OUT"' \
  /usr/local/bin/direct-launch
fake_free "vpn-verify neither" 'grep -q "^Result: " <<<"$OUT"' \
  /usr/local/bin/vpn-verify
FFBAK=""; [[ -e /usr/lib/firefox/firefox ]] && { FFBAK=$(mktemp); cp -a /usr/lib/firefox/firefox "$FFBAK"; }
install -D -m 755 /usr/bin/sleep /usr/lib/firefox/firefox     # stand-in
fake_free "ff-launch neither (it started Firefox in its namespace)" '(( rc == 0 ))' \
  /usr/local/bin/ff-launch 1
if [[ -n "$FFBAK" ]]; then cp -a "$FFBAK" /usr/lib/firefox/firefox; rm -f "$FFBAK"; else rm -rf /usr/lib/firefox; fi
rm -rf "$FAKE" /usr/local/sbin/suite-path-probe /run/suite-fake-ran
# secure_path stays off until the reinstall in section 6, which must say so.

# ---------------------------------------------------------------------------
section "4e. SSH direct"
# Opt-in: new TCP connections to the SSH ports (DIRECT_SSH_PORTS, default 22)
# keep the normal connection while a server is selected; everything else
# follows the bar. The "what is my IP" service also listens on ports 22, 2222
# and 443 here, so where a connection to each port comes from can be seen.
for p in 22 2222 443; do ip netns exec provider python3 /tmp/whoami.py 0.0.0.0 "$p" </dev/null >/dev/null 2>&1 & done
for i in $(seq 1 60); do
  for p in 22 2222 443; do ip netns exec provider curl -s --max-time 1 "http://192.0.2.80:$p/" >/dev/null 2>&1 || continue 2; done
  break
done
portip()   { local a; a=$(curl -4 -s --max-time 3 "http://192.0.2.80:$1/" 2>/dev/null) || a=""; printf '%s' "${a:-none}"; }
nsportip() { local a; a=$(ip netns exec "$1" curl -4 -s --max-time 4 "http://192.0.2.80:$2/" 2>/dev/null) || a=""; printf '%s' "${a:-none}"; }
ssh_ports() { sed -i '/^DIRECT_SSH_PORTS=/d' "$VCONF"; [[ "$1" == "-" ]] || printf 'DIRECT_SSH_PORTS="%s"\n' "$1" >> "$VCONF"; }
chrome_mark() { nft list chain inet vpnkit_direct output 2>/dev/null | grep -q cgroupv2; }
ssh_mark()    { nft list chain inet vpnkit_direct output 2>/dev/null | grep -q 'comment "ssh"'; }
sshst()       { as_user sudo -n /usr/local/bin/qbt-netns-status | jq -c .direct.ssh; }

as_user /usr/local/bin/vpn-toggle proton-ca-1 >/dev/null 2>&1
is "server A is selected" "$(myip)" "10.2.0.2"
is "off: port 22 follows the bar" "$(portip 22)" "10.2.0.2"
is "off: vpn-status" "$(status '[.ssh_direct_enabled, .ssh_direct_rules, .ssh_direct_ports] | @json')" '[false,null,[22]]'
is "off: the status helper" "$(sshst)" '{"enabled":false,"ports":"22","ports_ok":true,"rules":false}'
no "off: nothing loaded" nft list table inet vpnkit_direct
no "off: no fwmark rule" direct_rule
no "off: the kill switch has no direct line" ks_line
yes "vpn-status says off in words" grep -q '^SSH direct *: off$' <<<"$(as_user /usr/local/bin/vpn-status)"
OUT=$(vpn-verify 2>&1)
no "off: the leak check has no SSH direct section" grep -q "SSH direct" <<<"$OUT"

# Only the exact arguments are passwordless, and the helper refuses anything else.
sudo_refuses "ssh alone is not passwordless" /usr/local/bin/vpnkit-direct ssh
sudo_refuses "nor ssh with another word" /usr/local/bin/vpnkit-direct ssh status
sudo_refuses "nor ssh ON" /usr/local/bin/vpnkit-direct ssh ON
sudo_refuses "nor anything after ssh on" /usr/local/bin/vpnkit-direct ssh on 2222
sudo_refuses "nor the words the other way round" /usr/local/bin/vpnkit-direct on ssh
for a in "ssh" "ssh bogus" "ssh on extra" "on ssh" "ssh off off"; do
  # shellcheck disable=SC2086
  /usr/local/bin/vpnkit-direct $a >/dev/null 2>&1; rc=$?
  is "the helper itself refuses '$a'" "$rc" "2"
done
# sudo matches the arguments joined by spaces, so one word "ssh on" is
# passwordless too; the helper refuses it (one argument).
for a in "ssh on" "ssh off"; do
  as_user sudo -n /usr/local/bin/vpnkit-direct "$a" >/dev/null 2>&1; rc=$?
  is "through sudo, the helper refuses '$a' as one word" "$rc" "2"
done
no "and nothing was turned on" test -e /etc/vpnkit/direct-apps

# DIRECT_SSH_PORTS: one to eight port numbers, never DNS; anything else is refused.
for v in "" "0" "65536" "0022" "22 x" "22;id" "22-24" "53" "22 853" "1 2 3 4 5 6 7 8 9"; do
  ssh_ports "$v"
  OUT=$(direct ssh on 2>&1); rc=$?
  is "DIRECT_SSH_PORTS=\"$v\" is refused" "$rc" "1"
done
yes "with the reason" grep -q "at most 8" <<<"$OUT"
is "nine copies of one port are one port" "$(bash -c '. /usr/local/lib/vpnkit/common.sh; . /usr/local/lib/vpnkit/direct.sh; vpnkit_ssh_ports "22 22 22 22 22 22 22 22 22"' 2>&1)" "22"
no "nothing was turned on" test -e /etc/vpnkit/direct-apps
no "nor loaded" nft list table inet vpnkit_direct
no "nor the unit enabled" systemctl is-enabled --quiet vpnkit-direct.service

ssh_ports "22 2222"
is "on, with two ports" "$(as_user /usr/local/bin/vpn-direct ssh on 2>&1 | head -1)" "ssh direct: on (ports 22, 2222)"
yes "its unit is enabled, so it comes back after a reboot" systemctl is-enabled --quiet vpnkit-direct.service
is "port 22 leaves from the home address" "$(portip 22)" "$HOME_IP"
is "so does the second port" "$(portip 2222)" "$HOME_IP"
is "port 443 still goes through server A" "$(portip 443)" "10.2.0.2"
is "and so does everything else" "$(myip)" "10.2.0.2"
is "the torrent namespace's port 22 still goes through its tunnel" "$(nsportip qbtvpn 22)" "10.2.0.3"
is "and the Firefox namespace's through its own" "$(nsportip ffvpn 22)" "10.3.0.4"
is "status: on, its rules, both ports" "$(status '[.ssh_direct_enabled, .ssh_direct_rules, .ssh_direct_ports] | @json')" '[true,true,[22,2222]]'
is "the status helper" "$(sshst)" '{"enabled":true,"ports":"22,2222","ports_ok":true,"rules":true}'
yes "vpn-status says it in words" grep -q '^SSH direct *: on (ports 22, 2222)$' <<<"$(as_user /usr/local/bin/vpn-status)"
yes "the kill switch has the direct line" ks_line
yes "the tailnet rule is there" tailnet_rule
is "Chrome direct stays off" "$(direct status | jq -c '[.enabled, .rules]')" "[false,false]"
no "and Chrome's slice gets no mark" chrome_mark
is "a process in the slice follows the bar" "$(slice_ip)" "10.2.0.2"

nmcli connection down proton-ca-1 >/dev/null 2>&1; sleep 1
is "blocked: the host does not get out" "$(myip)" "none"
is "blocked: port 443 does not either" "$(portip 443)" "none"
is "blocked: port 22 still leaves from home" "$(portip 22)" "$HOME_IP"
as_user /usr/local/bin/vpn-toggle proton-ca-1 >/dev/null 2>&1
is "server A again" "$(myip)" "10.2.0.2"
yes "the re-armed kill switch keeps the direct line" ks_line

OUT=$(vpn-verify 2>&1); rc=$?
is "the leak check passes with SSH direct on" "$rc" "0"
(( rc == 0 )) || grep -E "FAIL" <<<"$OUT" | sed 's/^/      /'
yes "it checks the rules for the configured ports" grep -q "PASS.*new connections to the SSH ports (22, 2222) use your own IP" <<<"$OUT"
yes "that a marked connection leaves outside the tunnel" grep -q "PASS.*a connection SSH direct marks leaves through [^ ]*, not proton-ca-1" <<<"$OUT"
yes "and that the kill switch lets it out" grep -q "PASS.*the kill switch lets the marked connections out" <<<"$OUT"

# A rule that went missing: status, panel data and the leak check say so.
ip -4 rule del priority 90 fwmark 51821 table main
is "status: a missing rule shows" "$(status .ssh_direct_rules)" "false"
yes "vpn-status says it does not work" grep -q "NOT WORKING: its rules, or the kill switch line for them, are missing" <<<"$(as_user /usr/local/bin/vpn-status)"
is "port 22 then goes into the VPN, never around it" "$(portip 22)" "10.2.0.2"
OUT=$(vpn-verify 2>&1); rc=$?
is "the leak check fails" "$rc" "1"
yes "and says the rules are not loaded" grep -q "FAIL.*SSH direct is on but its rules for the SSH ports (22, 2222) are not loaded" <<<"$OUT"
yes "and that a marked connection would not leave outside the tunnel" grep -q "FAIL.*a connection SSH direct marks would leave through proton-ca-1" <<<"$OUT"
/etc/NetworkManager/dispatcher.d/50-vpnkit "$PHYS" up
is "a link coming up loads them again" "$(status .ssh_direct_rules)" "true"
# An armed kill switch without its line: the status must not say SSH direct
# works. (While the server is up, the tunnel interface's own accept still lets
# a rerouted connection out: the output hook keeps the device the first route
# chose. Once the bar says blocked, the line is all there is.)
h=$(nft -a list chain inet vpnkit_kill output 2>/dev/null | awk '/meta mark 0x0000ca6d accept/ {print $NF; exit}')
nft delete rule inet vpnkit_kill output handle "${h:-0}"
no "the kill switch is armed without its line" ks_line
is "status: not working" "$(status .ssh_direct_rules)" "false"
is "and the helper's own status agrees" "$(direct status | jq -c .ssh.rules)" "false"
yes "vpn-status says so" grep -q "NOT WORKING: its rules, or the kill switch line for them, are missing" <<<"$(as_user /usr/local/bin/vpn-status)"
OUT=$(vpn-verify 2>&1)
yes "the leak check fails on it" grep -q "FAIL.*the kill switch has no line for SSH direct's mark" <<<"$OUT"
nmcli connection down proton-ca-1 >/dev/null 2>&1; sleep 1
is "blocked without the line, port 22 does not get out either" "$(portip 22)" "none"
nft delete table inet vpnkit_kill
is "with no kill switch at all, the rules alone count" "$(status .ssh_direct_rules)" "true"
as_user /usr/local/bin/vpn-toggle proton-ca-1 >/dev/null 2>&1
is "(server A again)" "$(myip)" "10.2.0.2"
is "server A re-armed: working again" "$(status .ssh_direct_rules)" "true"

# Other ports than the loaded ones: the rules no longer count as loaded until on again.
ssh_ports "2222"
is "status: rules for other ports count as missing" "$(status .ssh_direct_rules)" "false"
is "on again loads the new ports" "$(direct ssh on 2>&1)" "ssh direct: on (port 2222)"
is "port 22 now follows the bar" "$(portip 22)" "10.2.0.2"
is "port 2222 leaves from home" "$(portip 2222)" "$HOME_IP"
ssh_ports "22 x"
is "status: ports that are not valid while on" "$(status '[.ssh_direct_ports_ok, .ssh_direct_rules] | @json')" '[false,false]'
yes "vpn-status says so" grep -q "DIRECT_SSH_PORTS in /etc/vpnkit/vpnkit.conf is not valid" <<<"$(as_user /usr/local/bin/vpn-status)"
OUT=$(vpn-verify 2>&1); rc=$?
is "the leak check fails on them" "$rc" "1"
yes "and says why" grep -q "FAIL.*SSH direct is on but DIRECT_SSH_PORTS" <<<"$OUT"
/usr/local/bin/vpnkit-direct-rules up >/dev/null 2>&1; rc=$?
is "the rules helper refuses to load them" "$rc" "1"
yes "and leaves the loaded rules as they were" ssh_mark
ssh_ports "22 2222"
is "on again with valid ports" "$(direct ssh on 2>&1)" "ssh direct: on (ports 22, 2222)"

# Reboot: the unit loads the rules again from the state file.
systemctl stop vpnkit-direct.service
is "with its unit stopped, port 22 follows the bar" "$(portip 22)" "10.2.0.2"
is "and status says the rules are missing" "$(status .ssh_direct_rules)" "false"
systemctl start vpnkit-direct.service
is "started again (as at boot), port 22 leaves from home" "$(portip 22)" "$HOME_IP"
systemctl restart vpnkit-direct.service
is "and after a restart" "$(portip 22)" "$HOME_IP"
is "status: rules loaded" "$(status .ssh_direct_rules)" "true"

# Independent of Chrome direct: either can go on or off without the other's rules.
is "Chrome direct turns on beside it" "$(direct on 2>&1)" "direct: on"
is "both rule sets are loaded" "$(direct status | jq -c '[.rules, .ssh.rules]')" "[true,true]"
is "the slice exits from home" "$(slice_ip)" "$HOME_IP"
is "port 22 still does" "$(portip 22)" "$HOME_IP"
# Ports that are not valid take only SSH direct down, never Chrome direct.
ssh_ports "22 x"
OUT=$(/usr/local/bin/vpnkit-direct-rules up 2>&1); rc=$?
is "with ports not valid, the rules helper still loads Chrome's part" "$rc" "0"
yes "and says SSH's is left out" grep -q "loading Chrome direct's rules only" <<<"$OUT"
yes "Chrome's mark is loaded" chrome_mark
no "SSH's is not" ssh_mark
is "status: Chrome works, SSH does not" "$(direct status | jq -c '[.rules, .ssh.rules]')" "[true,false]"
is "the slice still exits from home" "$(slice_ip)" "$HOME_IP"
is "port 22 follows the bar" "$(portip 22)" "10.2.0.2"
systemctl restart vpnkit-direct.service; rc=$?
is "the unit starts with them too (a reboot)" "$rc" "0"
yes "with Chrome's mark" chrome_mark
is "Chrome direct turns off with them" "$(direct off 2>&1 | tail -1)" "direct: off"
no "and its mark is gone" chrome_mark
is "SSH direct stays on, not working" "$(direct status | jq -c '[.enabled, .rules, .ssh.enabled, .ssh.rules]')" "[false,false,true,false]"
is "Chrome direct turns on with them" "$(direct on 2>&1 | tail -1)" "direct: on"
is "and works" "$(direct status | jq -c '[.enabled, .rules, .ssh.enabled, .ssh.rules]')" "[true,true,true,false]"
is "the slice exits from home again" "$(slice_ip)" "$HOME_IP"
ssh_ports "22 2222"
/usr/local/bin/vpnkit-direct-rules up >/dev/null 2>&1
is "valid again: both rule sets" "$(direct status | jq -c '[.rules, .ssh.rules]')" "[true,true]"
is "Chrome direct turns off" "$(direct off 2>&1)" "direct: off"
is "SSH direct keeps its rules" "$(direct status | jq -c '[.enabled, .rules, .ssh.enabled, .ssh.rules]')" "[false,false,true,true]"
is "port 22 still leaves from home" "$(portip 22)" "$HOME_IP"
yes "the tailnet rule stays" tailnet_rule
yes "the kill switch line stays" ks_line
no "Chrome's mark is gone" chrome_mark
is "a process in the slice follows the bar again" "$(slice_ip)" "10.2.0.2"
is "Chrome direct on once more" "$(direct on 2>&1)" "direct: on"
is "SSH direct turns off" "$(as_user /usr/local/bin/vpn-direct ssh off 2>&1 | head -1)" "ssh direct: off"
is "Chrome direct keeps its rules" "$(direct status | jq -c '[.enabled, .rules, .ssh.enabled, .ssh.rules]')" "[true,true,false,false]"
is "the slice still exits from home" "$(slice_ip)" "$HOME_IP"
is "port 22 follows the bar" "$(portip 22)" "10.2.0.2"
yes "the kill switch line stays for Chrome" ks_line
no "SSH's rules are gone" ssh_mark
is "Chrome direct off" "$(direct off 2>&1)" "direct: off"

# Ruling 17: a connection open when SSH direct is turned on keeps its path,
# only new ones go direct; and only TCP is matched (UDP to port 22 follows
# the bar). A line server on 2200 (TCP and UDP) and a UDP one on 22 answer
# each line or datagram with the address it came from.
cat > /tmp/peer.py <<'PY'
import socket, sys, threading
port, mode = int(sys.argv[1]), sys.argv[2]
def tcp():
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", port)); s.listen(8)
    while True:
        c, a = s.accept()
        def serve(c=c, a=a):
            try:
                for _ in c.makefile("rb"): c.sendall((a[0] + "\n").encode())
            except OSError: pass
            finally: c.close()
        threading.Thread(target=serve, daemon=True).start()
def udp():
    # Bound to the service's address: a reply from another source address
    # would not match the client's connection, and its firewall drops it.
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.bind(("192.0.2.80", port))
    while True:
        d, a = u.recvfrom(64); u.sendto((a[0] + "\n").encode(), a)
if mode in ("udp", "both"): threading.Thread(target=udp, daemon=True).start()
tcp() if mode in ("tcp", "both") else threading.Event().wait()
PY
cat > /tmp/peer-client.py <<'PY'
import os, socket, sys, time
c = socket.create_connection(("192.0.2.80", int(sys.argv[1])), timeout=10); f = c.makefile("rb")
c.sendall(b"a\n"); print(f.readline().decode().strip(), flush=True)
for _ in range(600):
    if os.path.exists(sys.argv[2]): break
    time.sleep(0.1)
c.sendall(b"b\n"); print(f.readline().decode().strip(), flush=True)
PY
udpip() { python3 -c 'import socket,sys
u=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); u.settimeout(3)
try:
    u.sendto(b"x",("192.0.2.80",int(sys.argv[1]))); print(u.recvfrom(64)[0].decode().strip())
except OSError: print("none")' "$1"; }
ip netns exec provider python3 /tmp/peer.py 2200 both </dev/null >/dev/null 2>&1 &
ip netns exec provider python3 /tmp/peer.py 22 udp </dev/null >/dev/null 2>&1 &
for i in $(seq 1 50); do [[ "$(udpip 2200)" != none ]] && break; sleep 0.2; done
ssh_ports "22 2200"
rm -f /tmp/suite-go
python3 /tmp/peer-client.py 2200 /tmp/suite-go > /tmp/peer-client.out 2>&1 &
PEERC=$!
for i in $(seq 1 50); do [[ -s /tmp/peer-client.out ]] && break; sleep 0.2; done
is "before: the open connection goes through server A" "$(head -1 /tmp/peer-client.out)" "10.2.0.2"
is "SSH direct on, with port 2200" "$(direct ssh on 2>&1)" "ssh direct: on (ports 22, 2200)"
touch /tmp/suite-go; wait "$PEERC"
is "after: the connection that was open keeps its path" "$(sed -n 2p /tmp/peer-client.out)" "10.2.0.2"
rm -f /tmp/suite-go
python3 /tmp/peer-client.py 2200 /tmp/suite-go-now > /tmp/peer-client.out 2>&1 & PEERC=$!
touch /tmp/suite-go-now; wait "$PEERC"; rm -f /tmp/suite-go-now
is "a new connection to it leaves from home" "$(head -1 /tmp/peer-client.out)" "$HOME_IP"
is "UDP to port 22 follows the bar" "$(udpip 22)" "10.2.0.2"
is "and UDP to port 2200" "$(udpip 2200)" "10.2.0.2"
ssh_ports "22 2222"

# Off removes everything.
is "SSH direct on again" "$(direct ssh on 2>&1)" "ssh direct: on (ports 22, 2222)"
OUT=$(as_user /usr/local/bin/vpn-direct ssh off 2>&1)
is "off" "$(head -1 <<<"$OUT")" "ssh direct: off"
yes "and says open connections need a reconnect" grep -q "reconnect them" <<<"$OUT"
no "off: nothing loaded" nft list table inet vpnkit_direct
no "off: no fwmark rule" direct_rule
no "off: no tailnet rule" tailnet_rule
no "off: no slice" test -d "$DSLICE"
no "off: the kill switch line is gone" ks_line
yes "the kill switch itself stays armed" nft list table inet vpnkit_kill
no "off: the unit is not enabled" systemctl is-enabled --quiet vpnkit-direct.service
no "off: no state file" test -e /etc/vpnkit/direct-apps
is "off: port 22 follows the bar" "$(portip 22)" "10.2.0.2"
is "off: the status helper" "$(sshst)" '{"enabled":false,"ports":"22,2222","ports_ok":true,"rules":false}'
/usr/local/bin/vpnkit-direct-rules up >/dev/null 2>&1; rc=$?
is "the rules helper refuses to load while both are off" "$rc" "1"
no "and loads nothing" nft list table inet vpnkit_direct

# A unit that cannot start: ssh on rolls everything back.
install -d /run/systemd/system/vpnkit-direct.service.d
printf '[Service]\nExecStartPre=/usr/bin/false\n' > /run/systemd/system/vpnkit-direct.service.d/suite.conf
systemctl daemon-reload
OUT=$(direct ssh on 2>&1); rc=$?
is "ssh on fails when its unit cannot start" "$rc" "1"
no "and leaves no state file" test -e /etc/vpnkit/direct-apps
no "no table" nft list table inet vpnkit_direct
no "no fwmark rule" direct_rule
no "no kill switch line" ks_line
no "and the unit is not enabled" systemctl is-enabled --quiet vpnkit-direct.service
rm -rf /run/systemd/system/vpnkit-direct.service.d; systemctl daemon-reload
systemctl reset-failed vpnkit-direct.service 2>/dev/null
ssh_ports -

# The status looks at the desktop user's programs once for the Firefox and
# Chrome checks (vpnkit_proc_index): each process must come out exactly as it
# does with one readlink per process. Stand-ins: a Chrome outside the slice,
# a Firefox (a copy of bash) with a Firefox child, a program that was deleted.
FFBAK=$(mktemp); cp -a /usr/lib/firefox/firefox "$FFBAK"
install -m 755 /usr/bin/bash /usr/lib/firefox/firefox
install -m 755 /usr/bin/sleep /opt/google/chrome/suite-standin
install -m 755 /usr/bin/sleep /tmp/suite-gone
as_user /opt/google/chrome/suite-standin 120 </dev/null >/dev/null 2>&1 &
as_user /usr/lib/firefox/firefox -c '/usr/lib/firefox/firefox -c "sleep 120 & wait" & wait' </dev/null >/dev/null 2>&1 &
as_user /tmp/suite-gone 120 </dev/null >/dev/null 2>&1 &
sleep 1; rm -f /tmp/suite-gone
CHPID=$(pgrep -u $U -f '^/opt/google/chrome/suite-standin' | head -1)
FFMAIN=$(pgrep -u $U -f '^/usr/lib/firefox/firefox -c /usr/lib/firefox/firefox' | head -1)
FFKID=$(pgrep -u $U -f '^/usr/lib/firefox/firefox -c sleep 120' | head -1)
GONE=$(pgrep -u $U -x suite-gone | head -1)
OUT=$(bash -c '. /usr/local/lib/vpnkit/common.sh; . /usr/local/lib/vpnkit/direct.sh
  ino=$(stat -Lc %i /run/netns/ffvpn)
  run() { vpnkit_chrome_outside_pids tester; echo -; vpnkit_ff_pids "$ino" tester both; echo -
          vpnkit_ff_pids "" tester outside; echo -; vpnkit_app_pids tester "^/tmp/suite-gone" both "netns:$ino"; echo -
          vpnkit_app_pids tester "^/usr/bin/sleep$" outside "slice:vpnkitdirect.slice"; }
  run; echo =; vpnkit_proc_index tester; run')
A=$(sed '/^=$/,$d' <<<"$OUT"); B=$(sed '1,/^=$/d' <<<"$OUT")
is "one pass over the processes classifies them as one readlink each does" "$B" "$A"
yes "(the Chrome stand-in is outside the slice)" grep -qx "${CHPID:-none}" <<<"$A"
yes "(the Firefox main process is outside, its child is not counted)" \
  bash -c '[[ -n "$2" && "$2" != "$3" ]] && grep -qx "outside $2" <<<"$1" && ! grep -q " $3$" <<<"$1"' _ "$A" "$FFMAIN" "$FFKID"
yes "(the deleted program is seen)" grep -qx "outside ${GONE:-none}" <<<"$A"
for p in $(pgrep -P "${FFKID:-0}") $FFKID $FFMAIN $CHPID $GONE; do kill "$p" 2>/dev/null; done
sleep 1
cp -a --remove-destination "$FFBAK" /usr/lib/firefox/firefox; rm -f "$FFBAK" /opt/google/chrome/suite-standin
as_user /usr/local/bin/vpn-toggle off >/dev/null 2>&1

# ---------------------------------------------------------------------------
section "5. The leak check, the rescue, and deleting a server"
as_user /usr/local/bin/vpn-toggle proton-ca-1 >/dev/null 2>&1
OUT=$(vpn-verify --fail-closed 2>&1); rc=$?
is "vpn-verify --fail-closed passes with a VPN up" "$rc" "0"
(( rc == 0 )) || grep -E "FAIL|Result" <<<"$OUT" | sed 's/^/      /'
echo "      $(grep Result <<<"$OUT")"
no "no direct lines in the leak check when off" grep -qiE "chrome direct|ssh direct" <<<"$OUT"
yes "the leak check covers the Firefox tunnel" grep -q "PASS.*Firefox exits from its own address (10.3.0.4)" <<<"$OUT"
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
(( rc == 0 )) || grep -E "FAIL|Result" <<<"$OUT" | sed 's/^/      /'
NEWEST=$(ls -1 "$REPORTS"/leak-check-*.txt 2>/dev/null | sort | tail -1)
yes "vpn-check saved a report" test -s "$NEWEST"
is "the report belongs to the desktop user" "$(stat -c %U "$NEWEST")" "$U"
is "the reports folder is private" "$(stat -c %a "$REPORTS")" "700"
yes "the report names the selected server" grep -q "^Regular traffic: proton-ca-1 (kill switch on)" "$NEWEST"
yes "and the Firefox tunnel's" grep -q "^Firefox: *proton-se-4 (tunnel up)" "$NEWEST"
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
# Kit servers are told apart from the user's own WireGuard profiles and
# configs by their uuid, not by the name prefix. A profile of the user's that
# happens to be called proton-*, and a wg-quick config of theirs:
as_user /usr/local/bin/vpn-toggle off >/dev/null 2>&1
nmcli connection add type wireguard con-name proton-mine ifname proton-mine autoconnect no \
  wireguard.private-key "$(cat "$WG/deskB.key")" ipv4.method manual ipv4.addresses 10.9.0.2/32 >/dev/null
MINE_UUID=$(nmcli -g connection.uuid connection show proton-mine)
printf '# the user own wg-quick config (suite)\n[Interface]\n' > /etc/wireguard/proton-mine.conf
printf '# the user own wg-quick config (suite)\n[Interface]\n' > /etc/wireguard/proton-de-4.conf
MINE_SUM=$(sha256sum < /etc/wireguard/proton-de-4.conf)
OUT=$(as_user sudo -n /usr/local/bin/vpnkit-sync remove proton-mine 2>&1); rc=$?
is "a profile of the user's with the kit's prefix cannot be deleted through the panel" "$rc" "1"
yes "it is still there" nmcli connection show uuid "$MINE_UUID"
yes "and so is its config" test -e /etc/wireguard/proton-mine.conf
no "nor be chosen for torrents" as_user sudo -n /usr/local/bin/vpnkit-sync torrent proton-mine
OUT=$(as_user sudo -n /usr/local/bin/vpnkit-sync firefox proton-mine 2>&1); rc=$?
is "nor for Firefox" "$rc" "1"
yes "(refused as not the kit's server)" grep -q "no such server: proton-mine" <<<"$OUT"
is "(the Firefox tunnel stayed where it was)" "$(cat /etc/vpnkit/firefox-server)" "proton-se-4"
# The NetworkManager hook arms the kill switch for the kit's servers only.
CONNECTION_ID=proton-mine CONNECTION_UUID=$MINE_UUID /etc/NetworkManager/dispatcher.d/50-vpnkit proton-mine up
no "the hook does not arm the kill switch for the user's own proton-* profile" nft list table inet vpnkit_kill
CONNECTION_ID=proton-ca-1 CONNECTION_UUID=$(nmcli -g connection.uuid connection show proton-ca-1) \
  /etc/NetworkManager/dispatcher.d/50-vpnkit proton-ca-1 up
yes "(it does for a kit server)" nft list table inet vpnkit_kill
/usr/local/bin/vpnkit-killswitch off >/dev/null
# A config whose name would be proton-de-4, while /etc/wireguard/proton-de-4.conf
# is the user's: imported under another name, the user's file untouched.
conf "$DROP/wg-DE-4.conf" "$WG/deskB.key" 10.3.0.2 10.3.0.1 "DE#4" "$WG/srvB.pub" 51821
OUT=$(as_user sudo -n /usr/local/bin/vpnkit-sync sync)
DE4=$(jq -r '.imported[0] // empty' <<<"$OUT")
yes "a config whose name is taken by a file of the user's is imported under another name ($DE4)" \
  bash -c "[[ '$DE4' == proton-de-* && '$DE4' != proton-de-4 ]]"
is "and the user's file is untouched" "$(sha256sum < /etc/wireguard/proton-de-4.conf)" "$MINE_SUM"
yes "that server is the kit's: it can be deleted" as_user sudo -n /usr/local/bin/vpnkit-sync remove "$DE4"
# A server whose profile is deleted outside the kit (nmcli, the network
# settings) leaves its config behind. Importing the very same file again takes
# that config back under the server's own name; a different file of that name
# is still not taken over.
conf "$DROP/wg-FI-6.conf" "$WG/deskB.key" 10.3.0.2 10.3.0.1 "FI#6" "$WG/srvB.pub" 51821
cp -a "$DROP/wg-FI-6.conf" /tmp/suite-fi6.conf
is "(a server proton-fi-6 is imported)" "$(as_user sudo -n /usr/local/bin/vpnkit-sync sync | jq -r '.imported[0] // empty')" "proton-fi-6"
nmcli connection delete proton-fi-6 >/dev/null
yes "(its profile is deleted outside the kit, its config stays)" test -e /etc/wireguard/proton-fi-6.conf
cp -a /tmp/suite-fi6.conf "$DROP/wg-FI-6.conf"
is "the same file imported again gets its own name back" "$(as_user sudo -n /usr/local/bin/vpnkit-sync sync | jq -r '.imported[0] // empty')" "proton-fi-6"
yes "and is the kit's: it can be deleted, config and all" as_user sudo -n /usr/local/bin/vpnkit-sync remove proton-fi-6
no "(its config is gone)" test -e /etc/wireguard/proton-fi-6.conf
rm -f /tmp/suite-fi6.conf
# A server imported under another provider's prefix (the setting changed
# since) is still the kit's: --purge removes it (section 6).
sed -i 's/^VPNKIT_PROVIDER=.*/VPNKIT_PROVIDER="generic"/' /etc/vpnkit/vpnkit.conf
conf "$DROP/wg-AT-5.conf" "$WG/deskB.key" 10.3.0.2 10.3.0.1 "AT#5" "$WG/srvB.pub" 51821
OLDP=$(as_user sudo -n /usr/local/bin/vpnkit-sync sync | jq -r '.imported[0] // empty')
sed -i 's/^VPNKIT_PROVIDER=.*/VPNKIT_PROVIDER="proton"/' /etc/vpnkit/vpnkit.conf
yes "(a server imported under the generic preset's prefix: $OLDP)" bash -c "[[ '$OLDP' == vpn-* ]]"

# The leak check reads files in the user's folder with the user's rights: a
# symlink there to a file only root may read gives nothing away, and a FIFO
# does not hang it.
install -d -o $U -g $U "$UHOME/.config/qBittorrent"
printf '[BitTorrent]\nSession\\Interface=rootonly0\n' > /root/suite-secret.conf; chmod 600 /root/suite-secret.conf
QCONF_U="$UHOME/.config/qBittorrent/qBittorrent.conf"
[[ -e "$QCONF_U" ]] && mv "$QCONF_U" "$QCONF_U.suite"
ln -s /root/suite-secret.conf "$QCONF_U"
as_user mkfifo "$UHOME/.local/share/applications/suite-fifo.desktop"
OUT=$(timeout 90 vpn-verify 2>&1); rc=$?
yes "the leak check finishes with a FIFO among the launchers (rc $rc)" test "$rc" -ne 124
no "and does not read a root-only file through a symlink" grep -q rootonly0 <<<"$OUT"
rm -f "$QCONF_U" "$UHOME/.local/share/applications/suite-fifo.desktop" /root/suite-secret.conf
[[ -e "$QCONF_U.suite" ]] && mv "$QCONF_U.suite" "$QCONF_U"

# Setup run by another user stops before changing anything: the kit acts for
# one desktop user, and the passwordless rules would go to the other.
OUT=$(bash "$PLUGIN/system/install-root.sh" "$PLUGIN" admin 2>&1); rc=$?
is "setup run by another user stops" "$rc" "1"
yes "and says the kit is set up for $U" grep -q "set up for the desktop user '$U'" <<<"$OUT"
yes "the passwordless rules still name $U" grep -q "^$U ALL=(root) NOPASSWD: /usr/local/bin/qbt-netns-status" /etc/sudoers.d/99-vpnkit
is "and the version stamp is still there" "$(cat /usr/local/lib/vpnkit/VERSION 2>/dev/null)" "$(cat "$PLUGIN/VERSION")"
as_user /usr/local/bin/vpn-toggle proton-ca-1 >/dev/null 2>&1
nmcli connection down proton-ca-1 >/dev/null 2>&1; sleep 1
is "blocked before the rescue" "$(myip)" "none"
yes "vpn-rescue succeeds" as_user env PATH="$PATH" /usr/local/bin/vpn-rescue
is "home address after the rescue" "$(myip)" "$HOME_IP"

# ---------------------------------------------------------------------------
section "6. Reinstall keeps settings; uninstall removes the kit"
QMARK=$(bash -c '. "$1"; printf %s "$VPNKIT_QBT_DESK_MARK"' _ "$PLUGIN/system/lib/owned.sh")
SAVED=/etc/vpnkit/ipv6-profiles.saved
SUPERSEDED=/etc/vpnkit/ipv6-profiles.superseded
# The install's rollback: the internet answers before the install and not
# after it (a lookup service that answers exactly once), so the installer
# must undo its network changes, IPv6 settings included, exactly.
cat > /tmp/oneshot.py <<'PY2'
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"192.0.2.1"
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 8081), H).handle_request()
PY2
# rollback_install <log>: run install.sh while the internet "goes away" during it.
rollback_install() {
  local pid i rc
  python3 /tmp/oneshot.py </dev/null >/dev/null 2>&1 &
  pid=$!
  for i in $(seq 1 40); do ss -ltn | grep -q '127.0.0.1:8081 ' && break; sleep 0.25; done
  sed -i 's|^IP_LOOKUP_URL=.*|IP_LOOKUP_URL="http://127.0.0.1:8081/"|' /etc/vpnkit/vpnkit.conf
  in_terminal "$PLUGIN/install.sh" > "$1" 2>&1; rc=$?
  sed -i "s|^IP_LOOKUP_URL=.*|IP_LOOKUP_URL=\"$LOOKUP\"|" /etc/vpnkit/vpnkit.conf
  kill "$pid" 2>/dev/null
  return "$rc"
}
# has_v6_ll: the physical link has an IPv6 link-local address (within 10 s).
has_v6_ll() {
  local i
  for i in $(seq 1 20); do
    ip -6 addr show dev "$PHYS" scope link | grep -q inet6 && return 0
    sleep 0.5
  done
  return 1
}
# shim <command> <bash condition on "$*">: a stand-in in /usr/local/sbin (first
# in the installer's PATH) that fails when the condition holds, else runs the
# real command. For one run of the installer only.
shim() {
  printf '#!/usr/bin/env bash\n# suite.sh: %s fails for this test\nif %s; then echo "suite: %s fails" >&2; exit 1; fi\nexec /usr/bin/%s "$@"\n' \
    "$1" "$2" "$1" "$1" > "/usr/local/sbin/$1"
  chmod 755 "/usr/local/sbin/$1"
}

direct on >/dev/null 2>&1
direct ssh on >/dev/null 2>&1
# A command as 0.4.0 installed it carries no marker line: an update must still
# know it as the kit's (by its checksum) and replace it without --move-aside.
# The file itself comes from the 0.4.0 release (vm.sh copies it in for section
# 7); this release's vpn-import has changed since.
if [[ -f $UHOME/releases/v0.4.0/system/bin/vpn-import ]]; then
  install -m 755 $UHOME/releases/v0.4.0/system/bin/vpn-import /usr/local/bin/vpn-import
else
  bad "the 0.4.0 release is in the VM (vm.sh copies it from its git tag)"
fi
no "(vpn-import as 0.4.0 left it: no marker)" grep -qxF "$BIN_MARK" /usr/local/bin/vpn-import
# A launcher cache that cannot be updated (update-desktop-database fails, as
# in a read-only or root-owned folder) must not end the run after the system
# part: the user-side steps run under set -e.
shim update-desktop-database 'true'
FFINO=$(stat -Lc %i /run/netns/ffvpn 2>/dev/null)
in_terminal "$PLUGIN/install.sh" --qbt-launcher > /tmp/install2.log 2>&1; rc=$?
is "install.sh can be run again" "$rc" "0"
(( rc == 0 )) || sed 's/^/      /' /tmp/install2.log | tail -15
yes "with a launcher cache that cannot be updated, it still gets to the end" grep -q "==> Done" /tmp/install2.log
no "and vpn-direct does not fail on it (the Chrome entry is written)" grep -q "could not update the Chrome launcher entry" /tmp/install2.log
OUT=$(as_user /usr/local/bin/vpn-direct launcher 2>&1); rc=$?
is "vpn-direct launcher exits 0 all the same" "$rc" "0"
rm -f /usr/local/sbin/update-desktop-database
is "settings survive a reinstall" "$(. /etc/vpnkit/vpnkit.conf; echo "$BYPASS_CIDRS")" "198.51.100.80/32"
is "the running torrent tunnel was left alone" "$(ip netns exec qbtvpn curl -4 -s --max-time 4 $LOOKUP)" "10.2.0.3"
is "the running Firefox tunnel was left alone (the same namespace)" "$(stat -Lc %i /run/netns/ffvpn 2>/dev/null)" "${FFINO:-missing}"
is "and still exits through its server" "$(ip netns exec ffvpn curl -4 -s --max-time 4 $LOOKUP)" "10.3.0.4"
yes "and stays enabled" systemctl is-enabled --quiet ff-netns.service
yes "Chrome direct stays on through a reinstall" systemctl is-active --quiet vpnkit-direct.service
yes "with its rules" nft list table inet vpnkit_direct
is "SSH direct stays on through a reinstall, with its rules" "$(direct status | jq -c '[.rules, .ssh.enabled, .ssh.rules]')" "[true,true,true]"
is "a reinstall writes the launcher override while it is on" "$(head -1 "$DESK" 2>/dev/null)" "$MARK"
is "an update replaces a command 0.4.0 installed (no marker) without --move-aside" "$(sed -n 2p /usr/local/bin/vpn-import)" "$BIN_MARK"
yes "with secure_path off in sudoers, setup says so" grep -q "sudo has no secure_path" /tmp/install2.log
rm -f "$NOSP"
is "--qbt-launcher replaces the user's own qBittorrent entry with the kit's" "$(head -1 "$QDESK" 2>/dev/null)" "$QMARK"
yes "which starts the wrapper" grep -qx 'Exec=/usr/local/bin/qbittorrent %U' "$QDESK"
is "the user's entry is backed up next to it" "$(cat "$QDESK".bak.* 2>/dev/null | sha256sum)" "$QDESK_SUM"
as_user /usr/local/bin/vpn-toggle proton-ca-1 >/dev/null 2>&1
is "and a probe in the slice still exits from the home address" "$(slice_ip)" "$HOME_IP"

# --keep-ipv6 (DISABLE_IPV6=0) on an existing install gives IPv6 back, as
# the sysctl file and the settings say: sysctl file gone, IPv6 on, every saved
# profile restored and applied to its running link.
# The same run in German (sudo keeps LANG, and its -V text is translated):
# the secure_path check must still see that sudo has one. And the user's
# qBittorrent entry is a dangling link: it cannot be read, which must not end
# the run either.
localedef -i de_DE -f UTF-8 de_DE.UTF-8 >/dev/null 2>&1
no "(control: in German, sudo -V does not say \"Value to override\")" \
  bash -c 'LANG=de_DE.UTF-8 sudo -V | grep -q "Value to override user"'
yes "(control: and it does name secure_path's value)" bash -c 'LANG=de_DE.UTF-8 sudo -V | grep -q "/usr/local/sbin:/usr/local/bin:/usr/bin"'
mv "$QDESK" /tmp/suite-qdesk.kit
ln -s "$UHOME/suite-no-such.desktop" "$QDESK"; chown -h $U:$U "$QDESK"
in_terminal env LANG=de_DE.UTF-8 "$PLUGIN/install.sh" --keep-ipv6 > /tmp/install-keep.log 2>&1; rc=$?
is "install.sh --keep-ipv6 on an existing install exits 0" "$rc" "0"
(( rc == 0 )) || sed 's/^/      /' /tmp/install-keep.log | tail -15
no "in German, setup does not warn about a secure_path sudo has" grep -q "sudo has no secure_path" /tmp/install-keep.log
yes "a qBittorrent entry that is a dangling link is reported as starting nothing" grep -q "starts nothing," /tmp/install-keep.log
yes "and the run gets to the end" grep -q "==> Done" /tmp/install-keep.log
yes "the dangling link is left as it is" test -L "$QDESK"
rm -f "$QDESK"; mv /tmp/suite-qdesk.kit "$QDESK"
is "it sets DISABLE_IPV6=0" "$(sed -n 's/^DISABLE_IPV6=//p' /etc/vpnkit/vpnkit.conf)" "0"
yes "after backing vpnkit.conf up" bash -c 'grep -qx DISABLE_IPV6=1 /etc/vpnkit/vpnkit.conf.bak.*'
no "the sysctl file is gone" test -e /etc/sysctl.d/99-vpnkit-disable-ipv6.conf
is "IPv6 is on again" "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" "0"
is "the physical profile's IPv6 method is back" "$(nmcli -g ipv6.method connection show "$PPROF")" "auto"
is "and its IPv6 DNS server" "$(nmcli -g ipv6.dns connection show "$PPROF" | sed 's/\\:/:/g')" "2606:4700:4700::1111"
yes "and IPv6 is back on the running link" has_v6_ll
same_static "--keep-ipv6 restores the static profile"
no "the saved settings are cleared" test -s "$SAVED"
sed -i 's/^DISABLE_IPV6=.*/DISABLE_IPV6=1/' /etc/vpnkit/vpnkit.conf

# Profiles for the restore below. TPROF: switched off by setup, then turned
# back on by the user with new settings. TW1/TW2: two profiles of the same
# name, TW1 switched off by a version before 0.4.1 (a line by name), TW2
# with IPv6 on. GPROF: switched off by setup, then deleted.
TPROF="suite turned on"
nmcli connection add type ethernet con-name "$TPROF" ifname suitest6 autoconnect no ipv4.method disabled \
  ipv6.method auto ipv6.dns 2001:db8::71 >/dev/null
TW="suite twin"
nmcli connection add type ethernet con-name "$TW" ifname suitest7 autoconnect no ipv4.method disabled ipv6.method disabled >/dev/null
TW1=$(nmcli -g connection.uuid connection show "$TW")
nmcli connection add type ethernet con-name "$TW" ifname suitest8 autoconnect no ipv4.method disabled \
  ipv6.method auto ipv6.dns 2001:db8::72 >/dev/null 2>&1   # (NetworkManager warns: same name)
TW2=$(nmcli -g UUID,NAME connection show | awk -F: -v n="$TW" -v u="$TW1" '$2 == n && $1 != u {print $1}')
printf '%s\tauto\t2001:db8::73\texample.test\n' "$TW" >> "$SAVED"
GPROF="suite gone"
nmcli connection add type ethernet con-name "$GPROF" ifname suitest9 autoconnect no ipv4.method disabled ipv6.method auto >/dev/null
# The qBittorrent entry as 0.3.0 to 0.4.0 wrote it (no marker line): an update
# takes it over without --qbt-launcher, and keeps the user's backup.
cp "$PLUGIN/applications/org.qbittorrent.qBittorrent.desktop" "$QDESK"; chown $U:$U "$QDESK"
# TARGET_USER edited by hand, in single quotes with a comment: the helpers
# (which source the file) read the same user, and so must setup.
sed -i "s/^TARGET_USER=.*/TARGET_USER='$U'   # the desktop user (suite: quoted, with a comment)/" /etc/vpnkit/vpnkit.conf
# A kernel started with ipv6.disable=1 has no /proc/sys/net/ipv6/conf (hidden
# here under a tmpfs, in a mount namespace of the test's own, which the
# installer inherits): sysctl fails on those keys, and setup must still finish.
unshare --mount --propagation slave bash -c 'mount -t tmpfs suite-noipv6 /proc/sys/net/ipv6 || exit 9; exec "$@"' _ \
  runuser -u $U -- env HOME=$UHOME USER=$U XDG_RUNTIME_DIR=/run/user/$UID_T PATH="$PATH" \
  python3 "$PLUGIN/tests/vm/with-password.py" tester "$PLUGIN/install.sh" > /tmp/install-noipv6.log 2>&1; rc=$?
is "on a kernel without IPv6, setup finishes" "$rc" "0"
(( rc == 0 )) || sed 's/^/      /' /tmp/install-noipv6.log | tail -15
yes "and says there is nothing to switch off now" grep -q "this kernel has no IPv6" /tmp/install-noipv6.log
no "a quoted TARGET_USER with a comment is not taken for another user" grep -q "set up for the desktop user" /tmp/install-noipv6.log
is "it writes the version stamp" "$(cat /usr/local/lib/vpnkit/VERSION 2>/dev/null)" "$(cat "$PLUGIN/VERSION")"
is "and switches the profiles off all the same" "$(nmcli -g ipv6.method connection show "$PPROF")" "disabled"
is "the qBittorrent entry 0.4.0 wrote is taken over" "$(head -1 "$QDESK" 2>/dev/null)" "$QMARK"
is "and the user's backup is still the only one" "$(ls "$QDESK".bak.* 2>/dev/null | wc -l):$(cat "$QDESK".bak.* 2>/dev/null | sha256sum)" "1:$QDESK_SUM"
# What the next boot, with IPv6 in the kernel, does with the file.
sysctl -q -p /etc/sysctl.d/99-vpnkit-disable-ipv6.conf
yes "a line from before 0.4.1 is not taken over by another profile of that name" \
  grep -qP "^\Q$TW\E\tauto\t" "$SAVED"
is "(that other profile is switched off and saved)" "$(nmcli -g ipv6.method connection show uuid "$TW2")" "disabled"
nmcli connection modify "$TPROF" ipv6.method auto ipv6.dns 2001:db8::77
TDUMP=$(nmcli -e no -f ipv6 connection show "$TPROF")
nmcli connection delete "$GPROF" >/dev/null
# A line saved by a version before 0.4.1 (name, method, dns, dns-search) must
# still be restored; and a profile switched off by a version before 0.3.6,
# which saved nothing, gets ipv6.method=auto back as before.
OPROF="suite legacy"
nmcli connection add type ethernet con-name "$OPROF" ifname suitest2 autoconnect no ipv4.method disabled ipv6.method disabled >/dev/null
printf '%s\tauto\t2001:db8::53\texample.test\n' "$OPROF" >> "$SAVED"
# Profiles the install never changed must come out of the restore exactly as
# they went in: one the user had switched off, and one joined after setup
# with IPv6 DNS servers of its own.
NPROF="suite user-disabled"
nmcli connection add type ethernet con-name "$NPROF" ifname suitest3 autoconnect no ipv4.method disabled ipv6.method disabled >/dev/null
JPROF="suite joined later"
nmcli connection add type ethernet con-name "$JPROF" ifname suitest5 autoconnect no ipv4.method disabled \
  ipv6.method auto ipv6.dns 2001:db8::99 ipv6.dns-search joined.example.test >/dev/null
JDUMP=$(nmcli -e no -f ipv6 connection show "$JPROF")
# A file of the user's where the kit has a command: the uninstaller keeps it.
printf '#!/bin/sh\n# the user own vpnkit-pick (suite)\n' > /usr/local/bin/vpnkit-pick
# The README's way when the plugin folder is already gone: the system part's
# own copy of the uninstaller, as root. It also switches to the normal
# connection, and removes the launcher entries (as the user).
bash /usr/local/lib/vpnkit/uninstall-root.sh --restore-ipv6 > /tmp/uninstall.log 2>&1; rc=$?
is "the installed uninstaller (plugin folder gone) exits 0" "$rc" "0"
(( rc == 0 )) || sed 's/^/      /' /tmp/uninstall.log | tail -15
is "home address after uninstall" "$(myip)" "$HOME_IP"
no "kill switch gone" nft list table inet vpnkit_kill
no "Chrome direct rules gone" nft list table inet vpnkit_direct
no "Chrome direct fwmark rules gone" direct_rule
no "Chrome direct slice gone" test -d "$DSLICE"
no "Chrome direct units gone" bash -c 'ls /etc/systemd/system/vpnkit-direct.service /etc/systemd/system/vpnkitdirect.slice 2>/dev/null | grep -q .'
no "Chrome direct and SSH direct state gone" test -e /etc/vpnkit/direct-apps
no "SSH direct's rules gone (no marking left)" bash -c 'nft list ruleset | grep -q "ct mark set 0x0000ca6d"'
no "namespace gone" bash -c "ip netns list | grep -qw qbtvpn"
no "helpers gone" test -e /usr/local/bin/vpn-status
no "Chrome direct helpers gone" bash -c 'ls /usr/local/bin/vpnkit-direct /usr/local/bin/vpnkit-direct-rules /usr/local/bin/vpn-direct /usr/local/bin/direct-launch 2>/dev/null | grep -q .'
is "the admin's own google-chrome-stable is put back" "$(sha256sum < /usr/local/bin/google-chrome-stable)" "$ADMIN_SUM"
is "a file of the user's with a kit command's name is kept" "$(sed -n 2p /usr/local/bin/vpnkit-pick)" "# the user own vpnkit-pick (suite)"
yes "and the uninstaller says so" grep -q "kept /usr/local/bin/vpnkit-pick: it is not omarchy-proton's" /tmp/uninstall.log
rm -f /usr/local/bin/vpnkit-pick /usr/local/bin/google-chrome-stable
no "nothing is left in /usr/local/lib/vpnkit" test -e /usr/local/lib/vpnkit
no "uninstall removes the Chrome launcher override (as the user)" test -e "$DESK"
is "and puts the user's own qBittorrent entry back" "$(sha256sum < "$QDESK" 2>/dev/null)" "$QDESK_SUM"
no "from its backup (moved back, not copied)" bash -c "ls '$QDESK'.bak.* 2>/dev/null | grep -q ."
no "sudoers rule gone" test -e /etc/sudoers.d/99-vpnkit
no "dispatcher hook gone" test -e /etc/NetworkManager/dispatcher.d/50-vpnkit
no "service gone" test -e /etc/systemd/system/qbt-netns.service
no "the Firefox tunnel's unit gone" test -e /etc/systemd/system/ff-netns.service
no "the Firefox namespace gone" bash -c "ip netns list | grep -qw ffvpn"
no "and its resolver files" test -e /etc/netns/ffvpn
is "IPv6 back on" "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" "0"
is "the physical profile's IPv6 method is back" "$(nmcli -g ipv6.method connection show "$PPROF")" "auto"
is "and its IPv6 DNS server is back" "$(nmcli -g ipv6.dns connection show "$PPROF" | sed 's/\\:/:/g')" "2606:4700:4700::1111"
no "the saved IPv6 settings are cleared" test -e "$SAVED"
same_static "uninstall --restore-ipv6 restores the static profile"
is "a line saved before 0.4.1 is restored: method" "$(nmcli -g ipv6.method connection show "$OPROF")" "auto"
is "a line saved before 0.4.1 is restored: dns" "$(nmcli -g ipv6.dns connection show "$OPROF" | sed 's/\\:/:/g')" "2001:db8::53"
is "a line saved before 0.4.1 is restored: dns-search" "$(nmcli -g ipv6.dns-search connection show "$OPROF")" "example.test"
is "a profile the user had switched off stays off (nothing saved for it)" "$(nmcli -g ipv6.method connection show "$NPROF")" "disabled"
is "a profile joined after setup keeps its IPv6 DNS and everything else" "$(nmcli -e no -f ipv6 connection show "$JPROF")" "$JDUMP"
is "a profile the install never changed is left alone by the restore" "$(nmcli -e no -f ipv6 connection show uuid "$LUUID")" "$LDUMP"
is "a profile turned back on after setup keeps the user's new settings" "$(nmcli -e no -f ipv6 connection show "$TPROF")" "$TDUMP"
yes "and the uninstaller says why it left it" grep -qF "\"$TPROF\" was turned back on since setup" /tmp/uninstall.log
is "of two profiles of one name, the one switched off before 0.4.1 gets that line: method" \
  "$(nmcli -g ipv6.method connection show uuid "$TW1")" "auto"
is "and dns" "$(nmcli -g ipv6.dns connection show uuid "$TW1" | sed 's/\\:/:/g')" "2001:db8::73"
is "the other gets its own settings back" "$(nmcli -g ipv6.dns connection show uuid "$TW2" | sed 's/\\:/:/g')" "2001:db8::72"
yes "a deleted profile is named" grep -qF "the profile \"$GPROF\" no longer exists" /tmp/uninstall.log
yes "and its saved settings are kept aside, not thrown away" grep -qF "$(printf '%s' "$GPROF" | base64 -w0)" "$SUPERSEDED"
no "the uninstall printed no IPv6 warning" grep -q "IPv6: could not" /tmp/uninstall.log
nmcli connection delete "$OPROF" "$NPROF" "$JPROF" "$TPROF" >/dev/null
nmcli connection delete uuid "$TW1" uuid "$TW2" >/dev/null

# A step that fails half way (here systemctl daemon-reload), after the
# profiles were switched off, on a run that also loses the internet: the
# connectivity check and its rollback still run, and the run does not count
# as finished.
shim systemctl '[[ "$*" == daemon-reload ]]'
no "an install that stops half way fails" rollback_install /tmp/install-abort.log
rm -f /usr/local/sbin/systemctl
yes "it says where it stopped" grep -q "Setup stopped during: Installing qbt-netns.service" /tmp/install-abort.log
yes "the connectivity check still ran, and rolled back" grep -q "No internet after the install - undoing" /tmp/install-abort.log
same_static "the rollback after a failed step restores the static profile"
is "and the physical profile" "$(nmcli -g ipv6.method connection show "$PPROF")" "auto"
no "and removes the sysctl file" test -e /etc/sysctl.d/99-vpnkit-disable-ipv6.conf
no "there is no version stamp: the panel keeps offering setup" test -e /usr/local/lib/vpnkit/VERSION
is "vpn-status reports the version as unknown" "$(status .version)" "unknown"

no "an install that loses the internet fails" rollback_install /tmp/install-rollback.log
yes "and undoes its network changes" grep -q "No internet after the install - undoing" /tmp/install-rollback.log
yes "it had switched the static profile off first" grep -qF "\"$SPROF\" had static IPv6" /tmp/install-rollback.log
same_static "the rollback restores the static profile"
is "the rollback restores the physical profile's IPv6 method" "$(nmcli -g ipv6.method connection show "$PPROF")" "auto"
is "and its IPv6 DNS server" "$(nmcli -g ipv6.dns connection show "$PPROF" | sed 's/\\:/:/g')" "2606:4700:4700::1111"
yes "and applies it to the running link: IPv6 is back on $PHYS without a reconnect" has_v6_ll
is "the rollback turns IPv6 back on" "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" "0"
no "the rollback removes the sysctl file" test -e /etc/sysctl.d/99-vpnkit-disable-ipv6.conf
no "the rollback forgets the entries it restored" test -s "$SAVED"
no "the rollback printed no IPv6 warning" grep -q "IPv6: could not" /tmp/install-rollback.log
no "and leaves no version stamp" test -e /usr/local/lib/vpnkit/VERSION
yes "servers are kept by a plain uninstall" nmcli connection show proton-ca-1
yes "settings are kept by a plain uninstall" test -f /etc/vpnkit/vpnkit.conf
yes "the leak-check reports are kept by a plain uninstall" test -s "$REPORTS/latest.txt"

# Steps that fail without stopping the run: a reapply NetworkManager refuses
# (only a warning), no systemd-resolved to ask (the global-DNS note is
# skipped), and a unit that cannot be enabled (the run goes on to the
# connectivity check, then says it is not finished). Run without
# XDG_RUNTIME_DIR, as over SSH.
rm -f /tmp/vpnkit-install.log "$UHOME/.cache/vpnkit-install.log"
install -d -o $U -g $U -m 755 "$UHOME/.cache"; chmod 755 "$UHOME/.cache"
shim nmcli '[[ " $* " == *" device reapply "* ]]'
shim resolvectl 'true'
shim systemctl '[[ "$*" == "enable qbt-netns.service" ]]'
in_terminal env -u XDG_RUNTIME_DIR "$PLUGIN/install.sh" > /tmp/install3.log 2>&1; rc=$?
rm -f /usr/local/sbin/nmcli /usr/local/sbin/resolvectl /usr/local/sbin/systemctl
is "an install with a step that failed exits 1" "$rc" "1"
yes "and says it is not finished, naming the step" grep -A3 "Setup is not finished" /tmp/install3.log
yes "(enabling qbt-netns.service)" grep -q "^    enabling qbt-netns.service" <(tr -d '\r' < /tmp/install3.log)
yes "a reapply NetworkManager refuses is only a warning" grep -q "could not apply the change to the running link $PHYS" /tmp/install3.log
yes "the run went on to the connectivity check" grep -q "internet OK" /tmp/install3.log
no "and wrote no version stamp" test -e /usr/local/lib/vpnkit/VERSION
is "the static profile is switched off again" "$(nmcli -g ipv6.method connection show uuid "$SUUID")" "disabled"
is "without XDG_RUNTIME_DIR the install log is in ~/.cache, the user's only" \
  "$(stat -c '%a %U' "$UHOME/.cache/vpnkit-install.log" 2>/dev/null)" "600 $U"
no "and not in /tmp" test -e /tmp/vpnkit-install.log
is "an existing ~/.cache keeps its mode" "$(stat -c %a "$UHOME/.cache")" "755"
# A rollback during an update leaves IPv6 as the earlier install set it.
no "an update that loses the internet fails" rollback_install /tmp/install-rollback2.log
yes "and rolls back" grep -q "No internet after the install - undoing" /tmp/install-rollback2.log
yes "but keeps the earlier install's sysctl file" test -e /etc/sysctl.d/99-vpnkit-disable-ipv6.conf
is "and IPv6 stays off" "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" "1"
is "the static profile stays off" "$(nmcli -g ipv6.method connection show uuid "$SUUID")" "disabled"
is "and its saved settings stay" "$(saved "$SUUID" addresses)" "2001:db8:1::10/64, 2001:db8:1::11/64"
# A static profile switched off by a version before 0.4.1: its addresses were
# not saved and are gone. Restoring it must fail loudly, name it, and keep it.
MPROF="suite legacy manual"
nmcli connection add type ethernet con-name "$MPROF" ifname suitest4 autoconnect no ipv4.method disabled ipv6.method disabled >/dev/null
printf '%s\tmanual\t2001:db8::53\texample.test\n' "$MPROF" >> "$SAVED"
# A step of the root half that fails (here: Chrome direct's unit refuses to
# stop) is reported, and everything else is still removed, the user's part
# included. A temporary folder an aborted qbt-netns-up left is removed too.
direct on >/dev/null 2>&1
install -d /etc/netns/.vpnkit-qbtvpn.suite1
install -d /run/systemd/system/vpnkit-direct.service.d
printf '[Unit]\nRefuseManualStop=yes\n' > /run/systemd/system/vpnkit-direct.service.d/suite.conf
systemctl daemon-reload
in_terminal "$PLUGIN/uninstall.sh" --purge > /tmp/uninstall2.log 2>&1; rc=$?
is "uninstall.sh --purge reports a failed step of the system part" "$rc" "1"
yes "and says so" grep -q "reported a problem" /tmp/uninstall2.log
yes "but finishes" grep -q "==> Done" /tmp/uninstall2.log
no "Chrome direct's rules are gone even so" nft list table inet vpnkit_direct
no "and its fwmark rules" direct_rule
rm -rf /run/systemd/system/vpnkit-direct.service.d; systemctl daemon-reload
systemctl stop vpnkit-direct.service vpnkitdirect.slice >/dev/null 2>&1
no "--purge removes the servers" nmcli connection show proton-ca-1
no "--purge removes the torrent config" test -e /etc/wireguard/vpnkit-torrent.conf
no "--purge removes the Firefox config" test -e /etc/wireguard/vpnkit-firefox.conf
no "--purge removes a server imported under another provider's prefix ($OLDP)" nmcli connection show "$OLDP"
no "and its config" test -e "/etc/wireguard/$OLDP.conf"
yes "--purge leaves a profile of the user's with the kit's prefix" nmcli connection show uuid "$MINE_UUID"
yes "and the user's own WireGuard configs" test -e /etc/wireguard/proton-mine.conf -a -e /etc/wireguard/proton-de-4.conf
no "--purge removes the settings" test -e /etc/vpnkit/vpnkit.conf
is "but keeps the saved IPv6 settings (the only copy of the static ones) and the superseded ones" \
  "$(ls -A /etc/vpnkit | paste -sd' ' -)" "ipv6-profiles.saved ipv6-profiles.superseded"
yes "and says how to put them back" grep -q "Kept /etc/vpnkit/ipv6-profiles" /tmp/uninstall2.log
is "the user's own qBittorrent entry is left alone" "$(sha256sum < "$QDESK" 2>/dev/null)" "$QDESK_SUM"
no "a temporary folder qbt-netns-up left behind is removed" test -e /etc/netns/.vpnkit-qbtvpn.suite1
# With the system part gone, the plugin folder's uninstall.sh still restores
# them (its own copy of the library), in the combined form the README gives.
# The legacy static profile cannot be restored: reported, named, kept;
# everything else is put back.
in_terminal "$PLUGIN/uninstall.sh" --purge --restore-ipv6 > /tmp/uninstall3.log 2>&1; rc=$?
is "uninstall.sh --purge --restore-ipv6 reports the profile it could not restore" "$rc" "1"
yes "it names that profile" grep -qF "could not restore \"$MPROF\" (ipv6.method manual)" /tmp/uninstall3.log
yes "and says its addresses were never saved" grep -q "cleared by a version before 0.4.1" /tmp/uninstall3.log
yes "and that the saved file is kept for those profiles" grep -q "which could not be put back" /tmp/uninstall3.log
no "and does not claim IPv6 is re-enabled" grep -q "IPv6 re-enabled" /tmp/uninstall3.log
is "that profile keeps IPv6 off, not a guessed auto" "$(nmcli -g ipv6.method connection show "$MPROF")" "disabled"
is "only its entry is left, and --purge keeps it" "$(cut -f1 "$SAVED")" "$MPROF"
same_static "the plugin folder's uninstall restores the static profile"
is "and the physical profile's IPv6 method" "$(nmcli -g ipv6.method connection show "$PPROF")" "auto"
yes "and IPv6 is back on the running link" has_v6_ll
# NetworkManager not running: nothing can be restored, and nothing saved may
# be lost (no profile can be looked up, which is not "the profile is gone").
SAVED_SUM=$(sha256sum < "$SAVED")
systemctl stop NetworkManager
in_terminal "$PLUGIN/uninstall.sh" --purge --restore-ipv6 > /tmp/uninstall-nm.log 2>&1; rc=$?
systemctl start NetworkManager
for i in $(seq 1 60); do
  [[ "$(nmcli -t -f RUNNING general status 2>/dev/null)" == running ]] \
    && nmcli -t -f GENERAL.STATE device show "$PHYS" 2>/dev/null | grep -q '(connected)' && break
  sleep 0.5
done
gateway on
is "with NetworkManager stopped, --restore-ipv6 fails" "$rc" "1"
yes "and says why" grep -q "NetworkManager is not running, so no profile was restored" /tmp/uninstall-nm.log
is "the saved settings are kept, unchanged" "$(sha256sum < "$SAVED" 2>/dev/null)" "$SAVED_SUM"
# Once nothing is left to restore, --purge --restore-ipv6 removes it all. A
# saved line whose profile was deleted is named and put aside.
nmcli connection delete "$MPROF" >/dev/null
in_terminal "$PLUGIN/uninstall.sh" --purge --restore-ipv6 > /tmp/uninstall4.log 2>&1; rc=$?
is "uninstall.sh --purge --restore-ipv6 then exits 0" "$rc" "0"
(( rc == 0 )) || sed 's/^/      /' /tmp/uninstall4.log | tail -15
yes "naming the deleted profile whose line it put aside" grep -qF "the profile \"$MPROF\" no longer exists" /tmp/uninstall4.log
no "and /etc/vpnkit is gone" test -e /etc/vpnkit
nmcli connection delete "$SPROF" "$LPROF" >/dev/null
nmcli connection delete uuid "$MINE_UUID" >/dev/null
rm -f /etc/wireguard/proton-mine.conf /etc/wireguard/proton-de-4.conf
no "--purge removes the leak-check reports" test -e "$REPORTS"
is "home address at the end" "$(myip)" "$HOME_IP"
gateway off
yes "real internet still works" curl -4 -s --max-time 8 -o /tmp/out https://archlinux.org

# ---------------------------------------------------------------------------
section "7. Upgrade from an earlier release, then uninstall"
# The way a user upgrades: the plugin folder holds the earlier release (its
# own files, from its git tag) and its setup has run; `omarchy plugin update`
# replaces the folder; "Update the system part" runs install.sh with no
# options; later the README's uninstall. Nothing the earlier release installed
# may count as someone else's: no refusal, no launcher left to the user, and
# nothing kept as "not omarchy-proton's".
OLD=$(grep -m1 -E '^[A-Za-z0-9._-]+$' "$PLUGIN/tests/vm/upgrade-from" 2>/dev/null)
OLDTREE=$UHOME/releases/$OLD
if [[ -z "$OLD" || ! -f "$OLDTREE/install.sh" ]]; then
  bad "the earlier release ${OLD:-(none named)} is in the VM (vm.sh copies it from its git tag)"
else
  OLDV=$(cat "$OLDTREE/VERSION")
  cp "$PLUGIN/tests/vm/with-password.py" /tmp/with-password.py
  mv "$PLUGIN" "$PLUGIN.suite-new"
  cp -a "$OLDTREE" "$PLUGIN"
  as_user python3 /tmp/with-password.py tester "$PLUGIN/install.sh" > /tmp/old-install.log 2>&1; rc=$?
  is "$OLD: its install.sh exits 0" "$rc" "0"
  (( rc == 0 )) || sed 's/^/      /' /tmp/old-install.log | tail -15
  is "$OLD: it is installed" "$(cat /usr/local/lib/vpnkit/VERSION 2>/dev/null)" "$OLDV"
  is "$OLD: its qBittorrent entry (no marker) replaced the user's" "$(sha256sum < "$QDESK")" "$(sha256sum < "$OLDTREE/applications/org.qbittorrent.qBittorrent.desktop")"
  is "$OLD: the user's entry is backed up next to it" "$(cat "$QDESK".bak.* 2>/dev/null | sha256sum)" "$QDESK_SUM"
  is "$OLD: IPv6 is off on the physical profile" "$(nmcli -g ipv6.method connection show "$PPROF")" "disabled"
  # Two servers imported by the earlier release.
  conf "$DROP/wg-CA-1.conf" "$WG/deskA.key" 10.2.0.2 10.2.0.1 "CA#1" "$WG/srvA.pub" 51820
  conf "$DROP/wg-SE-2.conf" "$WG/deskB.key" 10.3.0.2 10.3.0.1 "SE#2" "$WG/srvB.pub" 51821
  is "$OLD: imports two servers" "$(as_user sudo -n /usr/local/bin/vpnkit-sync sync | jq -r '.imported | sort | join(",")')" "proton-ca-1,proton-se-2"
  # omarchy plugin update: the folder now holds this release.
  rm -rf "$PLUGIN"; mv "$PLUGIN.suite-new" "$PLUGIN"
  in_terminal "$PLUGIN/install.sh" > /tmp/upgrade.log 2>&1; rc=$?
  is "the update from $OLD (install.sh, no options) exits 0" "$rc" "0"
  (( rc == 0 )) || sed 's/^/      /' /tmp/upgrade.log | tail -25
  yes "and gets to the end" grep -q "==> Done" /tmp/upgrade.log
  no "it refuses nothing as not the kit's" grep -qiE "not omarchy-proton's|--move-aside" /tmp/upgrade.log
  no "it leaves no launcher entry to the user (no warning, no --qbt-launcher)" grep -qiE "your own|--qbt-launcher|skips the torrent tunnel" /tmp/upgrade.log
  no "it moves nothing aside" test -e /usr/local/lib/vpnkit/moved-aside
  is "it is installed" "$(cat /usr/local/lib/vpnkit/VERSION 2>/dev/null)" "$(cat "$PLUGIN/VERSION")"
  no "the update does not turn the Firefox tunnel on (opt-in)" systemctl is-enabled --quiet ff-netns.service
  unmarked=""
  for f in "$PLUGIN"/system/bin/*; do
    [[ "$(sed -n 2p "/usr/local/bin/${f##*/}" 2>/dev/null)" == "$BIN_MARK" ]] || unmarked+=" ${f##*/}"
  done
  is "every command is replaced by this release's (marker line)" "$unmarked" ""
  is "the earlier release's qBittorrent entry is taken over" "$(head -1 "$QDESK" 2>/dev/null)" "$QMARK"
  is "and the user's backup is kept, the only one" "$(ls "$QDESK".bak.* 2>/dev/null | wc -l):$(cat "$QDESK".bak.* 2>/dev/null | sha256sum)" "1:$QDESK_SUM"
  is "IPv6 stays off on the physical profile" "$(nmcli -g ipv6.method connection show "$PPROF")" "disabled"
  is "the servers $OLD imported are listed" "$(as_user /usr/local/bin/vpn-status --json | jq -r '.profiles | sort | join(",")' 2>/dev/null)" "proton-ca-1,proton-se-2"
  yes "a server $OLD imported is the kit's: it can be deleted" as_user sudo -n /usr/local/bin/vpnkit-sync remove proton-se-2
  no "(its config is gone)" test -e /etc/wireguard/proton-se-2.conf
  CA1_UUID=$(nmcli -g connection.uuid connection show proton-ca-1)
  CONNECTION_ID=proton-ca-1 CONNECTION_UUID=$CA1_UUID /etc/NetworkManager/dispatcher.d/50-vpnkit proton-ca-1 up
  yes "the hook arms the kill switch for a server $OLD imported" nft list table inet vpnkit_kill
  /usr/local/bin/vpnkit-killswitch off >/dev/null
  in_terminal "$PLUGIN/uninstall.sh" --purge --restore-ipv6 > /tmp/upgrade-uninstall.log 2>&1; rc=$?
  is "then uninstall.sh --purge --restore-ipv6 exits 0" "$rc" "0"
  (( rc == 0 )) || sed 's/^/      /' /tmp/upgrade-uninstall.log | tail -25
  no "it keeps nothing as not the kit's" grep -qiE "not omarchy-proton's|kept /usr/local/bin" /tmp/upgrade-uninstall.log
  left=""
  for f in "$PLUGIN"/system/bin/*; do
    [[ -e "/usr/local/bin/${f##*/}" || -L "/usr/local/bin/${f##*/}" ]] && left+=" ${f##*/}"
  done
  is "no command is left in /usr/local/bin" "$left" ""
  no "nothing is left in /usr/local/lib/vpnkit" test -e /usr/local/lib/vpnkit
  no "nor in /etc/vpnkit" test -e /etc/vpnkit
  no "the server $OLD imported is purged" nmcli connection show proton-ca-1
  no "with its config" test -e /etc/wireguard/proton-ca-1.conf
  is "the user's own qBittorrent entry is back" "$(sha256sum < "$QDESK" 2>/dev/null)" "$QDESK_SUM"
  no "from the backup $OLD made (moved back)" bash -c "ls '$QDESK'.bak.* 2>/dev/null | grep -q ."
  is "IPv6 is on again" "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" "0"
  is "the physical profile's IPv6 method is back (saved by $OLD)" "$(nmcli -g ipv6.method connection show "$PPROF")" "auto"
  is "and its IPv6 DNS server" "$(nmcli -g ipv6.dns connection show "$PPROF" | sed 's/\\:/:/g')" "2606:4700:4700::1111"
  yes "real internet still works after the upgrade and the uninstall" curl -4 -s --max-time 8 -o /tmp/out https://archlinux.org
fi

pkill -f whoami.py; pkill -x dnsmasq
printf '\nResult: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
