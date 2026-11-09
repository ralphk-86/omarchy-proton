# ============================================================================
#  common.sh - shared configuration loader.
#
#  Installed to /usr/local/lib/vpnkit/common.sh and sourced by every script in
#  this kit, privileged and unprivileged alike. Sourcing it gives you every
#  setting from /etc/vpnkit/vpnkit.conf with provider defaults already applied.
#
#  Load order, lowest priority first:
#    1. the built-in defaults below
#    2. the provider preset  /etc/vpnkit/providers/$VPNKIT_PROVIDER.conf
#    3. the site config      /etc/vpnkit/vpnkit.conf
#
#  This file must stay POSIX-ish and side-effect free: it is sourced by scripts
#  running as root and by scripts running as you.
# ============================================================================

VPNKIT_ETC="${VPNKIT_ETC:-/etc/vpnkit}"

# ------------------------------------------------------------- defaults -----
# Chosen so the kit still works if vpnkit.conf is missing entirely.
NS="qbtvpn"
WG_IF="pqbt0"
QBT_CONF=""
PROFILE_PREFIX="vpn"
FALLBACK_DNS="1.1.1.1"
SERVER_TAG_REGEX=''
TARGET_USER=""
CONFIG_DIR=""
IP_CACHE_TTL=30
IP_LOOKUP_URL="https://ifconfig.me/ip"
HANDSHAKE_MAX_AGE=240
DISABLE_IPV6=1
BYPASS_CIDRS=""
VPN_FWMARK=51820
DIRECT_DNS=""
KILLSWITCH_ALLOW_LAN=1
REPORT_DIR=""
LAN_CIDRS="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 224.0.0.0/4 255.255.255.255/32"
VPNKIT_PROVIDER="proton"

# --- pass 1: read the site config just to learn which provider is selected ---
if [ -r "$VPNKIT_ETC/vpnkit.conf" ]; then
  # shellcheck disable=SC1090
  . "$VPNKIT_ETC/vpnkit.conf"
fi

# --- pass 2: provider preset ------------------------------------------------
if [ -n "${VPNKIT_PROVIDER:-}" ] && [ -r "$VPNKIT_ETC/providers/$VPNKIT_PROVIDER.conf" ]; then
  # shellcheck disable=SC1090
  . "$VPNKIT_ETC/providers/$VPNKIT_PROVIDER.conf"
fi

# --- pass 3: site config wins ----------------------------------------------
if [ -r "$VPNKIT_ETC/vpnkit.conf" ]; then
  # shellcheck disable=SC1090
  . "$VPNKIT_ETC/vpnkit.conf"
fi

# ----------------------------------------------------------- derived --------
[ -z "$QBT_CONF" ] && QBT_CONF="/etc/wireguard/vpnkit-torrent.conf"

# Resolve the unprivileged user for qBittorrent when it was not pinned.
# Preference order: explicit setting, then the invoking sudo user, then the
# owner of the first active graphical session, then uid 1000.
if [ -z "$TARGET_USER" ]; then
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    TARGET_USER="$SUDO_USER"
  else
    # "|| true": with no session at all (early boot) the pipeline fails, and
    # a caller running under `set -e -o pipefail` must not die on that.
    TARGET_USER=$(loginctl list-sessions --no-legend 2>/dev/null \
                  | awk '{print $3}' | grep -v '^root$' | head -1) || true
  fi
  [ -z "$TARGET_USER" ] && TARGET_USER=$(id -nu 1000 2>/dev/null || true)
fi
TARGET_UID=$(id -u "$TARGET_USER" 2>/dev/null || echo 1000)
TARGET_HOME=$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6) || true

# The drop folder: WireGuard configs put here are imported on refresh.
# Configs directly inside become desktop servers; the one inside torrent/
# becomes the torrent tunnel.
[ -z "$CONFIG_DIR" ] && CONFIG_DIR="${TARGET_HOME:-/nonexistent}/Documents/WireGuard"

VPNKIT_VERSION=$(cat /usr/local/lib/vpnkit/VERSION 2>/dev/null || echo unknown)

# Chrome direct (opt-in): the one app that keeps the normal connection while a
# desktop server is selected. Fixed values, not settings: the slice is a unit
# file of that name, the state file is written only by vpnkit-direct, and the
# mark must never equal VPN_FWMARK (WireGuard's own packets) nor change while
# rules for it are loaded.
DIRECT_FWMARK=51821
DIRECT_SLICE="vpnkitdirect.slice"
DIRECT_STATE="/etc/vpnkit/direct-apps"
DIRECT_BIN="/usr/bin/google-chrome-stable"

# ------------------------------------------------------------- helpers ------
# First desktop VPN interface currently present (named <prefix>-...), or empty.
vpnkit_find_vpn_iface() {
  for _i in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1); do
    case "$_i" in "$PROFILE_PREFIX"-*) printf '%s' "$_i"; return 0 ;; esac
  done
  return 1
}

# The body of a URL with whitespace removed; empty when it cannot be reached.
# The answer is only ever held in a variable: nothing downloaded is piped
# anywhere or written to a file that something later runs.
# Every HTTP body this kit reads is an IP address, so what is read is capped:
# a hostile or broken lookup server must not be able to make a helper (some
# run as root) buffer an unbounded response. --max-filesize makes curl refuse
# a larger declared size and, since curl 8.4 (Omarchy ships newer), abort a
# stream that declares none once it passes the limit; the transfer then fails
# and the caller gets nothing. Time is capped as well. No pipe: curl's output
# goes into a variable only.
VPNKIT_MAX_BODY=256
vpnkit_curl() {  # vpnkit_curl <timeout-seconds> <curl args...>: body on stdout, fails if over VPNKIT_MAX_BODY bytes
  curl -4 -s --max-time "$1" --max-filesize "$VPNKIT_MAX_BODY" "${@:2}" 2>/dev/null
}
vpnkit_fetch() {  # vpnkit_fetch <url> [timeout-seconds]: body without whitespace, empty on failure
  _body=$(vpnkit_curl "${2:-5}" "$1") || _body=""
  printf '%s' "$_body" | tr -d '[:space:]'
}

# Does the internet answer? Three tries.
vpnkit_online() {
  for _try in 1 2 3; do
    [ -n "$(vpnkit_fetch "$IP_LOOKUP_URL" 5)" ] && return 0
    sleep 1
  done
  return 1
}

# Read one key from a WireGuard config. Section-aware, and splits only on the
# FIRST '=' so that base64 keys keep their trailing '=' padding intact.
vpnkit_wg_get() {  # vpnkit_wg_get <file> <section> <key>
  awk -v want_sec="$2" -v want_key="$3" '
    /^[[:space:]]*\[/ { sec = tolower($0); gsub(/[^a-z]/, "", sec); next }
    /^[[:space:]]*[#;]/ { next }
    {
      line = $0
      eq = index(line, "=")
      if (eq == 0) next
      key = substr(line, 1, eq - 1)
      val = substr(line, eq + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      gsub(/\r/, "", val)
      if (sec == tolower(want_sec) && tolower(key) == tolower(want_key)) { print val; exit }
    }
  ' "$1"
}

# Server tag from a config's peer comment ("# SE#21" -> se-21,
# "# US-NY#45" -> us-ny-45), or empty.
vpnkit_server_tag() {  # vpnkit_server_tag <file>
  [ -n "${SERVER_TAG_REGEX:-}" ] || return 0
  grep -oE "$SERVER_TAG_REGEX" "$1" 2>/dev/null | head -1 | tr -d ' ' | tr '#' '-' \
    | sed 's/^-*//' | tr 'A-Z' 'a-z'
}

# Torrent apps other than the qBittorrent GUI. Only `qbittorrent` goes through
# the wrapper into the namespace; any of these started from the desktop uses the
# regular connection, so they are looked for and reported.
TORRENT_CLIENTS="qbittorrent-nox transmission-gtk transmission-qt transmission-daemon
transmission-cli deluge deluge-gtk deluged rtorrent ktorrent fragments tixati biglybt
frostwire webtorrent"

vpnkit_qbt_outside_pids() {  # vpnkit_qbt_outside_pids <namespace inode or ""> <user>
  # Prints each qBittorrent (GUI or qbittorrent-nox) of <user> that is NOT
  # inside the torrent namespace. A second qBittorrent of the same user hands
  # its torrents and magnets to the running one over a socket file, and socket
  # files cross network namespaces; the GUI and nox share that socket by
  # default. So while one of these runs, starting another inside the namespace
  # would still download outside it. Only the real binaries count: the wrapper
  # is a script with the same process name. A process that vanished is skipped.
  local ns_inode="$1" pid pns
  for pid in $(pgrep -x 'qbittorrent|qbittorrent-nox' -u "$2" 2>/dev/null); do
    [[ "$(readlink "/proc/$pid/exe" 2>/dev/null)" =~ ^/usr/bin/qbittorrent(-nox)?(\ \(deleted\))?$ ]] || continue
    pns=$(stat -Lc '%i' "/proc/$pid/ns/net" 2>/dev/null) || continue
    [[ -n "$ns_inode" && "$pns" == "$ns_inode" ]] || printf '%s\n' "$pid"
  done
  return 0
}

vpnkit_ns_nsswitch() {  # vpnkit_ns_nsswitch: prints the nsswitch.conf for a private namespace
  # The host's nsswitch uses the `resolve` NSS module, which talks to
  # systemd-resolved over a UNIX SOCKET in /run. Unix sockets are NOT isolated
  # by a network namespace (or a mount namespace), so resolved - running in the
  # root namespace, with the VPN's resolver - would answer the lookups. Without
  # `resolve` and `mdns`, glibc speaks plain DNS to the nameservers in the
  # namespace's own resolv.conf. Used for the torrent namespace (qbt-netns-up)
  # and for Chrome direct (direct-launch).
  cat <<'NSS'
# Namespace-local NSS config. Deliberately excludes the `resolve` (systemd-
# resolved) and `mdns` modules - see vpnkit_ns_nsswitch in common.sh for why.
passwd:     files systemd
group:      files [SUCCESS=merge] systemd
shadow:     files systemd
gshadow:    files systemd
publickey:  files
hosts:      files myhostname dns
networks:   files
protocols:  files
services:   files
ethers:     files
rpc:        files
netgroup:   files
NSS
}

vpnkit_gui_env() {  # vpnkit_gui_env <user> <uid>: sets the array VPNKIT_GUI_ENV
  # The environment a GUI program started by a root launcher (qbt-launch,
  # direct-launch) gets, as NAME=value words for env(1): the user's runtime
  # dir, session bus, HOME, USER, LOGNAME, and the display variables sudo kept
  # for the launcher (see the sudoers file). When WAYLAND_DISPLAY is missing
  # or stale, the first compositor socket in the runtime dir is used; on
  # Hyprland that is wayland-1, not wayland-0.
  local user="$1" rundir="/run/user/$2" wl s v
  wl="${WAYLAND_DISPLAY:-}"
  if [[ -z "$wl" || ! -S "$rundir/$wl" ]]; then
    wl=""
    for s in "$rundir"/wayland-[0-9]*; do
      [[ -S "$s" ]] && { wl=$(basename "$s"); break; }
    done
  fi
  VPNKIT_GUI_ENV=(
    XDG_RUNTIME_DIR="$rundir"
    DBUS_SESSION_BUS_ADDRESS="unix:path=$rundir/bus"
    QT_QPA_PLATFORM="wayland;xcb"
    HOME="$(getent passwd "$user" | cut -d: -f6)"
    USER="$user"
    LOGNAME="$user"
  )
  [[ -n "$wl" ]] && VPNKIT_GUI_ENV+=(WAYLAND_DISPLAY="$wl")
  for v in DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE QT_QPA_PLATFORMTHEME QT_STYLE_OVERRIDE \
           XCURSOR_THEME XCURSOR_SIZE GTK_THEME HYPRLAND_INSTANCE_SIGNATURE; do
    [[ -n "${!v:-}" ]] && VPNKIT_GUI_ENV+=("$v=${!v}")
  done
  return 0
}

vpnkit_resolver_safe() {  # vpnkit_resolver_safe <dir holding resolv.conf + nsswitch.conf>
  # True when a process reading these files can only resolve names through the
  # tunnel: nsswitch.conf exists and its hosts line does not use `resolve` or
  # `mdns` (systemd-resolved answers over a Unix socket, which a network
  # namespace does not isolate), and resolv.conf names at least one nameserver.
  # Called on /etc/netns/<ns> before entering the namespace, and on /etc from
  # inside it, where `ip netns exec` bind-mounts those files - but only the ones
  # that existed when the process entered: a process that entered too early keeps
  # the host's files for its whole life.
  local dir="$1"
  [[ -s "$dir/nsswitch.conf" && -s "$dir/resolv.conf" ]] || return 1
  grep -qE '^[[:space:]]*hosts:' "$dir/nsswitch.conf" || return 1
  ! grep -qE '^[[:space:]]*hosts:.*\b(resolve|mdns[46_a-z]*)\b' "$dir/nsswitch.conf" || return 1
  grep -qE '^[[:space:]]*nameserver[[:space:]]+[^[:space:]]' "$dir/resolv.conf"
}

vpnkit_outside_clients() {  # vpnkit_outside_clients <namespace inode or "">
  # Prints each running torrent app (from TORRENT_CLIENTS) that is NOT inside
  # the torrent namespace, once per name. Needs root to read other users' /proc.
  local ns_inode="$1" c pid pns found
  for c in $TORRENT_CLIENTS; do
    found=0
    # pgrep matches the kernel's process name, which is cut at 15 characters.
    for pid in $(pgrep -x "${c:0:15}" 2>/dev/null); do
      pns=$(stat -Lc '%i' "/proc/$pid/ns/net" 2>/dev/null) || continue
      [[ -n "$ns_inode" && "$pns" == "$ns_inode" ]] || found=1
    done
    (( found )) && printf '%s\n' "$c"
  done
  return 0
}

# Is Chrome direct turned on? Only `vpnkit-direct on` writes the state file.
vpnkit_direct_on() {
  grep -qx chrome "$DIRECT_STATE" 2>/dev/null
}

vpnkit_chrome_outside_pids() {  # vpnkit_chrome_outside_pids <user>
  # Prints each Chrome process of <user> (its binary is under /opt/google/chrome)
  # that is NOT in Chrome direct's slice. A new Chrome hands its window to a
  # running one over a socket in the profile, so while one of these runs, a
  # Chrome started in the slice would open its window there instead. A process
  # that vanished is skipped.
  local pid cg
  for pid in $(pgrep -u "$1" 2>/dev/null); do
    [[ "$(readlink "/proc/$pid/exe" 2>/dev/null)" == /opt/google/chrome/* ]] || continue
    cg=$(cat "/proc/$pid/cgroup" 2>/dev/null) || continue
    [[ -n "$cg" ]] || continue
    [[ "$cg" == *"0::/$DIRECT_SLICE/"* ]] || printf '%s\n' "$pid"
  done
  return 0
}

vpnkit_chrome_flag_refused() {  # vpnkit_chrome_flag_refused <argument>
  # True for a Chrome switch that makes Chrome start another program as its
  # child, which would inherit Chrome direct: --renderer-cmd-prefix,
  # --utility-cmd-prefix, --gpu-launcher, --browser-subprocess-path, and any
  # --*-cmd-prefix or --*-launcher, with or without a value. Chrome also reads
  # switches written with one dash.
  [[ "$1" =~ ^--?([A-Za-z0-9_-]*-cmd-prefix|[A-Za-z0-9_-]*-launcher|browser-subprocess-path)(=|$) ]]
}

vpnkit_loopback_ip() {  # vpnkit_loopback_ip <addr>: a well-formed IPv4 address in 127.0.0.0/8
  # No leading zeros: some parsers read 010 as octal.
  local o='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
  [[ "$1" =~ ^127\.$o\.$o\.$o$ ]]
}

vpnkit_dns_answers() {  # vpnkit_dns_answers <IPv4 address>: true when a DNS server there answers
  # One question (the root zone's name servers) over UDP port 53, sent by bash
  # itself: a stock Omarchy has no DNS query tool. Any reply to it counts, even
  # a refusal: this asks whether a resolver is there, not what it knows.
  local fd reply
  # In braces: a redirection written on exec itself would stay for the caller.
  { exec {fd}<>"/dev/udp/$1/53"; } 2>/dev/null || return 1
  reply=""
  if printf '\x76\x6b\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x01' >&"$fd" 2>/dev/null; then
    reply=$(timeout 3 head -c 3 <&"$fd" 2>/dev/null | od -An -tx1 | tr -d ' \n') || reply=""
  fi
  exec {fd}>&-
  # Same id (766b), and the "this is a response" bit set in the flags.
  [[ "$reply" =~ ^766b[89a-f] ]]
}

vpnkit_direct_rules_loaded() {  # Chrome direct's table and its main-table rule are in place
  nft list table inet vpnkit_direct >/dev/null 2>&1 \
    && [[ -n "$(ip -4 rule list priority 90 fwmark "$DIRECT_FWMARK" table main 2>/dev/null)" ]]
}

_vpnkit_in_root() {  # _vpnkit_in_root <pid> <absolute path>: that file as <pid> sees it
  # Through /proc/<pid>/root, so the process's own mounts count. A symlink's
  # absolute target would be resolved against OUR root (resolv.conf is one),
  # so the last component's links are followed by hand, inside <pid>'s root.
  local root="/proc/$1/root" p="$2" t i
  for i in 1 2 3 4 5 6 7 8; do
    if [[ ! -L "$root$p" ]]; then printf '%s\n' "$root$p"; return 0; fi
    t=$(readlink -- "$root$p") || return 1
    [[ "$t" == /* ]] || t="$(dirname -- "$p")/$t"
    p=$(realpath -m -s -- "$t") || return 1
  done
  return 1
}

_vpnkit_override_ok() {  # _vpnkit_override_ok <pid> <tmp dir>: 0 ok, 1 not, 2 sees no file system
  # A process that DIRECT_DNS applies to sees resolv.conf naming DIRECT_DNS
  # and nothing else, and an nsswitch.conf without resolve/mdns (else glibc
  # asks systemd-resolved, i.e. the VPN's resolver). Chrome's sandboxed
  # children run in an empty root: they cannot open either file, so they
  # have nothing to check. Files are read capped and only if regular.
  local pid="$1" tmp="$2" f n
  [[ -d "/proc/$pid/root/etc" ]] || return 2
  for n in resolv.conf nsswitch.conf; do
    : > "$tmp/$n"
    f=$(_vpnkit_in_root "$pid" "/etc/$n") || return 1
    [[ -f "$f" ]] || return 1
    timeout 2 head -c 16384 -- "$f" > "$tmp/$n" 2>/dev/null || return 1
  done
  vpnkit_resolver_safe "$tmp" || return 1
  [[ "$(awk '$1 == "nameserver" {print $2}' "$tmp/resolv.conf" | sort -u)" == "$DIRECT_DNS" ]]
}

_vpnkit_host_paths() {  # _vpnkit_host_paths <user>: programs named in native-messaging manifests
  # The system's manifests (root's) and the user's own, read with the user's
  # rights: root never opens a file in the user's folder.
  local home uid gid f
  for f in /etc/opt/chrome/native-messaging-hosts/*.json; do
    [[ -f "$f" ]] && head -c 65536 -- "$f" | jq -r 'if type == "object" and (.path | type) == "string" then .path else empty end' 2>/dev/null
  done
  [[ -n "$1" ]] || return 0
  home=$(getent passwd "$1" | cut -d: -f6); uid=$(id -u "$1" 2>/dev/null); gid=$(id -g "$1" 2>/dev/null)
  [[ -n "$home" && -n "$uid" && -n "$gid" ]] || return 0
  setpriv --reuid="$uid" --regid="$gid" --init-groups -- timeout 3 bash -c '
    for f in "$1"/*.json; do
      [[ -f "$f" ]] && head -c 65536 -- "$f" | jq -r "if type == \"object\" and (.path | type) == \"string\" then .path else empty end" 2>/dev/null
    done; true' _ "$home/.config/google-chrome/NativeMessagingHosts" 2>/dev/null | head -c 262144
  return 0
}

_vpnkit_prog_name() {  # _vpnkit_prog_name <path or name>: a printable program name
  local n="${1##*/}"
  n=$(printf '%s' "$n" | tr -cd 'A-Za-z0-9._+-' | head -c 64)
  printf '%s\n' "${n:-unknown}"
}

vpnkit_direct_scan() {  # vpnkit_direct_scan <user>: what runs in Chrome direct's slice (root)
  # One line each:
  #   chrome <pid> ok|bad|-  a Chrome process (its binary is under
  #                          /opt/google/chrome) in the slice, and whether its
  #                          resolver override holds; "-" when DIRECT_DNS is
  #                          empty or the process sees no file system
  #   outside <pid>          a Chrome of <user> outside the slice (on the VPN)
  #   helper <name>          not Chrome, but a program a native-messaging
  #                          manifest names: Chrome started it for an extension
  #   other <name>           anything else in the slice
  # The leak check's own probe (vpnkit-direct-probe-*.service, which only root
  # can start in the system's slice) is left out.
  local cg="/sys/fs/cgroup/$DIRECT_SLICE" pid exe st tmp="" r key hosts="" name
  local -a others=() argv=()
  local -A seen=()
  if [[ -d "$cg" ]]; then
    for pid in $(find "$cg" -path "$cg/vpnkit-direct-probe-*" -prune -o -name cgroup.procs -print0 2>/dev/null \
                 | xargs -0r cat 2>/dev/null); do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      st=$(sed -n 's/^.*) \(.\) .*$/\1/p' "/proc/$pid/stat" 2>/dev/null) || continue
      [[ -n "$st" && "$st" != Z ]] || continue        # gone, or a zombie: sends nothing
      exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || exe=""
      exe="${exe% (deleted)}"
      if [[ "$exe" != /opt/google/chrome/* ]]; then others+=("$pid"); continue; fi
      r="-"
      if [[ -n "$DIRECT_DNS" ]]; then
        # Processes that share a mount namespace and a root see the same files.
        key="$(stat -Lc %i "/proc/$pid/ns/mnt" 2>/dev/null):$(stat -Lc %d:%i "/proc/$pid/root" 2>/dev/null)"
        if [[ -n "${seen[$key]:-}" ]]; then r="${seen[$key]}"
        else
          [[ -n "$tmp" ]] || tmp=$(mktemp -d) || return 1
          _vpnkit_override_ok "$pid" "$tmp"
          case $? in 0) r=ok ;; 2) r="-" ;; *) r=bad ;; esac
          seen[$key]="$r"
        fi
      fi
      printf 'chrome %s %s\n' "$pid" "$r"
    done
  fi
  [[ -n "$tmp" ]] && rm -rf "$tmp"
  if [[ -n "$1" ]]; then
    for pid in $(vpnkit_chrome_outside_pids "$1"); do printf 'outside %s\n' "$pid"; done
  fi
  (( ${#others[@]} )) || return 0
  hosts=$(_vpnkit_host_paths "$1")
  for pid in "${others[@]}"; do
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || exe=""
    exe="${exe% (deleted)}"
    argv=(); { mapfile -d '' -n 3 -t argv < "/proc/$pid/cmdline"; } 2>/dev/null || true
    name=""
    # The program itself, or a script its interpreter runs (argv[1] or [2]).
    for r in "$exe" "${argv[1]:-}" "${argv[2]:-}"; do
      [[ -n "$r" && "$r" == /* ]] && grep -qxF -- "$r" <<<"$hosts" && { name="$r"; break; }
    done
    if [[ -n "$name" ]]; then printf 'helper %s\n' "$(_vpnkit_prog_name "$name")"
    elif [[ -n "$exe" ]]; then printf 'other %s\n' "$(_vpnkit_prog_name "$exe")"
    else printf 'other %s\n' "$(_vpnkit_prog_name "$(cat "/proc/$pid/comm" 2>/dev/null)")"
    fi
  done
  return 0
}

# Where vpn-check saves the leak-check reports of the user running it: a
# folder in Documents ("VPN leak checks"), easy to find in the file manager.
# REPORT_DIR in vpnkit.conf overrides it.
vpnkit_report_dir() {
  if [ -n "${REPORT_DIR:-}" ]; then printf '%s\n' "$REPORT_DIR"; return 0; fi
  _vpnkit_docs=$(xdg-user-dir DOCUMENTS 2>/dev/null) || _vpnkit_docs=""
  # xdg-user-dir answers $HOME when no Documents folder is configured.
  if [ -z "$_vpnkit_docs" ] || [ "$_vpnkit_docs" = "$HOME" ]; then _vpnkit_docs="$HOME/Documents"; fi
  printf '%s/VPN leak checks\n' "$_vpnkit_docs"
}
