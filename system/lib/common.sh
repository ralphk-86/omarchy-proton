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
KILLSWITCH_ALLOW_LAN=1
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
vpnkit_fetch() {  # vpnkit_fetch <url> [timeout-seconds]
  _body=$(curl -4 -s --max-time "${2:-5}" "$1" 2>/dev/null) || _body=""
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
