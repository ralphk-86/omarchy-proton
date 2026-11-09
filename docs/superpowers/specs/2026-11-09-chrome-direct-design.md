# Chrome direct: design

Status: approved by the owner, 2026-11-09 ("go ahead and write it up, make all necessary
changes"). Ships alone in 0.4.0; the companion `2026-11-09-firefox-tunnel-design.md` follows in 0.5.0.

## Intent

The owner wants Chrome **always** on the normal connection (the home IP), also while a
desktop VPN server is selected in the bar, and always resolving through the local ad-blocking
resolver (AdGuard Home on `127.0.0.1`), so its ad blocking is the same with the VPN on or off.
Chrome holds the sites that expect the home IP (banking, Google work tools, the Claude browser
extension). Everything else keeps following the bar; Firefox gets its own tunnel (companion
design); torrents keep theirs.

Today the desktop VPN moves every process, and its kill switch rejects anything that does not
leave through a tunnel. So this is a narrow, explicit exemption in the kill switch for one app,
launched one way. That hole is the price; the design keeps it as small as it can be.

## Goals

1. Opt-in. Until the owner turns it on, nothing changes: Chrome follows the bar like today.
2. Once on, Chrome's traffic leaves through the normal connection whatever the bar says
   (Normal connection, a server, or blocked), and the bar keeps covering everything else.
3. Chrome resolves names through a configured resolver (`DIRECT_DNS`, default `127.0.0.1`),
   with the VPN on or off. With `DIRECT_DNS` empty it uses the system resolver.
4. Only processes the kit's own launcher started can use the exemption. A user process cannot
   put itself into it.
5. Every normal way to open Chrome lands in the exemption: the launcher entry and its actions,
   Omarchy's "browser" launcher (`omarchy-launch-browser`, which reads the default browser's
   `Exec=`), `google-chrome-stable` in a terminal, and links from other apps.
6. Status, panel and leak check know about it and say plainly which apps are exempt.

## Non-goals

- Other apps, or a general "split tunnel by app" UI. One app: Google Chrome (`google-chrome`
  package). The mechanism may be written so a second app is possible later; nothing more.
- IPv6 (off system-wide in this kit).
- Changing how AdGuard Home is set up; the plugin only points Chrome at `DIRECT_DNS`.

## Anti-goals

- Any process other than one started by the kit's launcher getting the exemption.
- The exemption existing while the feature is off, or surviving `vpnkit-direct off`/uninstall.
- Weakening the kill switch for anything else, the Firefox tunnel, or the torrent tunnel.
- Chrome's DNS leaving outside a tunnel in plain text towards anything but `DIRECT_DNS`
  (the kill switch's "no DNS outside a tunnel" rule stays in force for Chrome's own packets).
- A failure that silently sends Chrome through the VPN without saying so is acceptable (it is
  the safe direction) only if the status shows it; a failure that sends other apps out
  directly is not acceptable.

## Constraints

Everything in the repository's `CLAUDE.md` (public repo, fail closed, root helpers take no
paths and validate arguments, new sudo rule = `SECURITY.md` row + abuse test, never overwrite
user config without a flag, network changes tested only in the VM).

## Decided (designer's calls, owner approved the feature)

- **Who is exempt: a dedicated system cgroup.** A root-owned slice `vpnkitdirect.slice` (top
  level, so the nftables match is `socket cgroupv2 level 1 "vpnkitdirect.slice"`). Only root
  can place a process there, so a user process cannot join it (Goal 4). Chrome started by the
  launcher runs there as the desktop user. The cgroup must exist continuously while the
  feature is on (nftables resolves the path to an id when the rule is loaded): a oneshot unit
  `vpnkit-direct.service` keeps it pinned and loads the rules; if the cgroup is ever
  recreated, the rules are reloaded.
- **How it leaves directly: its own fwmark.** `DIRECT_FWMARK=51821` (not `VPN_FWMARK`, so the
  WireGuard packets and the torrent tunnel are untouched). nftables table `inet vpnkit_direct`:
  a `type route hook output` chain sets the mark on packets from sockets in the slice; a
  postrouting NAT chain masquerades marked packets that leave a non-tunnel interface (their
  source address was chosen while the VPN route was in place). One `ip rule`
  `priority 90 fwmark 51821 lookup main`, ahead of NetworkManager's WireGuard rules.
- **The kill switch hole.** When the feature is on, `vpnkit-killswitch on` adds
  `meta mark 51821 accept` **after** the DNS reject rule, so Chrome's packets may leave
  directly but its plain DNS may not leave outside a tunnel. When off, the line is absent.
- **DNS.** The launcher starts Chrome in a private mount namespace where `/etc/resolv.conf`
  names `DIRECT_DNS` only and `/etc/nsswitch.conf` has no `resolve`/`mdns` (Chrome's resolver
  and glibc then ask `DIRECT_DNS` directly instead of systemd-resolved, which would pick the
  VPN's resolver). `DIRECT_DNS=127.0.0.1` reaches AdGuard Home over loopback, which the kill
  switch allows; AdGuard Home's own upstream traffic is not exempt and follows the bar.
  If `DIRECT_DNS` is empty, no mount namespace: Chrome uses the system resolver.
- **Launch path.** Same pattern as Firefox: a PATH wrapper `/usr/local/bin/google-chrome-stable`
  (pass-through when off), a root launcher `direct-launch` (passwordless; hardcodes
  `/usr/bin/google-chrome-stable`; mount namespace; `systemd-run --scope
  --slice=vpnkitdirect.slice` as the desktop user; refuses while a Chrome of that user runs
  outside the slice, because Chrome hands new windows to the running instance over a socket),
  and a user-side launcher override for `google-chrome.desktop` that follows the opt-in.
- **Turning it on and off.** Root helper `vpnkit-direct on|off|status` (passwordless,
  validated, no paths): on = write `/etc/vpnkit/direct-apps` (`chrome`), enable and start
  `vpnkit-direct.service`, re-arm the kill switch if armed; off = the reverse, and refuse while
  Chrome runs inside the slice (closing it first is asked for, as for the torrent server).
  Panel: a switch "Chrome uses your own IP". `vpn-import`-style user command `vpn-direct
  on|off` calls the helper and the launcher-override step.
- **Status and leak check.** `qbt-netns-status` adds `"direct": {enabled, slice, rules,
  chrome_inside, chrome_outside, others_inside}`; `vpn-status` exposes `direct_*` fields and
  a text line. `vpn-verify` (when on): PASS that Chrome's exit is the home IP while a server is
  selected (checked with a probe run inside the slice), FAIL if any process in the slice is
  not Chrome (an app Chrome started, e.g. a download opened in another program, inherits the
  exemption; it is named so the user can close it), FAIL if the rules or the cgroup are
  missing while on, and the existing DNS checks still pass.

## Settled after the builder check (designer's calls)

1. **Boundary strength: against accidents, not against same-user software.** That is the
   kit's existing promise for the kill switch (README "Limits"). Same-user software can
   always ask Chrome to start things (native-messaging manifests and extensions are
   user-writable), so a stronger claim would be false. Still, the launcher refuses the
   flags that make Chrome run an arbitrary binary as a child (`--renderer-cmd-prefix`,
   `--utility-cmd-prefix`, `--gpu-launcher`, `--browser-subprocess-path`, and any
   `--*-cmd-prefix`/`--*-launcher` form), and it runs `/usr/bin/google-chrome-stable` with
   `HOME`/`XDG_CONFIG_HOME` of the desktop user so the user's `chrome-flags.conf` keeps
   working (Omarchy's Wayland flags live there). `SECURITY.md` states the limit plainly.
2. **Processes in the slice that are not Chrome.** Chrome's own binaries
   (`/opt/google/chrome/*`, crashpad, the sandbox helper) are Chrome. A program registered as
   a Chrome native-messaging host (manifests in `/etc/opt/chrome/native-messaging-hosts` and
   the user's `NativeMessagingHosts`) is a **WARN** that names it (e.g. the Claude extension's
   host, Omarchy's yt-dlp helper: both then use the home IP, which is the point of the
   feature). Anything else is a **FAIL** that names it.
3. **Tailscale stays reachable from Chrome.** Besides `priority 90 fwmark 51821 lookup main`,
   one more rule `priority 89 fwmark 51821 to 100.64.0.0/10 lookup 52` keeps tailnet
   addresses (incl. 100.100.100.100) on Tailscale's table. Only tailnet destinations, so an
   exit node never captures Chrome's other traffic. Applied only if Tailscale's table exists;
   checked again when the rules load.
4. **`DIRECT_DNS` is loopback only.** Accepted values: empty, or an address in 127.0.0.0/8.
   `vpnkit-direct on` refuses when a DNS query to `DIRECT_DNS` gets no answer, and the status
   flags a resolver that stops answering. Default in `vpnkit.settings`: empty (Chrome uses the
   system resolver, which follows the bar); the owner sets `DIRECT_DNS="127.0.0.1"`.
5. **The resolver override must not quietly come undone.** `/etc/resolv.conf` is a symlink
   into `/run/systemd/resolve/`, and systemd-resolved replaces that file by renaming, which
   detaches a bind mount in another namespace. So the private namespace mounts a tmpfs over
   `/run/systemd/resolve` holding the kit's own `stub-resolv.conf` and `resolv.conf`, binds
   `/etc/nsswitch.conf`, and uses slave mount propagation (drives mounted later still appear).
   Status and the leak check read `/proc/<chrome pid>/root/etc/resolv.conf`; an override that
   is gone while the feature is on is a **FAIL**.
6. **Omarchy web apps go direct too.** `omarchy-launch-webapp` opens them in the default
   browser, i.e. through the override, and they run inside the same Chrome anyway. The README
   lists this.

## Settled after the final review (designer's calls, 2026-11-09)

The final review checked the code against real Chrome, and a VM run with real Chrome 157 confirmed it
(`.superpowers` investigation, not in git):

7. **Chrome must not be able to move itself out of the slice.** Real Chrome asks the user systemd
   manager on every start for its own `app-com.google.Chrome-<pid>.scope`, and PID 1 attaches it:
   within a second the browser leaves `vpnkitdirect.slice`, later children start outside, pages load
   through the VPN, and every later launch is refused. Fix: Chrome gets a **filtered session bus**
   (`xdg-dbus-proxy`, official repos) with no access at all to `org.freedesktop.systemd1`; portals,
   secrets (`--password-store=gnome-libsecret`) and notifications keep working. The proxy runs as the
   user outside the slice and lives exactly as long as Chrome. Cost: Chrome's tray icon is not shown
   (the proxy cannot grant `StatusNotifierItem-*` names). Any user process can still ask to be moved
   out of the slice; that only ever moves it onto the VPN (fail-safe) and is not prevented.
8. **Apps Chrome opens do not inherit the exemption.** Links and downloads Chrome hands to other apps go
   through `xdg-open`; Chrome gets a Chrome-only `xdg-open` that starts the handler in its own user
   scope, outside the slice, so it follows the bar.
9. **Chrome's own wrapper processes are Chrome.** `/opt/google/chrome/google-chrome` keeps two
   `/usr/bin/cat` children of the browser for its whole life, and short-lived interpreter steps run at
   start-up. A `cat` whose parent's exe is under `/opt/google/chrome/`, and an interpreter whose script
   argument is under `/opt/google/chrome/`, count as Chrome. The panel/bar also requires an "other"
   process on two consecutive polls before it alerts.
10. **The tailnet rule is always present while on** (`priority 89 fwmark 51821 to 100.64.0.0/10 lookup
    52`): a lookup in an empty table 52 falls through to priority 90, so it is never worse, and Chrome
    reaches tailnet hosts once Tailscale comes up after boot. This replaces "only if Tailscale's table
    exists" in item 3.
11. **Tests use real Chrome for the containment checks**, not a stand-in, in addition to the stand-in
    checks that remain.

## What the owner should know (README)

- While on, Chrome always shows the home IP, also with a server selected. Sites see you in
  Chrome; that is the point.
- Anything Chrome itself starts (a downloaded file opened from Chrome, a native-messaging
  helper) inherits the exemption. The leak check names those processes.
- Chrome must be closed once after turning it on or off, so the next start lands in the right
  place.

## Left to the builder

- Exact pinning of the slice (an anchor process vs. relying on the slice staying active) and
  the reload path, proven in the VM by recreating the cgroup.
- Whether `systemd-run --scope --uid` inside the mount namespace or an equivalent ordering
  (namespace, then scope, then drop privileges) is used; the VM test is that Chrome runs as
  the user, in the slice, with the private resolver files.
- The panel control's placement, following the existing panel style.
- Names of status fields beyond those listed, following the existing pattern.
