# Firefox Tunnel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An opt-in, always-on WireGuard namespace for Firefox, built like the torrent tunnel, with its own server and exit, that Firefox cannot leave.

**Architecture:** The torrent tunnel's namespace builder moves into a shared library function that both tunnels call with their own names. Firefox gets the same pieces qBittorrent has (boot unit, PATH wrapper, root launcher, launcher override, status, leak check), all inert until a Firefox config is imported. `vpnkit-sync` owns selection and every "one key / one exit" guard.

**Tech Stack:** bash, iproute2 (`ip netns`), wireguard-tools, nftables, systemd, NetworkManager, jq, QML (widget only).

**Spec:** `docs/superpowers/specs/2026-11-09-firefox-tunnel-design.md`

## Global Constraints

- Repository is public: no real names, domains, IPs, hostnames or home paths in files or commits; commits use the noreply address; `tests/check.sh` must pass before every commit.
- Fail closed: unknown state is shown as unknown or blocks; never a guess, never a stale address.
- Nothing downloaded is executed; packages only via `pacman` from official repos.
- Root helpers take no paths and validate every argument. Each new passwordless sudo rule: a row in `SECURITY.md` and a suite test that it cannot be abused.
- User configuration is not overwritten without a flag; what is replaced is backed up.
- Network changes are tested only in the VM (`tests/vm/vm.sh test`), never on the developer's machine. The root half of the installer is never run from an agent session.
- The torrent tunnel's behaviour, file names, unit name and `vpnkit.conf` keys do not change. VM section 3 must pass with only the one edit named in Task 1.
- Opt-in: installing or updating changes nothing for Firefox until a config is imported from `firefox/`. Turning it off is supported without uninstalling.
- Separate exit: a Firefox config with the same endpoint (host:port) as the torrent tunnel's is refused, and vice versa; a server is never in two of {regular, torrent, Firefox} at once.
- Release: `VERSION`, `manifest.json`, `kitVersion` in `VpnWidget.qml` and `CHANGELOG.md` all say `0.4.0`.

## Review Focus

1. **Existing plugin user with Firefox who never opts in, after updating:** `firefox` in a terminal, the launcher and links open Firefox exactly as before, on the normal connection. Test in Task 4 (`firefox off: the wrapper execs the real binary`) and Task 5 (`no override while off`).
2. **Firefox already open outside the namespace when the user opts in:** the import still succeeds, but every later launch is refused with a message naming the PID, the bar/panel shows Firefox as unprotected, and the leak check fails. Tests in Task 4 and Task 6.
3. **A link opened from another app while Firefox is the default browser:** it goes through the desktop override into the namespace and lands in the running (inside) Firefox. Test in Task 5 (`the override's Exec is the wrapper`, `actions keep their arguments`).
4. **The Firefox server chosen for regular traffic or torrents, or the torrent server chosen for Firefox:** refused with a message, nothing changes. Tests in Task 3.
5. **Boot with no network yet:** `ff-netns.service` fails and retries until the endpoint resolves; Firefox is refused meanwhile. Test in Task 2 (`unit retries`), Task 4 (`no namespace: refused`).

---

### Task 1: Shared namespace builder (torrent behaviour unchanged)

**Files:**
- Create: `system/lib/netns.sh`
- Modify: `system/bin/qbt-netns-up` (becomes a thin caller), `system/install-root.sh` (install `netns.sh` next to `common.sh`), `system/uninstall-root.sh` (nothing new: `/usr/local/lib/vpnkit` is already removed whole)
- Test: `tests/vm/suite.sh` section 3, `tests/check.sh` section 2 (add `system/lib/netns.sh` to the parsed files if the glob misses it)

**Interfaces:**
- Produces: `vpnkit_netns_up <ns> <wg_if> <conf> <guard_table>` in `/usr/local/lib/vpnkit/netns.sh`. It does everything `qbt-netns-up` does today, in the same order: parse `conf`, tear down `<ns>`/`<wg_if>`, write `/etc/netns/<ns>/{resolv.conf,nsswitch.conf}` atomically and check them with `vpnkit_resolver_safe` before any route, create the namespace, IPv6 off when `DISABLE_IPV6=1`, load nftables table `inet <guard_table>` (egress only `lo` and `<wg_if>`), create the WireGuard link in the root namespace with `VPN_FWMARK`, move it in, addresses, `route add default`. Exit non-zero with the same log lines on every failure. `vpnkit_netns_down <ns> <wg_if>` deletes both.
- `qbt-netns-up` becomes: source `common.sh` and `netns.sh`, then `vpnkit_netns_up "$NS" "$WG_IF" "$QBT_CONF" qbtguard`. `qbt-netns-down` calls `vpnkit_netns_down "$NS" "$WG_IF"`.

- [ ] **Step 1: Point the ordering test at the library.** In section 3 change the `awk` check `"qbt-netns-up writes the resolver files before the default route"` to read `/usr/local/lib/vpnkit/netns.sh`. Run `tests/vm/vm.sh test`; expected: that one check FAILS (the file does not exist yet), the rest of section 3 passes.
- [ ] **Step 2: Move the body of `qbt-netns-up` into `vpnkit_netns_up` in `system/lib/netns.sh`** with the four parameters replacing `NS`, `WG_IF`, `CONF` and the literal `qbtguard`. The heredoc comments move with the code. Install it in `install-root.sh` with mode 644 right after `common.sh`.
- [ ] **Step 3: Run `tests/check.sh` and `tests/vm/vm.sh test`.** Expected: all checks pass, section 3 output identical to before apart from the renamed check.
- [ ] **Step 4: Commit** `refactor: torrent namespace builder becomes vpnkit_netns_up`.

### Task 2: Firefox settings, tunnel builder and boot unit

**Files:**
- Modify: `system/lib/common.sh` (defaults + derived), `system/vpnkit.settings` (commented keys under a new "Firefox tunnel" block)
- Create: `system/bin/ff-netns-up`, `system/bin/ff-netns-down`, `system/systemd/ff-netns.service`
- Modify: `system/install-root.sh` (install the unit, `daemon-reload`, enable+start it only when `$FF_CONF` is readable; leave a running `$FF_NS` alone as for torrents), `system/uninstall-root.sh` (disable/remove the unit, remove `ff-netns-*`, `ff-launch`, `firefox` from `/usr/local/bin`, `rm -rf /etc/netns/$FF_NS`; `--purge` also removes `$FF_CONF` and `$FF_SERVER_FILE`)
- Test: `tests/vm/suite.sh` new section `"3b. Firefox namespace"` (after section 3), plus a third peer in section 0

**Interfaces:**
- Produces in `common.sh`: `FF_NS="ffvpn"`, `FF_WG_IF="pff0"`, `FF_CONF=""` → derived `/etc/wireguard/vpnkit-firefox.conf`, `FF_SERVER_FILE=/etc/vpnkit/firefox-server`, `FF_BIN=/usr/lib/firefox/firefox`. All overridable in `vpnkit.conf` except `FF_SERVER_FILE` and `FF_BIN`.
- `ff-netns-up` = `vpnkit_netns_up "$FF_NS" "$FF_WG_IF" "$FF_CONF" ffguard`; `ff-netns-down` = `vpnkit_netns_down "$FF_NS" "$FF_WG_IF"`.
- `ff-netns.service`: a copy of `qbt-netns.service` with the Firefox names (oneshot, `RemainAfterExit=yes`, `Restart=on-failure`, `RestartSec=10`, `WantedBy=multi-user.target`).

- [ ] **Step 1: Write the VM tests.** Section 0: add a client key `ff` and peer `$(cat $WG/ff.pub)@10.3.0.4/32` on server B (`wgB`, endpoint `203.0.113.2:51821`), and write `$DROP/firefox/se-4.conf` with `conf ... 10.3.0.4 10.3.0.1 "SE#4" srvB.pub 51821`. Section 3b, before anything is imported: `no "no Firefox namespace before opt-in" ip netns exec ffvpn true`, `is "unit not enabled before opt-in" "$(systemctl is-enabled ff-netns.service)" "disabled"`. (Import and the rest come in Task 3.) After Task 3's import, in the same section: `is "only lo and the tunnel are inside" "<links>" "lo,pff0"`, `is "Firefox namespace exits through its own server" "$(ip netns exec ffvpn curl -4 -s --max-time 4 $LOOKUP)" "10.3.0.4"`, `yes "DNS inside uses the in-tunnel resolver" ip netns exec ffvpn getent hosts only-in-tunnel.test`, `is "unit retries" "$(systemctl show -p Restart --value ff-netns.service)" "on-failure"`, then with `pff0` down: `is "tunnel down: nothing leaves" ... "none"`, `no "tunnel down: no DNS" ...`; restore.
- [ ] **Step 2: Run `tests/vm/vm.sh test`;** expected: the new 3b checks FAIL (no unit, no `ff-netns-up`).
- [ ] **Step 3: Implement** the `common.sh` keys, the two scripts, the unit and the install/uninstall lines above.
- [ ] **Step 4: Run `tests/check.sh` and `tests/vm/vm.sh test`;** expected: the pre-import checks pass; post-import checks still fail until Task 3.
- [ ] **Step 5: Commit** `feat: Firefox namespace builder and boot unit (inert until opted in)`.

### Task 3: Choosing the Firefox server, opting out, and the one-key/one-exit guards

**Files:**
- Modify: `system/bin/vpnkit-sync`, `system/bin/vpn-toggle`, `system/bin/vpn-import`
- Test: `tests/vm/suite.sh` sections 2 and 3b

**Interfaces:**
- Consumes: `FF_CONF`, `FF_SERVER_FILE`, `FF_NS` (Task 2).
- Produces: `vpnkit-sync firefox <name>` (= `select_firefox`), `vpnkit-sync firefox off` (= `firefox_off`); the drop folder's `firefox/` subfolder imported like `torrent/` with the first import selected for Firefox; the sync summary JSON gains `"firefox": "<name>"`; `vpn-import --firefox x.conf`. Shared helpers in `vpnkit-sync`: `endpoint_of <file>` (the `[Peer] Endpoint` via `vpnkit_wg_get`, lowercased) and `role_of <name>` printing `regular`, `torrent`, `firefox` or nothing.
- Rules (exact messages are the builder's, each starting `vpnkit-sync:`):
  - `select_firefox` refuses: invalid name (`valid_name`), unknown server, `role_of` is `regular` or `torrent`, `endpoint_of` equals that of `$QBT_CONF`, or a Firefox of `$TARGET_USER` is running (any process whose exe is `$FF_BIN`; rebuilding the namespace would strand it). On success: copy to `$FF_CONF` (600, root), write `$FF_SERVER_FILE` (644), `systemctl enable` + `restart ff-netns.service`, print `firefox: <name>`.
  - `select_torrent` additionally refuses `role_of` = `firefox` and an endpoint equal to `$FF_CONF`'s.
  - `do_remove` refuses the Firefox server ("choose another Firefox server or turn the Firefox tunnel off first").
  - `vpn-toggle <server>` refuses the Firefox server with the same wording style as its torrent refusal (`vpn-toggle:64-66`), and its listing shows it under "Used for Firefox".
  - `firefox_off` refuses while a Firefox of `$TARGET_USER` runs inside `$FF_NS`; otherwise disables and stops the unit, removes `$FF_CONF`, `$FF_SERVER_FILE` and `/etc/netns/$FF_NS`, prints `firefox: off`. The server itself stays (it can be reused elsewhere).
  - `README.txt` written by `ensure_folder` gains the `firefox/` line; `ensure_folder` creates `firefox/` (700).

- [ ] **Step 1: Write the VM tests** (3b, using the fixtures from Task 2): `yes "import from firefox/ selects it for Firefox" as_user /usr/local/bin/vpn-import`, then `is "status names the Firefox server" "$(status .ff_conn)" "proton-se-4"` (status comes in Task 6; until then assert `cat /etc/vpnkit/firefox-server`). Guards: `no "the Firefox server cannot carry regular traffic" as_user /usr/local/bin/vpn-toggle proton-se-4`; `no "the Firefox server cannot carry torrents" as_user sudo -n /usr/local/bin/vpnkit-sync torrent proton-se-4`; `no "the torrent server cannot be chosen for Firefox" as_user sudo -n /usr/local/bin/vpnkit-sync firefox proton-nl-3`; `no "a server on the torrent tunnel's endpoint is refused for Firefox"` using a fourth fixture config on endpoint `:51820` imported as a plain server; `no "the Firefox server cannot be removed" ... remove proton-se-4`; `no "names outside the kit cannot be chosen" ... firefox "Wired connection 1"`; `no "a path is not a name" ... firefox ../../etc/shadow`. Opt-out: `yes "firefox off" as_user sudo -n /usr/local/bin/vpnkit-sync firefox off`, `no "namespace gone" ip netns exec ffvpn true`, `is "unit disabled" ... "disabled"`, then re-select for the later tasks.
- [ ] **Step 2: Run `tests/vm/vm.sh test`;** expected: new checks FAIL.
- [ ] **Step 3: Implement** the rules above.
- [ ] **Step 4: Run `tests/check.sh` and `tests/vm/vm.sh test`;** expected: sections 2, 3, 3b pass (3b's launch and status checks are added later).
- [ ] **Step 5: Commit** `feat: choose a Firefox server; one key and one exit per tunnel`.

### Task 4: Starting Firefox inside the namespace

**Files:**
- Create: `system/bin/firefox` (PATH wrapper, installed to `/usr/local/bin/firefox`), `system/bin/ff-launch` (root launcher)
- Modify: `system/lib/common.sh` (`vpnkit_ff_outside_pids`), `system/sudoers.d/99-vpnkit`, `SECURITY.md`
- Test: `tests/vm/suite.sh` section 3b

**Interfaces:**
- Produces: `vpnkit_ff_outside_pids <ns inode or ""> <user>`: every process of `<user>` whose exe is `$FF_BIN` (allow the `" (deleted)"` suffix, as `vpnkit_qbt_outside_pids` does) and whose network namespace inode differs from `<ns inode>`.
- `/usr/local/bin/firefox` (runs as the user), in this order:
  1. `$FF_CONF` not readable (tunnel off) → `exec $FF_BIN "$@"` (pass-through; Review Focus 1).
  2. Any `vpnkit_ff_outside_pids` → refuse, naming the PIDs and saying to close that Firefox first.
  3. Already inside `$FF_NS` (inode compare, as the qBittorrent wrapper) → refuse unless `vpnkit_resolver_safe /etc`, else `exec $FF_BIN "$@"`.
  4. Namespace missing → refuse with `sudo systemctl start ff-netns.service`.
  5. Otherwise `exec sudo -n /usr/local/bin/ff-launch "$@"`.
- `ff-launch` (root, passwordless): the same checks and order as `qbt-launch` with Firefox names (binary hardcoded to `$FF_BIN`, resolver files, default route, outside PIDs, drop to `$TARGET_USER` with `runuser` before exec, same environment build). It also refuses when `$FF_CONF` is not readable. Arguments go only to Firefox.
- Sudoers: `@USER@ ALL=(root) NOPASSWD: /usr/local/bin/ff-launch` and an `env_keep` line identical to `qbt-launch`'s plus `MOZ_ENABLE_WAYLAND`.
- `SECURITY.md`: helper count five → six; new row `ff-launch | passed to Firefox only | start /usr/lib/firefox/firefox inside the Firefox namespace, as the desktop user; refuses while the tunnel is off or down, the resolver files are unsafe, or a Firefox of that user runs outside the namespace`.

- [ ] **Step 1: Write the VM tests.** Stand-in: `install -D /usr/bin/sleep /usr/lib/firefox/firefox`. With the tunnel selected: start `as_user /usr/local/bin/firefox 600 &` → `is "Firefox started through the wrapper is inside the namespace"` (compare `/proc/<pid>/ns/net` inode with `/var/run/netns/ffvpn`), `is "and runs as the desktop user"`. With a stand-in started directly from `/usr/lib/firefox/firefox` outside: `no "with one outside, the wrapper refuses"`, `no "with one outside, ff-launch refuses"`. Tunnel down (`pff0` down): `no "tunnel down: Firefox refuses to start"`. Resolver file moved away: `no "without the namespace's nsswitch.conf, ff-launch refuses"`. Abuse: `no "ff-launch cannot run another binary"` (pass `--` and a path; assert the started process's exe is still `/usr/lib/firefox/firefox` and it runs as `tester`, not root). `firefox off`, then: `is "firefox off: the wrapper execs the real binary" "<pid's netns inode>" "<host netns inode>"` and `no "firefox off: ff-launch refuses"`.
- [ ] **Step 2: Run `tests/vm/vm.sh test`;** expected: new checks FAIL.
- [ ] **Step 3: Implement** the wrapper, `ff-launch`, the library function, the sudoers lines and the `SECURITY.md` row.
- [ ] **Step 4: Run `tests/check.sh` (sudoers validates) and `tests/vm/vm.sh test`;** expected: all pass.
- [ ] **Step 5: Commit** `feat: Firefox starts only inside its namespace once opted in`.

### Task 5: The desktop launcher override follows the opt-in

**Files:**
- Create: `system/bin/vpn-firefox-launcher` (user command, no root)
- Modify: `install.sh` (call it after the root half), `system/bin/vpn-import` (call it after `vpnkit-sync`), `VpnWidget.qml` (call it after the sync, Firefox-select and Firefox-off processes finish), `uninstall.sh` (remove the override it wrote)
- Test: `tests/vm/suite.sh` section 3b

**Interfaces:**
- Consumes: `FF_SERVER_FILE` (Task 2; mode 644, so the user can read it: non-empty = opted in).
- `vpn-firefox-launcher`: when `$FF_SERVER_FILE` is non-empty and `/usr/share/applications/firefox.desktop` exists, write `~/.local/share/applications/firefox.desktop`: the system file with every `Exec=/usr/lib/firefox/firefox` replaced by `Exec=/usr/local/bin/firefox`, keeping each line's arguments (`%u`, `--new-window %u`, `--private-window %u`, `--ProfileManager`), plus a first comment line `# Written by omarchy-proton (Firefox tunnel). Removed when the tunnel is turned off.`. When off: remove that file only if its first line is that marker; a user's own `firefox.desktop` is backed up (`.bak.<stamp>`) before the first write and never deleted. Run `update-desktop-database` on the folder when present.

- [ ] **Step 1: Write the VM tests** (copy a minimal `firefox.desktop` fixture with the four Exec lines into `/usr/share/applications` in section 0): opted in → `yes "the override's Exec is the wrapper"` (all four Exec lines start with `/usr/local/bin/firefox`), `yes "actions keep their arguments"` (the three argument strings are present); opted out → `no "no override while off"` (`test -e`); a pre-existing user file without the marker → `yes "a user's own launcher is backed up, not lost"`.
- [ ] **Step 2: Run the VM suite;** expected FAIL.
- [ ] **Step 3: Implement** `vpn-firefox-launcher` and the four call sites.
- [ ] **Step 4: Run `tests/check.sh` and `tests/vm/vm.sh test`;** expected PASS.
- [ ] **Step 5: Commit** `feat: Firefox launcher follows the tunnel opt-in`.

### Task 6: Status, bar data and the leak check

**Files:**
- Modify: `system/bin/qbt-netns-status`, `system/bin/vpn-status`, `system/bin/vpn-verify`, `tests/preview/status*.json` (add the new fields with made-up values)
- Test: `tests/vm/suite.sh` sections 3b and 5

**Interfaces:**
- `qbt-netns-status` adds one key `"firefox": {"configured", "exists", "tunnel_up", "exit_ip", "server", "conn", "running", "protected", "unprotected", "pids"}`, computed exactly like the torrent fields (exit IP cached in `/run/ff-netns-exit-ip`, 60 s, only an address is cached; running/protected by namespace inode on processes whose exe is `$FF_BIN`). Still takes no arguments.
- `vpn-status --json` adds `ff_configured, ff_ns, ff_tunnel, ff_ip, ff_server, ff_conn, ff_running, ff_protected, ff_unprotected, firefox_if, firefox_ns`; text mode adds a "Firefox tunnel" and a "Firefox app" line after the qBittorrent lines, shown only when configured (a line "not set up" otherwise, mirroring the torrent wording with `firefox/`).
- `vpn-verify` (read-only variant) adds, when configured: links inside are exactly `lo,$FF_WG_IF`; resolver files safe; no Firefox outside the namespace (FAIL names PIDs); each Firefox process inside sees safe resolver files (the same "entered too early" check as qBittorrent); exit IP of Firefox ≠ exit IP of the torrent tunnel (FAIL "Firefox and torrents leave from the same address"). When not configured: one INFO line, no FAIL.

- [ ] **Step 1: Write the VM tests:** `is "status: Firefox tunnel up" "$(status .ff_tunnel)" "true"`, `is "status: Firefox exit" "$(status .ff_ip)" "10.3.0.4"`, `is "status: protected" "$(status .ff_protected)" "true"` with the stand-in running inside, `is "status: unprotected" "$(status .ff_unprotected)" "true"` with one outside, `yes "the leak check fails on a Firefox outside"` (grep the FAIL line), `yes "the leak check passes with Firefox inside"`; same-exit: temporarily add `10.3.0.4/32` as an allowed IP for the torrent peer on `wgB`, repoint the torrent tunnel there, `yes "the leak check fails when both tunnels share an exit"`, restore. With Firefox off: `is "ff_configured false" ... "false"`, `no "no Firefox FAIL lines when off"`.
- [ ] **Step 2: Run the VM suite;** expected FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `tests/check.sh` and `tests/vm/vm.sh test`;** expected PASS.
- [ ] **Step 5: Commit** `feat: Firefox tunnel in status and the leak check`.

### Task 7: Panel row

**Files:**
- Modify: `VpnWidget.qml` (properties beside `qbtTunnel`/`qbtIp`/`qbtServer` at ~275; a "Firefox:" line under the "Torrents:" line at ~874, same style, shown only when `ffConfigured`; red/warning state when `ffUnprotected` or configured but tunnel down)
- Test: `qmllint` via `tests/check.sh`; `tests/preview/make-preview.sh` renders with the new fields

- [ ] **Step 1: Implement** the properties and the line; no VPN logic in QML (read `vpn-status --json` only).
- [ ] **Step 2: Run `tests/check.sh`;** expected PASS (qmllint). Render the preview and look at it: no personal data, made-up servers only.
- [ ] **Step 3: Commit** `feat: Firefox tunnel in the panel`.

### Task 8: Documentation and release 0.4.0

**Files:**
- Modify: `README.md`, `CHANGELOG.md`, `VERSION`, `manifest.json`, `VpnWidget.qml` (`kitVersion`), `CONTRIBUTING.md` (layout list), `system/skills/diagnose-vpn/SKILL.md` (Firefox namespace names, "never weaken" rule covers it)

- [ ] **Step 1: README:** "Two tunnels" table becomes three columns (desktop VPN, torrent tunnel, Firefox tunnel; Firefox default "off until you import a config to `firefox/`, then on from boot"); a "Firefox tunnel" section with the spec's "What the namespace means for Firefox" paragraph, how to turn it on (download a separate config, NetShield level of your choice, put it in `firefox/`, Refresh), how to turn it off (`vpnkit-sync firefox off` / panel), the same-exit rule, and that Firefox's own DNS-over-HTTPS bypasses the tunnel's resolver (turn it off in Firefox settings to use the provider's DNS); "What gets installed" and "Uninstall" updated; "Limits": one app per tunnel, Firefox only.
- [ ] **Step 2: CHANGELOG `## 0.4.0 (<date>)`** with an "Upgrading" note: nothing changes for Firefox until you opt in. Bump `VERSION`, `manifest.json`, `kitVersion`.
- [ ] **Step 3: Run `tests/check.sh`, `tests/marketplace-scan.sh <marketplace checkout>` (expect review-required, no findings) and `tests/vm/vm.sh test`;** expected all pass. Paste the VM result into the release notes.
- [ ] **Step 4: Commit** `release: 0.4.0 Firefox tunnel`. Tag and marketplace verification issue only with the owner's go-ahead.

## Rollout on the owner's machine (after the release; owner only)

The owner downloads one more Proton WireGuard config for a different server than the torrent one, puts it in `~/Documents/WireGuard/firefox/`, and clicks "Update the system part" in the panel (or runs `install.sh` in a terminal). Agents prepare this, they do not run it.
