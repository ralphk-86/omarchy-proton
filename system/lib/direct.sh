# ============================================================================
#  direct.sh - Chrome direct's settings and helpers.
#
#  Installed to /usr/local/lib/vpnkit/direct.sh. Sourced AFTER common.sh (it
#  uses TARGET_USER, DIRECT_DNS, vpnkit_resolver_safe) by the scripts that deal
#  with Chrome direct, as root or as you. Side-effect free, like common.sh.
# ============================================================================

# Chrome direct (opt-in): the one app that keeps the normal connection while a
# desktop server is selected. Fixed values, not settings: the slice is a unit
# file of that name, the state file is written only by vpnkit-direct, and the
# mark must never equal VPN_FWMARK (WireGuard's own packets) nor change while
# rules for it are loaded.
DIRECT_FWMARK=51821
DIRECT_SLICE="vpnkitdirect.slice"
DIRECT_STATE="/etc/vpnkit/direct-apps"
DIRECT_BIN="/usr/bin/google-chrome-stable"
# Comes first in Chrome's PATH: Chrome's own xdg-open, which starts the app
# outside the slice (see direct-bin/xdg-open).
DIRECT_PATH_DIR="/usr/local/lib/vpnkit/direct-bin"
# Chrome's session bus is a filtered proxy of the user's (see direct-launch).
DIRECT_PROXY="/usr/bin/xdg-dbus-proxy"

# Is Chrome direct turned on? Only `vpnkit-direct on` writes the state file.
vpnkit_direct_on() {
  grep -qx chrome "$DIRECT_STATE" 2>/dev/null
}

vpnkit_chrome_outside_pids() {  # vpnkit_chrome_outside_pids <user>
  # Prints each Chrome process of <user> (its binary is under /opt/google/chrome)
  # that is NOT in Chrome direct's slice. A new Chrome hands its window to a
  # running one over a socket in the profile, so while one of these runs, a
  # Chrome started in the slice would open its window there instead. A process
  # that vanished is skipped. (vpnkit_app_pids is in common.sh.)
  vpnkit_app_pids "$1" '^/opt/google/chrome/' outside "slice:$DIRECT_SLICE"
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

vpnkit_direct_rules_loaded() {  # Chrome direct's table and both its policy rules are in place
  nft list table inet vpnkit_direct >/dev/null 2>&1 \
    && [[ -n "$(ip -4 rule list priority 90 fwmark "$DIRECT_FWMARK" table main 2>/dev/null)" ]] \
    && [[ -n "$(ip -4 rule list priority 89 fwmark "$DIRECT_FWMARK" to 100.64.0.0/10 table 52 2>/dev/null)" ]]
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

_vpnkit_chrome_wrapper() {  # _vpnkit_chrome_wrapper <pid> <exe>: one of Chrome's own start-up processes
  # Chrome's start script (/opt/google/chrome/google-chrome, run by bash)
  # sends Chrome's output through two `cat`s (exec > >(exec cat)) that live as
  # long as Chrome: /usr/bin/cat, run as plain "cat", whose parent is a Chrome
  # binary. While Chrome starts, bash runs that script, and the package's
  # /usr/bin/google-chrome-stable (DIRECT_BIN) before it: an interpreter whose
  # script (argv[1] or argv[2]) is one of those.
  local pid="$1" exe="$2" ppid pexe a
  local -a argv=()
  { mapfile -d '' -n 3 -t argv < "/proc/$pid/cmdline"; } 2>/dev/null || return 1
  case "$exe" in
    /usr/bin/cat)
      [[ ${#argv[@]} -eq 1 && "${argv[0]}" == cat ]] || return 1
      ppid=$(sed -n 's/^.*) . \([0-9]*\) .*$/\1/p' "/proc/$pid/stat" 2>/dev/null) || return 1
      [[ "$ppid" =~ ^[0-9]+$ ]] || return 1
      pexe=$(readlink "/proc/$ppid/exe" 2>/dev/null) || return 1
      [[ "${pexe% (deleted)}" == /opt/google/chrome/* ]]
      ;;
    /usr/bin/bash|/usr/bin/dash)
      for a in "${argv[1]:-}" "${argv[2]:-}"; do
        [[ "$a" == "$DIRECT_BIN" || ( "$a" == /opt/google/chrome/* && "$a" != *..* ) ]] && return 0
      done
      return 1
      ;;
    *) return 1 ;;
  esac
}

_vpnkit_prog_name() {  # _vpnkit_prog_name <path or name>: a printable program name
  local n="${1##*/}"
  n=$(printf '%s' "$n" | tr -cd 'A-Za-z0-9._+-' | head -c 64)
  printf '%s\n' "${n:-unknown}"
}

vpnkit_direct_scan() {  # vpnkit_direct_scan <user>: what runs in Chrome direct's slice (root), ending in "done"
  # One line each:
  #   chrome <pid> ok|bad|-  a Chrome process (its binary is under
  #                          /opt/google/chrome, or it is one of Chrome's own
  #                          start-up processes: _vpnkit_chrome_wrapper) in
  #                          the slice, and whether its
  #                          resolver override holds; "-" when DIRECT_DNS is
  #                          empty or the process sees no file system
  #   outside <pid>          a Chrome of <user> outside the slice (on the VPN)
  #   helper <name>          not Chrome, but a program a native-messaging
  #                          manifest names: Chrome started it for an extension
  #   other <name>           anything else in the slice
  # The leak check's own probe (vpnkit-direct-probe-*.service, which only root
  # can start in the system's slice) is left out.
  # All or nothing: the lines come out only once the whole scan has run, and
  # the last one is "done". A caller that does not see "done" knows nothing.
  local cg="/sys/fs/cgroup/$DIRECT_SLICE" pid exe st tmp="" r key hosts="" name out=""
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
      if [[ "$exe" != /opt/google/chrome/* ]] && ! _vpnkit_chrome_wrapper "$pid" "$exe"; then
        others+=("$pid"); continue
      fi
      r="-"
      if [[ -n "$DIRECT_DNS" ]]; then
        # Processes that share a mount namespace and a root see the same files.
        key="$(stat -Lc %i "/proc/$pid/ns/mnt" 2>/dev/null):$(stat -Lc %d:%i "/proc/$pid/root" 2>/dev/null)"
        if [[ -n "${seen[$key]:-}" ]]; then r="${seen[$key]}"
        else
          [[ -n "$tmp" ]] || tmp=$(mktemp -d 2>/dev/null) || return 1
          _vpnkit_override_ok "$pid" "$tmp"
          case $? in 0) r=ok ;; 2) r="-" ;; *) r=bad ;; esac
          seen[$key]="$r"
        fi
      fi
      out+="chrome $pid $r"$'\n'
    done
  fi
  [[ -n "$tmp" ]] && rm -rf "$tmp"
  if [[ -n "$1" ]]; then
    for pid in $(vpnkit_chrome_outside_pids "$1"); do out+="outside $pid"$'\n'; done
  fi
  if (( ${#others[@]} == 0 )); then printf '%sdone\n' "$out"; return 0; fi
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
    if [[ -n "$name" ]]; then out+="helper $(_vpnkit_prog_name "$name")"$'\n'
    elif [[ -n "$exe" ]]; then out+="other $(_vpnkit_prog_name "$exe")"$'\n'
    else out+="other $(_vpnkit_prog_name "$(cat "/proc/$pid/comm" 2>/dev/null)")"$'\n'
    fi
  done
  printf '%sdone\n' "$out"
}
