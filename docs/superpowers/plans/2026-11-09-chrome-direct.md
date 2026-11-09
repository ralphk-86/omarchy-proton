# Chrome Direct Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Opt-in exemption that keeps Google Chrome on the normal connection and on a loopback resolver while a desktop VPN server is selected, without letting any other process out.

**Architecture:** A root-owned top-level cgroup (`vpnkitdirect.slice`) holds only what the kit's launcher starts. nftables marks those sockets' packets with `DIRECT_FWMARK`, policy rules send the mark to the main table (tailnet addresses to Tailscale's table), NAT fixes the source, and the kill switch accepts the mark after its DNS reject. The launcher starts Chrome in a private mount namespace whose resolver files name `DIRECT_DNS` only.

**Tech Stack:** bash, nftables (`socket cgroupv2`, route-type output chain, NAT), iproute2 `ip rule`, systemd (slice, oneshot unit, `systemd-run --scope`), util-linux `unshare`/`mount`, jq, QML.

**Spec:** `docs/superpowers/specs/2026-11-09-chrome-direct-design.md`

**Order:** these tasks run BEFORE `2026-11-09-firefox-tunnel.md`. That plan's Task 8 releases both features as 0.4.0 and its README/CHANGELOG step covers this one too.

## Global Constraints

- Public repo: no personal data in files or commits; `tests/check.sh` passes before every commit.
- Root helpers take no paths and validate every argument; each new passwordless rule gets a `SECURITY.md` row and an abuse test.
- Network changes are tested only in the VM (`tests/vm/vm.sh test`, baseline 207 passed / 0 failed on 2026-11-09). Agents never run the root installer on the developer's machine.
- Opt-in: nothing changes until `vpnkit-direct on`; `vpnkit-direct off` and uninstall remove every rule, mark, unit and override.
- Values from the spec: slice `vpnkitdirect.slice` (nft: `socket cgroupv2 level 1 "vpnkitdirect.slice"`), table `inet vpnkit_direct`, `DIRECT_FWMARK=51821`, rules `priority 89 fwmark 51821 to 100.64.0.0/10 lookup 52` (only when table 52 exists) and `priority 90 fwmark 51821 lookup main`, kill-switch line `meta mark 51821 accept` placed after the DNS reject, `DIRECT_DNS` empty or in 127.0.0.0/8 (default empty), state file `/etc/vpnkit/direct-apps`.
- Launcher refuses `--renderer-cmd-prefix`, `--utility-cmd-prefix`, `--gpu-launcher`, `--browser-subprocess-path` and any `--*-cmd-prefix` / `--*-launcher` argument (with or without `=value`).
- The torrent tunnel and the existing kill-switch behaviour are unchanged when the feature is off (VM sections 1-6 keep passing).

## Review Focus

1. **Feature off after an update:** Chrome starts exactly as before, through the bar's VPN when one is selected; no `vpnkit_direct` table, no fwmark rules, no kill-switch line. Test in Task 1 (`off: nothing installed`) and Task 2 (`off: wrapper passes through`).
2. **Chrome already open outside the slice when the owner turns it on:** turning on works, launches are refused with "close Chrome first", status shows `chrome_outside`, leak check names it. Tests in 2 and 3.
3. **systemd-resolved rewrites its stub file while Chrome runs:** Chrome keeps resolving through `DIRECT_DNS`. Test in 2 (`resolver override survives a host-side rename`).
4. **A desktop server selected, then the VPN drops (kill switch blocking):** Chrome still reaches the internet directly, everything else stays blocked. Test in 1 (`blocked: the slice still gets out, the host does not`).
5. **`DIRECT_DNS` set but nothing answers:** `vpnkit-direct on` refuses with a message; a resolver that dies later shows in status. Tests in 1 and 3.

---

### Task 1: Slice, rules and the on/off helper

**Files:**
- Modify: `system/lib/common.sh` (`DIRECT_FWMARK=51821`, `DIRECT_DNS=""`, `DIRECT_SLICE=vpnkitdirect.slice`, `DIRECT_STATE=/etc/vpnkit/direct-apps`, `DIRECT_BIN=/usr/bin/google-chrome-stable`; helper `vpnkit_direct_on` = state file says `chrome`), `system/vpnkit.settings` (commented `DIRECT_DNS` block explaining loopback-only), `system/bin/vpnkit-killswitch` (the accept line, only when `vpnkit_direct_on`)
- Create: `system/systemd/vpnkitdirect.slice`, `system/systemd/vpnkit-direct.service` (oneshot, `RemainAfterExit=yes`, keeps the slice's cgroup present for as long as it is active, `ExecStart=/usr/local/bin/vpnkit-direct-rules up`, `ExecStop=... down`), `system/bin/vpnkit-direct-rules` (root, called only by the unit: loads/removes the nft table and the ip rules; `up` is idempotent and reloads the table so a recreated cgroup gets the current id), `system/bin/vpnkit-direct` (root helper: `on`, `off`, `status`)
- Modify: `system/install-root.sh` (install units, daemon-reload; start only when `vpnkit_direct_on`), `system/uninstall-root.sh` (stop/disable/remove units and helpers, `rm -f $DIRECT_STATE`, delete table and rules), `system/dispatcher.d/50-vpnkit` (after a link comes up, `vpnkit-direct-rules up` when on, so the tailnet rule follows Tailscale)
- Test: `tests/vm/suite.sh` new section `"4b. Chrome direct: rules"` after section 4

**Interfaces:**
- Produces: `vpnkit-direct on` (refuses unless `DIRECT_DNS` is empty or answers a query; writes state, enables+starts the unit, re-arms the kill switch if armed, prints `direct: on`), `vpnkit-direct off` (refuses while a process runs in the slice; reverse of on; prints `direct: off`), `vpnkit-direct status` (JSON `{"enabled","unit","rules","dns_ok"}`). Any other argument: exit 2.
- Produces: `/sys/fs/cgroup/vpnkitdirect.slice` exists while the unit is active.

- [ ] **Step 1: VM tests.** Section 0: `dnsmasq` on `127.0.0.1:53` answering `direct-only.test` → `192.0.2.9` (stop the VM's own stub listener only if it conflicts: it listens on 127.0.0.53). Section 4b, server A selected: `no "off: nothing installed"` (`nft list table inet vpnkit_direct`), `no "off: no fwmark rule"` (`ip rule | grep 0xca6d`); `echo 'DIRECT_DNS="127.0.0.1"' >> /etc/vpnkit/vpnkit.conf`; `yes "on" as_user sudo -n /usr/local/bin/vpnkit-direct on`; `is "a probe in the slice exits from the home address" "$(systemd-run --quiet --wait --pipe --slice=vpnkitdirect.slice --uid=$U curl -4 -s --max-time 4 $LOOKUP)" "$HOME_IP"`; `is "the host still exits through the server" "$(myip)" "10.2.0.2"`; `no "a user cannot start a process in the slice" as_user systemd-run --user --slice=vpnkitdirect.slice true` and `no "nor move itself in" as_user sh -c 'echo $$ > /sys/fs/cgroup/vpnkitdirect.slice/cgroup.procs'`; `yes "the kill switch has the direct line after the DNS reject"` (awk order check on `nft list table inet vpnkit_kill`); bring server A's link down (blocked): `is "blocked: the slice still gets out" ... "$HOME_IP"`, `is "blocked: the host does not" "$(myip)" "none"`; restore. Recreate the cgroup (`systemctl restart vpnkit-direct.service`) and repeat the probe: `is "rules follow a recreated cgroup"`. `no "a DIRECT_DNS outside loopback is refused"` (set `192.0.2.53`, `vpnkit-direct on` must fail). `no "a DIRECT_DNS that does not answer is refused"` (`127.0.0.9`). `yes "off" ...`, then the three "off" checks again plus `no "kill switch line gone"`.
- [ ] **Step 2: Run `tests/vm/vm.sh test`** — new checks FAIL, sections 1-6 pass.
- [ ] **Step 3: Implement** the files above. nft table (by `vpnkit-direct-rules up`): chain `output { type route hook output priority mangle; socket cgroupv2 level 1 "vpnkitdirect.slice" meta mark set $DIRECT_FWMARK }` and chain `postrouting { type nat hook postrouting priority srcnat; meta mark $DIRECT_FWMARK oifname != "$PROFILE_PREFIX-*" masquerade }`, loaded with the same add/delete/define atomic pattern as the kill switch. The tailnet rule only when `ip route show table 52` succeeds.
- [ ] **Step 4: Run `tests/check.sh` and `tests/vm/vm.sh test`** — all pass.
- [ ] **Step 5: Commit** `feat: Chrome direct rules and on/off helper (inert until on)`.

### Task 2: Starting Chrome in the slice with the private resolver

**Files:**
- Create: `system/bin/google-chrome-stable` (PATH wrapper, installed to `/usr/local/bin`), `system/bin/direct-launch` (root launcher), `system/bin/vpn-direct` (user command: `on|off` → `sudo -n vpnkit-direct`, then the launcher-override step)
- Modify: `system/sudoers.d/99-vpnkit` (`direct-launch` with an `env_keep` line identical to `qbt-launch`'s; `vpnkit-direct` with exactly the arguments `on`, `off`, `status`, one rule each), `SECURITY.md` (two rows; helper count), `install.sh` / `uninstall.sh` (the override step) (the override step lives in `vpn-direct`; it does not depend on the Firefox plan's `vpn-firefox-launcher`)
- Test: `tests/vm/suite.sh` section 4b continued

**Interfaces:**
- Wrapper: off → `exec /usr/bin/google-chrome-stable "$@"`; on → refuse (message naming PIDs) when a Chrome of the user (exe under `/opt/google/chrome/`) runs outside the slice, else `exec sudo -n /usr/local/bin/direct-launch "$@"`.
- `direct-launch` (root): refuses when off; refuses the flags listed in Global Constraints; refuses when a Chrome of `$TARGET_USER` runs outside the slice; then `unshare --mount --propagation slave` and inside it: when `DIRECT_DNS` is set, mount a tmpfs on `/run/systemd/resolve` containing `stub-resolv.conf` and `resolv.conf` (`nameserver $DIRECT_DNS`, `options edns0 trust-ad`), bind a kit-written `nsswitch.conf` (hosts: `files myhostname dns`) over `/etc/nsswitch.conf`; then `systemd-run --scope --quiet --slice=$DIRECT_SLICE --uid=$TARGET_USER --gid=<its group>` with the same environment `qbt-launch` builds plus `HOME`/`XDG_CONFIG_HOME` of the user, running `$DIRECT_BIN "$@"`.
- Launcher override: when on and `/usr/share/applications/google-chrome.desktop` exists, write `~/.local/share/applications/google-chrome.desktop` with every `Exec=/usr/bin/google-chrome-stable` → `Exec=/usr/local/bin/google-chrome-stable` (arguments kept) and the marker first line `# Written by omarchy-proton (Chrome direct). Removed when it is turned off.`; when off, remove it only if it carries the marker; back up a user's own file first.

- [ ] **Step 1: VM tests.** Stand-in `/usr/bin/google-chrome-stable`: a script that writes `$(curl -4 -s --max-time 4 $LOOKUP) $(getent hosts direct-only.test | awk '{print $1}') $(getent hosts only-in-tunnel.test >/dev/null && echo leak || echo noleak) $(id -un)` to `/tmp/chrome-probe` then sleeps 600, and a stand-in `/opt/google/chrome/chrome` (copy of sleep) for the "outside" checks. With direct on and server A selected: `as_user /usr/local/bin/google-chrome-stable &` → `is "Chrome direct: probe" "$(cat /tmp/chrome-probe)" "$HOME_IP 192.0.2.9 noleak $U"`; `yes "and it runs in the slice"` (its `/proc/<pid>/cgroup` ends in `vpnkitdirect.slice/...`); `yes "resolver override survives a host-side rename"` (on the host `cp` then `mv` a new file over `/run/systemd/resolve/stub-resolv.conf`, then `nsenter -t <pid> -m cat /etc/resolv.conf` still names 127.0.0.1); flags: `no "--renderer-cmd-prefix is refused" as_user sudo -n /usr/local/bin/direct-launch --renderer-cmd-prefix=/bin/sh`, same for `--gpu-launcher /bin/sh`, `--browser-subprocess-path=/bin/sh`, `--foo-cmd-prefix=x`; with the stand-in `/opt/google/chrome/chrome` started outside: `no "with Chrome outside, the wrapper refuses"`, `no "and direct-launch refuses"`; off: `is "off: wrapper passes through"` (the probe shows `10.2.0.2`), `no "off: direct-launch refuses"`. Override fixture `google-chrome.desktop` with three Exec lines: `yes "override points at the wrapper"`, `yes "override removed when off"`, `yes "a user's own file is backed up"`.
- [ ] **Step 2: Run the VM suite** — new checks FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `tests/check.sh` (sudoers validates) and `tests/vm/vm.sh test`** — all pass.
- [ ] **Step 5: Commit** `feat: Chrome starts in the direct slice with its own resolver`.

### Task 3: Status, leak check and the panel switch

**Files:**
- Modify: `system/bin/qbt-netns-status` (key `"direct": {"enabled","unit","rules","dns","dns_ok","chrome_inside","chrome_outside","override_ok","helpers","others"}`; `helpers`/`others` are comma-separated program names of non-Chrome processes in the slice, split by whether their exe is named in a native-messaging manifest under `/etc/opt/chrome/native-messaging-hosts` or the user's `~/.config/google-chrome/NativeMessagingHosts`), `system/bin/vpn-status` (`direct_*` fields; a text line "Chrome direct: on · home IP · DNS 127.0.0.1" / "off"), `system/bin/vpn-verify` (when on: PASS/FAIL that a slice probe exits from the normal connection while a server is selected; FAIL `others`; WARN `helpers`; FAIL `override_ok=false` for any Chrome process; FAIL rules or unit missing; FAIL `dns_ok=false`), `VpnWidget.qml` (a switch "Chrome uses your own IP" in the panel calling `vpn-direct on|off`, error text from stderr like the torrent switch; a "Chrome: direct" line under "Torrents:"), `tests/preview/status*.json`
- Test: `tests/vm/suite.sh` sections 4b and 5

- [ ] **Step 1: VM tests:** `is "status: direct on" "$(status .direct_enabled)" "true"`; with the stand-in inside `is "chrome inside" ... "true"`; start `sleep` inside the slice via root `systemd-run --scope --slice` → `yes "the leak check fails on a non-Chrome process in the slice"` naming it; register that program in a manifest under `/etc/opt/chrome/native-messaging-hosts` → `yes "a registered native host is a warning, not a failure"`; stop the dnsmasq on 127.0.0.1 → `is "dns_ok false" ... "false"` and `yes "the leak check fails on a dead DIRECT_DNS"`; restore. Off: `is "status: off" ... "false"`, `no "no direct lines in the leak check when off"`.
- [ ] **Step 2: Run the VM suite** — FAIL.
- [ ] **Step 3: Implement**, then `tests/check.sh` (qmllint) and `tests/preview/make-preview.sh` (look at it: made-up data only).
- [ ] **Step 4: Run `tests/vm/vm.sh test`** — all pass.
- [ ] **Step 5: Commit** `feat: Chrome direct in status, leak check and panel`.

## Rollout on the owner's machine (owner only, after the 0.4.0 release)

Add `DIRECT_DNS="127.0.0.1"` to `/etc/vpnkit/vpnkit.conf`, click "Update the system part", close Chrome, flip "Chrome uses your own IP" in the panel, open Chrome.
