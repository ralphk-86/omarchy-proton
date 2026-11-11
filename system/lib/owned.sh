# ============================================================================
#  owned.sh - which files are this kit's, so that nothing else is replaced or
#  deleted.
#
#  Installed to /usr/local/lib/vpnkit/owned.sh. Defines functions only.
#
#  Commands in /usr/local/bin (install-root.sh, uninstall-root.sh; as root):
#  every file of system/bin carries VPNKIT_BIN_MARK on its second line (those
#  of 0.3.0 to 0.4.0, which had none, are known by checksum). Any other file
#  there is not the kit's: setup replaces it only when asked
#  (--move-aside), keeping it in VPNKIT_ASIDE, and the uninstaller deletes only
#  marked files and puts the kept ones back.
#
#  Launcher entries in ~/.local/share/applications (install.sh, uninstall.sh,
#  vpn-direct, and uninstall-root.sh through runuser; ALWAYS as the desktop
#  user, never as root): the kit's own entries start with a marker line. One
#  of yours is replaced only when asked, backed up first as <file>.bak.<time>,
#  and put back when the kit's entry is removed.
# ============================================================================

VPNKIT_BIN_MARK="# omarchy-proton: installed by its setup, removed by its uninstaller (vpnkit)."
VPNKIT_ASIDE=/usr/local/lib/vpnkit/moved-aside

# Every version of the commands from 0.3.0 to 0.4.0 (they had no marker line),
# by checksum and name: the file next to this one.
VPNKIT_BIN_RELEASED="$(dirname -- "${BASH_SOURCE[0]}")/released-bin.sha256"

# vpnkit_owned_bin <path>: a regular file (not a link) the kit installed: it
# carries the marker, or it is byte for byte a command of an earlier release
# under its own name. Anything else there is someone else's.
vpnkit_owned_bin() {
  local sum
  [[ -f "$1" && ! -L "$1" ]] || return 1
  [[ "$(head -c 4096 -- "$1" 2>/dev/null | sed -n 2p)" == "$VPNKIT_BIN_MARK" ]] && return 0
  sum=$(sha256sum < "$1" 2>/dev/null | cut -d' ' -f1) || return 1
  grep -qxF "$sum  $(basename -- "$1")" "$VPNKIT_BIN_RELEASED" 2>/dev/null
}

# --------------------------------------------------------------- launchers --
VPNKIT_QBT_DESK_MARK="# Written by omarchy-proton (torrent tunnel). Removed by its uninstaller."
# The qBittorrent entry 0.3.0 to 0.4.0 wrote, which had no marker line.
VPNKIT_QBT_DESK_LEGACY_SHA="8b1b0ceac177ddf4843b976eab80730e1ea147135c673414526335425585ce3c"
VPNKIT_CHROME_DESK_MARK="# Written by omarchy-proton (Chrome direct). Removed when it is turned off."

vpnkit_qbt_desk()    { printf '%s/.local/share/applications/org.qbittorrent.qBittorrent.desktop\n' "$1"; }
vpnkit_chrome_desk() { printf '%s/.local/share/applications/google-chrome.desktop\n' "$1"; }

# vpnkit_desk_ours <file> <marker> [legacy sha256]: the kit wrote this entry.
vpnkit_desk_ours() {
  [[ -f "$1" && ! -L "$1" ]] || return 1
  [[ "$(head -n 1 -- "$1" 2>/dev/null)" == "$2" ]] && return 0
  [[ -n "${3:-}" && "$(head -c 65536 -- "$1" 2>/dev/null | sha256sum | cut -d' ' -f1)" == "$3" ]]
}

# vpnkit_desk_exec <file>: the program the entry's first Exec= starts.
vpnkit_desk_exec() {
  head -c 65536 -- "$1" 2>/dev/null | sed -nE 's/^Exec=[[:space:]]*([^[:space:]]+).*/\1/p' | head -1
}

# vpnkit_desk_backup <file>: copy an entry of the user's aside; prints the copy.
vpnkit_desk_backup() {
  local bak
  bak="$1.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a -- "$1" "$bak" || return 1
  printf '%s\n' "$bak"
}

# vpnkit_desk_restore <file> <marker> [legacy sha256] [kit wrapper]: move the
# newest backup of the user's own entry back into place. Backups the kit wrote
# itself are skipped, and so is one that starts [kit wrapper] (it would point
# at a command the uninstaller removes); those stay where they are.
vpnkit_desk_restore() {
  local f="$1" b
  [[ -e "$f" || -L "$f" ]] && return 0      # something is there already: leave it
  while IFS= read -r b; do
    [[ -n "$b" ]] || continue
    vpnkit_desk_ours "$b" "$2" "${3:-}" && continue
    [[ -n "${4:-}" && -f "$b" && "$(vpnkit_desk_exec "$b")" == "$4" ]] && continue
    mv -- "$b" "$f" || return 1
    echo "    put your own $(basename -- "$f") back (it was kept as $(basename -- "$b"))"
    return 0
  done < <(compgen -G "$f.bak.*" | sort -r)
  return 0
}

vpnkit_desk_refresh() {
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$1" >/dev/null 2>&1
  return 0
}

# vpnkit_desk_remove <file> <marker> [legacy sha256] [kit wrapper]: remove the
# kit's entry (only the kit's) and put the user's own back, if one was kept.
vpnkit_desk_remove() {
  if vpnkit_desk_ours "$1" "$2" "${3:-}"; then
    rm -f -- "$1" || return 1
  fi
  vpnkit_desk_restore "$@" || return 1
  vpnkit_desk_refresh "$(dirname -- "$1")"
}

# vpnkit_launchers_remove <home>: both of the kit's entries, as the uninstaller
# does it. Run as the owner of <home>.
vpnkit_launchers_remove() {
  local rc=0
  vpnkit_desk_remove "$(vpnkit_qbt_desk "$1")" "$VPNKIT_QBT_DESK_MARK" "$VPNKIT_QBT_DESK_LEGACY_SHA" \
    /usr/local/bin/qbittorrent || rc=1
  vpnkit_desk_remove "$(vpnkit_chrome_desk "$1")" "$VPNKIT_CHROME_DESK_MARK" || rc=1
  return "$rc"
}
