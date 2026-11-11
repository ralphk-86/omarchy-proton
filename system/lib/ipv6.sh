# ============================================================================
#  ipv6.sh - save and restore the IPv6 settings of NetworkManager profiles.
#
#  Installed to /usr/local/lib/vpnkit/ipv6.sh. Used by install-root.sh (to
#  switch IPv6 off in the wired and Wi-Fi profiles, and by its rollback) and by
#  uninstall-root.sh --restore-ipv6. One implementation for both, so what the
#  install clears is exactly what they put back. Runs as root; needs nmcli and
#  base64. Defines functions only.
#
#  NetworkManager refuses ipv6.method=disabled while a profile still carries
#  static IPv6 settings, so switching IPv6 off clears these fields in the same
#  call. Every one of them is saved first, in $V6_SAVED, one line per profile:
#
#    v2 <TAB> uuid <TAB> name <TAB> method <TAB> dns <TAB> dns-search
#       <TAB> addresses <TAB> gateway <TAB> routes
#
#  Everything after the uuid is base64, of the value exactly as
#  `nmcli -e no -g ipv6.<field>` prints it, which `nmcli connection modify`
#  takes back unchanged (several addresses, routes with next hop, metric and
#  attributes, colons). Base64 keeps tabs, commas and colons from breaking the
#  file. Lines from before 0.4.1 have four plain fields, matched by name:
#
#    name <TAB> method <TAB> dns <TAB> dns-search
#
#  Those versions cleared addresses, gateway and routes without saving them;
#  they are gone, and a restore of such a profile says so.
# ============================================================================

V6_SAVED=/etc/vpnkit/ipv6-profiles.saved
# Saved lines the kit will not apply any more, dated: replaced by a later
# install, or not restored because the profile was turned back on or deleted
# since. Kept for reference (nothing saved is thrown away), never applied.
V6_SUPERSEDED=/etc/vpnkit/ipv6-profiles.superseded
# In this order in a v2 line, after version, uuid and name.
V6_FIELDS=(method dns dns-search addresses gateway routes)

v6_say()  { printf '    %s\n' "$*"; }
v6_warn() { printf '[!] %s\n' "$*"; }

# v6_get <uuid> <property>: a profile property, unescaped (nmcli -e no).
v6_get() { nmcli -e no -g "$2" connection show uuid "$1" 2>/dev/null; }

# v6_current <uuid>: the profile's v2 line as it is now. Fails (and prints
# nothing) when any field cannot be read: never save half a profile.
v6_current() {
  local uuid="$1" name f val line
  name=$(v6_get "$uuid" connection.id) || return 1
  [[ -n "$name" ]] || return 1
  line="v2"$'\t'"$uuid"$'\t'"$(printf '%s' "$name" | base64 -w0)"
  for f in "${V6_FIELDS[@]}"; do
    val=$(v6_get "$uuid" "ipv6.$f") || return 1
    line+=$'\t'"$(printf '%s' "$val" | base64 -w0)"
  done
  printf '%s\n' "$line"
}

# v6_entry <uuid> <name>: the saved line for a profile: the v2 line with its
# uuid, else a line from before 0.4.1 with its name; nothing when none.
v6_entry() {
  [[ -f "$V6_SAVED" ]] || return 0
  # ENVIRON, not -v: awk would interpret backslashes in a profile name.
  U="$1" N="$2" awk -F'\t' '
    $1 == "v2" && NF == 9 && $2 == ENVIRON["U"] { print; found = 1; exit }
    NF == 4 && $1 == ENVIRON["N"] && old == ""  { old = $0 }
    END { if (!found && old != "") print old }' "$V6_SAVED"
}

# v6_replace <uuid> <old-line> <new-line>: rewrite the file without the
# profile's v2 line and without <old-line>, then add <new-line> (if any).
# Atomic: written next to the file, then renamed over it.
v6_replace() {
  local tmp
  tmp=$(mktemp "$V6_SAVED.XXXXXX") || return 1
  if [[ -f "$V6_SAVED" ]]; then
    U="$1" OLD="$2" awk -F'\t' '!($1 == "v2" && $2 == ENVIRON["U"]) && $0 != ENVIRON["OLD"]' \
      "$V6_SAVED" > "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  [[ -z "$3" ]] || printf '%s\n' "$3" >> "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 644 "$tmp" && mv -f "$tmp" "$V6_SAVED"
}

# v6_disable_profile <uuid>: save the profile's IPv6 settings, then set
# ipv6.method=disabled and clear what NetworkManager would refuse it with.
# Returns 1, with the profile and the saved file as they were, when either
# step fails. A profile already saved by an earlier install whose settings
# have changed since gets the current ones saved; the earlier entry goes to
# $V6_SUPERSEDED, so nothing that was saved is lost.
v6_disable_profile() {
  local uuid="$1" name line prev
  line=$(v6_current "$uuid") || return 1
  name=$(v6_get "$uuid" connection.id)
  prev=$(v6_entry "$uuid" "$name")
  # A line from before 0.4.1 names its profile, and the name may belong to
  # more than one profile. It is taken over only when no other profile of
  # that name is switched off (it may be that one's): else it stays for the
  # restore.
  if [[ -n "$prev" && "$(cut -f1 <<< "$prev")" != "v2" ]] && v6_name_off_elsewhere "$uuid" "$name"; then
    prev=""
  fi
  v6_replace "$uuid" "$prev" "$line" || return 1
  if ! nmcli connection modify uuid "$uuid" ipv6.method disabled ipv6.dns "" ipv6.dns-search "" \
         ipv6.addresses "" ipv6.gateway "" ipv6.routes ""; then
    v6_replace "$uuid" "$line" "$prev"
    return 1
  fi
  if [[ -n "$prev" && "$prev" != "$line" ]]; then
    v6_supersede "$prev"
    v6_say "\"$name\": replaced the IPv6 settings saved by an earlier install (the profile was changed since); the earlier ones are kept in $V6_SUPERSEDED"
  fi
  [[ "$(v6_field "$line" method)" == "manual" ]] \
    && v6_say "\"$name\" had static IPv6 (ipv6.method manual): saved, uninstall.sh --restore-ipv6 puts it back"
  return 0
}

# v6_supersede <saved line>: keep a line the kit will not apply any more, dated.
v6_supersede() {
  printf '%s\t%s\n' "$(date +%Y-%m-%d)" "$1" >> "$V6_SUPERSEDED" && chmod 644 "$V6_SUPERSEDED"
}

# v6_line_name <saved line>: the profile name a saved line is for.
v6_line_name() {
  if [[ "$(cut -f1 <<< "$1")" == "v2" ]]; then cut -f3 <<< "$1" | base64 -d 2>/dev/null
  else cut -f1 <<< "$1"; fi
}

# v6_profiles: "uuid:type:name" of every profile (-e no: the name is
# everything after the second colon, and may contain colons itself).
v6_profiles() { nmcli -e no -g UUID,TYPE,NAME connection show 2>/dev/null; }

# v6_name_off_elsewhere <uuid> <name>: another wired or Wi-Fi profile called
# <name> has IPv6 switched off. True as well when that cannot be found out.
v6_name_off_elsewhere() {
  local all u t n
  all=$(v6_profiles) || return 0
  while IFS= read -r u; do
    t=${u#*:}; n=${t#*:}; t=${t%%:*}; u=${u%%:*}
    [[ "$u" != "$1" && "$n" == "$2" ]] || continue
    case "$t" in 802-3-ethernet|802-11-wireless) ;; *) continue ;; esac
    [[ "$(v6_get "$u" ipv6.method)" == "disabled" ]] && return 0
  done <<< "$all"
  return 1
}

# v6_field <v2-line> <field>: one decoded field of a v2 line.
v6_field() {
  local i
  for i in "${!V6_FIELDS[@]}"; do
    if [[ "${V6_FIELDS[$i]}" == "$2" ]]; then
      printf '%s' "$1" | awk -F'\t' -v c=$((i + 4)) '{ print $c }' | base64 -d 2>/dev/null
      return 0
    fi
  done
  return 1
}

# v6_reapply <uuid>: apply the profile's stored settings to the device it is
# active on, if any, without taking the link down. Needed both ways: the
# running link keeps the IPv6 settings it was activated with.
v6_reapply() {
  local dev
  dev=$(nmcli -g GENERAL.DEVICES connection show uuid "$1" 2>/dev/null | head -1) || dev=""
  [[ -n "$dev" ]] || return 0
  # Never fatal: the stored profile is already right, and the link picks it
  # up when it reconnects. (NetworkManager refuses a reapply while the
  # profile has other changes not yet applied, or when the link just went.)
  nmcli device reapply "$dev" >/dev/null 2>&1 \
    || v6_warn "IPv6: could not apply the change to the running link $dev; it applies when the link reconnects (or: nmcli device reapply $dev)"
  return 0
}

# v6_restore_profile <uuid>: put back what was saved for the profile, all
# fields in one call, apply it to the running link, then forget the entry.
# A profile with nothing saved is left alone: the install did not change it.
# So is one whose IPv6 was turned back on since: its settings are the user's
# now; the saved line goes to $V6_SUPERSEDED. Returns 1 when the profile
# could not be restored: it is named, IPv6 stays off on it, and its entry
# stays saved.
v6_restore_profile() {
  local uuid="$1" name entry method dns search addrs gw routes legacy=0 cur
  name=$(v6_get "$uuid" connection.id) || name=""
  [[ -n "$name" ]] || { v6_warn "IPv6: cannot read the profile $uuid"; return 1; }
  entry=$(v6_entry "$uuid" "$name")
  [[ -n "$entry" ]] || return 0
  cur=$(v6_get "$uuid" ipv6.method) || { v6_warn "IPv6: cannot read the profile \"$name\"; its saved settings stay in $V6_SAVED"; return 1; }
  if [[ "$cur" != "disabled" ]]; then
    v6_supersede "$entry" && v6_replace "$uuid" "$entry" "" || return 1
    v6_say "IPv6: \"$name\" was turned back on since setup (ipv6.method $cur) and is left as it is; the settings saved before setup are kept in $V6_SUPERSEDED"
    return 0
  fi
  if [[ "$(cut -f1 <<< "$entry")" == "v2" ]]; then
    method=$(v6_field "$entry" method);   dns=$(v6_field "$entry" dns)
    search=$(v6_field "$entry" dns-search); addrs=$(v6_field "$entry" addresses)
    gw=$(v6_field "$entry" gateway);      routes=$(v6_field "$entry" routes)
  else
    legacy=1
    method=$(cut -f2 <<< "$entry"); dns=$(cut -f3 <<< "$entry"); search=$(cut -f4 <<< "$entry")
    addrs=""; gw=""; routes=""
  fi
  # Only an entry whose method could not be read (an empty field) gets auto.
  [[ -n "$method" && "$method" != "disabled" ]] || method="auto"
  if nmcli connection modify uuid "$uuid" ipv6.method "$method" ipv6.addresses "$addrs" \
       ipv6.gateway "$gw" ipv6.routes "$routes" ipv6.dns "$dns" ipv6.dns-search "$search"; then
    v6_replace "$uuid" "$entry" "" || v6_warn "IPv6: \"$name\" is restored, but its entry could not be removed from $V6_SAVED"
    v6_reapply "$uuid"
    return 0
  fi
  v6_warn "IPv6: could not restore \"$name\" (ipv6.method $method). IPv6 stays off on that profile;"
  v6_warn "its saved settings stay in $V6_SAVED."
  if (( legacy )) && [[ "$method" == "manual" ]]; then
    v6_warn "Its static IPv6 addresses, gateway and routes were cleared by a version before 0.4.1,"
    v6_warn "which did not save them; they cannot be restored. Set them again, for example:"
    v6_warn "  nmcli connection modify \"$name\" ipv6.method manual ipv6.addresses <address/prefix> ipv6.gateway <gateway>"
  fi
  return 1
}

# v6_restore_saved: restore every profile listed in $V6_SAVED, and no other.
# A line whose profile no longer exists (NetworkManager says so: exit 10) is
# moved to $V6_SUPERSEDED: there is nothing left to put it back into. Any other
# failure to look a profile up keeps its line. Returns 1 when any profile
# could not be restored, and at once, changing nothing, when NetworkManager
# is not running.
v6_restore_saved() {
  local -a lines uuids
  local line uuid rc=0 r u t n all name
  [[ -s "$V6_SAVED" ]] || return 0
  if [[ "$(nmcli -t -f RUNNING general status 2>/dev/null)" != "running" ]]; then
    v6_warn "IPv6: NetworkManager is not running, so no profile was restored; the saved settings stay in $V6_SAVED."
    return 1
  fi
  mapfile -t lines < "$V6_SAVED"
  for line in "${lines[@]}"; do
    [[ -n "$line" ]] || continue
    uuids=()
    name=$(v6_line_name "$line")
    if [[ "$(cut -f1 <<< "$line")" == "v2" ]]; then
      uuid=$(cut -f2 <<< "$line")
      nmcli -g connection.uuid connection show uuid "$uuid" >/dev/null 2>&1; r=$?
      case "$r" in
        0)  uuids=("$uuid") ;;
        10) ;;
        *)  v6_warn "IPv6: could not look up the profile \"$name\" (nmcli exit $r); its saved settings stay in $V6_SAVED."
            rc=1; continue ;;
      esac
    else
      # A line from before 0.4.1 names the profile: every wired or Wi-Fi
      # profile of that name that has no line of its own.
      if ! all=$(v6_profiles); then
        v6_warn "IPv6: could not list the profiles to find \"$name\"; its saved settings stay in $V6_SAVED."
        rc=1; continue
      fi
      while IFS= read -r u; do
        t=${u#*:}; n=${t#*:}; t=${t%%:*}; u=${u%%:*}
        [[ "$n" == "$name" ]] || continue
        case "$t" in 802-3-ethernet|802-11-wireless) ;; *) continue ;; esac
        U="$u" awk -F'\t' '$1 == "v2" && $2 == ENVIRON["U"] { f = 1 } END { exit !f }' "$V6_SAVED" && continue
        uuids+=("$u")
      done <<< "$all"
    fi
    if (( ${#uuids[@]} == 0 )); then
      v6_say "IPv6: the profile \"$name\" no longer exists; its saved settings are moved to $V6_SUPERSEDED"
      v6_supersede "$line" && v6_replace "" "$line" "" || rc=1
      continue
    fi
    for uuid in "${uuids[@]}"; do
      v6_restore_profile "$uuid" || rc=1
    done
  done
  return "$rc"
}
