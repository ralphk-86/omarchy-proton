# Changelog

## 0.4.2 (2026-11-11)

- **No predictable files in a shared `/tmp`.** The developer helper that makes the
  presentation images (`tests/preview/make-preview.sh`) wrote full-desktop captures under a
  fixed name in `/tmp`, where another local user could read them. It now works in a new
  private folder for each run (a `WORK` folder you set must be yours, not a symlink, mode
  700, or it refuses), captures only the panel or bar area of the focused monitor instead of
  the whole desktop, and deletes the raw capture as soon as it is cropped, also when it
  fails half way. Only people who build the images run it.
- The same class, in the plugin: when `XDG_RUNTIME_DIR` is not set (not the case in a normal
  desktop session), `vpn-status` kept its address cache, and the panel and `vpn-diagnose`
  their session report, under a fixed name in `/tmp`. They now use a private folder in your
  home instead (`~/.cache/vpnkit`, `~/.cache`).
- VM suite: 682 passed, 0 failed.

## 0.4.1 (2026-11-10)

- **Static IPv6 in a network profile is now saved in full and put back exactly.** To switch
  IPv6 off, setup sets `ipv6.method=disabled` in each wired and Wi-Fi profile, and has to clear
  the profile's IPv6 DNS servers, search domains, addresses, gateway and routes in the same
  call (NetworkManager refuses it otherwise). Since 0.3.6 it saved only the method, DNS servers
  and search domains. The addresses, gateway and routes were dropped, and neither the rollback
  (when the internet stops answering after setup) nor `uninstall.sh --restore-ipv6` could put
  them back; restoring a `manual` profile then failed and fell back to `auto` without saying
  so. **Who is affected:** only profiles with static IPv6 (`ipv6.method manual`, or addresses,
  a gateway or routes set by hand). Profiles with automatic IPv6, the usual case, lost nothing.
  Reported in the marketplace review of 0.4.0.
- **What changed.** Setup now saves every field it clears (method, DNS servers, search domains,
  addresses, gateway, routes with next hop, metric and attributes), each exactly as
  NetworkManager reports it, encoded so no character can break the file, keyed by the profile's
  UUID. The rollback and the uninstaller use one shared implementation (`system/lib/ipv6.sh`,
  installed to `/usr/local/lib/vpnkit/ipv6.sh`) and restore all fields in one call. A profile
  that cannot be restored is named, keeps IPv6 off instead of getting a guessed `auto`, keeps
  its saved line, and the uninstaller exits with an error. A profile NetworkManager will not
  change is left exactly as it was (before, its settings were saved anyway and could be
  applied later). A profile turned back on with different settings before a later setup has
  the new ones saved; the earlier line is kept in `/etc/vpnkit/ipv6-profiles.superseded`.
- **Profiles switched off by 0.3.6 to 0.4.0 cannot get their static addresses back.** Those
  versions never saved them; no version of this kit can recover them. Their saved lines (old
  format) are still read: method, DNS servers and search domains are restored as before. For a
  profile that had `ipv6.method manual`, `--restore-ipv6` now says that its addresses, gateway
  and routes were not saved, names the profile and leaves IPv6 off on it; set them again with
  `nmcli` (README: "IPv6 and your network profiles").
- **The restore touches only what setup changed, and the running link follows.** Found in the
  same review's audit of this code:
  - The rollback now applies the restored settings to the running connection (`nmcli device
    reapply`, which keeps it up). Before, on a network that needs IPv6 (DNS only over IPv6, an
    IPv6-only uplink) the machine stayed offline until `vpn-rescue` or a reconnect.
    `--restore-ipv6` does the same.
  - `--restore-ipv6` restores only the profiles listed in the saved file. Before, it set every
    other wired and Wi-Fi profile to `ipv6.method=auto` and cleared its IPv6 DNS servers and
    search domains: a profile you had switched off yourself came back on, and a network joined
    after setup lost its IPv6 DNS. A profile switched off by a version before 0.3.6 (which saved
    nothing) now stays off; README says how to turn it back on.
  - `--purge` no longer deletes the saved file while it holds settings not yet put back: alone
    it keeps the file and says so plainly; `--purge --restore-ipv6` restores first, then
    removes everything.
  - A rollback during an update undoes only what that run changed: the earlier setup's sysctl
    file and the profiles it switched off stay as they were (before, IPv6 came back on).
  - Profiles are addressed by UUID: a profile with a colon in its name was skipped by setup and
    by the restore, and two profiles with the same name shared one saved line.
- **The restore never loses or overrides what it should keep** (found in the review of the
  above): with NetworkManager not running (moving to another network manager, say),
  `--restore-ipv6` treated every saved profile as deleted, dropped the whole file and exited 0;
  now it changes nothing, keeps the file and exits with an error, and only a profile
  NetworkManager reports as gone has its line put aside (named, in
  `ipv6-profiles.superseded`; nothing saved is thrown away any more). A profile you turned back
  on since setup is left as you set it, its old line put aside. A line from before 0.4.1 is
  applied only to a profile of its name that has no line of its own, and setup no longer takes
  such a line over while another profile of that name is switched off. A failing `nmcli device
  reapply` (NetworkManager refuses it while a profile has other unapplied changes) now only
  warns; it used to stop setup right after the profiles were switched off. The uninstaller
  says "IPv6 re-enabled" only when it was, explains a kept saved file after any uninstall (not
  only `--purge`), and removes a leftover `/etc/vpnkit` once everything is restored.
- **Root helpers no longer run commands from your PATH** (security, found in the marketplace
  maintainer's audit of 0.4.0's privileged code). With `env_reset`, sudo replaces the caller's
  `PATH` only when sudoers sets `secure_path`. On a machine whose `/etc/sudoers` has none (an
  older or edited one), the passwordless helpers ran `id`, `nft`, `ip` and the like from the
  desktop user's `PATH` as root, for example from `~/.local/bin`: a way to root without a
  password through the rules SECURITY.md calls safe. Every script that runs as root now sets a
  fixed `PATH` before anything else (`tests/check.sh` enforces it), the settings folder is
  always `/etc/vpnkit` for root, and setup warns when sudo has no `secure_path` (it does not
  edit `/etc/sudoers`). Arch's sudo is built with a default `secure_path`, so a stock Omarchy
  was not exposed.
- **A half-finished setup no longer looks finished.** The version stamp the panel reads is now
  written last, only when every step succeeded, and removed when a run starts changing things,
  so the panel keeps offering setup after a failed run. A step that fails half way is named,
  and the connectivity check (with its rollback of the IPv6 changes) still runs. Steps that used
  to stop setup silently are fixed: the global-DNS note without systemd-resolved, and a kernel
  started with `ipv6.disable=1` (no IPv6 keys for sysctl; the torrent namespace is built too).
  A unit that cannot be enabled is reported and the run counts as not finished.
- **`install.sh --keep-ipv6`, or `DISABLE_IPV6=0`, on an existing install gives IPv6 back**, as
  the docs and the sysctl file said: it removes the sysctl file, turns IPv6 on and restores
  every saved profile on its running link. Before, `DISABLE_IPV6=0` only deleted the file and
  `--keep-ipv6` was ignored after the first install. `--keep-ipv6` now sets `DISABLE_IPV6=0`
  (after a backup of `vpnkit.conf`).
- **Your own files are left alone, or put back.** Setup no longer replaces a qBittorrent
  launcher entry of yours (it says whether yours reaches the tunnel); `install.sh
  --qbt-launcher` replaces it with a backup that the uninstaller puts back. Turning Chrome
  direct off now puts your own Chrome entry back too. Commands in `/usr/local/bin` carry a
  marker line: setup stops, changing nothing, when a file of yours has one of their names
  (`install.sh --move-aside` keeps it aside and the uninstaller puts it back), and the
  uninstaller deletes only marked files (and the unmarked commands earlier versions installed,
  known by their checksums, `system/lib/released-bin.sha256`). `sudo bash /usr/local/lib/vpnkit/uninstall-root.sh`, the way out after the plugin
  folder is gone, now also disconnects the VPN and removes the kit's launcher entries (as you),
  which used to be left pointing at deleted wrappers.
- **Servers are the kit's by their uuid, not by name.** `--purge` deleted every WireGuard
  profile named `<prefix>-*` with its `/etc/wireguard` config, yours included, and missed the
  kit's servers imported under an earlier provider prefix; the NetworkManager hook armed the
  kill switch for any such profile; the panel's delete could remove one; an import overwrote a
  WireGuard config of yours of the same name. All now go by the uuid the import gives each
  server; an import whose name is taken by something of yours gets another name.
- Smaller fixes from the audit: the leak check reads files in your home folder with your
  permissions (a symlink there could make it read root-only files, a FIFO hang it), and checks
  a running qBittorrent's files as that process's owner; the install log is readable by you
  only and goes to `~/.cache` instead of `/tmp` without `XDG_RUNTIME_DIR`; the uninstaller
  reports every failed step in its exit code, removes the namespace folder by its configured
  name and the temporary folders an interrupted tunnel start left; setup run by a second user
  stops instead of giving that user the passwordless rules while the kit keeps acting for the
  first; the docs say that IPv6 goes off on every interface but loopback (Tailscale and
  container bridges included), not only on "real" ones.
- From the final review: setup no longer stops right after the system part, before the
  qBittorrent settings, the status and "Done", when the launcher cache cannot be updated or a
  qBittorrent entry of yours cannot be read (and `vpn-direct on|off` no longer exits with an
  error after doing its work for the first reason); a launcher entry that cannot be written is
  only a warning. Without `XDG_RUNTIME_DIR`, an existing `~/.cache` keeps its mode. The
  `secure_path` check no longer warns wrongly when sudo speaks another language. Setup reads
  `TARGET_USER` the way the helpers do, so quotes or a comment on that line no longer make it
  refuse that very user. The stop messages give the full path of `install.sh` to run, and
  README "Update" says when the panel's update stops. Importing the very same file again after
  a server's profile was deleted outside the kit gives it back its old name, not a hashed one.
- **Upgrading:** "Update the system part" changes nothing on profiles that already have IPv6
  off, unless you set `DISABLE_IPV6=0` under an earlier version (the docs said it gave IPv6
  back; it did nothing). This update acts on it: IPv6 comes back on, and every profile setup
  switched off gets its saved settings back. A profile that had `ipv6.method manual` when 0.3.6
  to 0.4.0 switched it off cannot be (its addresses were never saved): setup names it, leaves
  IPv6 off on it and reports itself as not finished on every run, until you set that profile's
  IPv6 again with `nmcli` (README: "IPv6 and your network profiles"). If you keep your own
  qBittorrent launcher entry, setup now leaves it alone; the kit's entry from 0.4.0 is
  recognised and updated.
- Tests: static checks pass (now also: every root-run script sets its PATH first, and the
  passwordless ones start with `#!/usr/bin/bash`; every command carries the marker and is in
  the uninstaller's list; the launcher helpers survive `set -e`); the marketplace security
  baseline is `review-required` with no findings. VM suite: 682 passed, 0 failed. VM tests added in
  this release: a wired profile with static IPv6 (two addresses, a gateway, two routes, one
  with a metric and the attributes `table` and `onlink`, DNS servers, search domains, a colon
  in its name) is switched off with every field saved, then restored field for field (and
  every other `ipv6.*` setting unchanged) by a forced install rollback, by a rollback after a
  step failed half way, by `install.sh --keep-ipv6`, by the installed `uninstall-root.sh
  --restore-ipv6`, and by the plugin folder's `uninstall.sh --purge --restore-ipv6` after the
  system part is gone; every restore brings IPv6 back on the running link; a profile
  NetworkManager refuses to change is left exactly as it was and not saved; old-format lines
  restore as before, an old-format `manual` line fails loudly and is kept, and one is not taken
  over by a same-named profile; profiles never changed, or turned back on since, are left
  alone; a deleted profile's line is named and put aside; with NetworkManager stopped the saved
  file survives unchanged; a refused reapply, a missing resolver and a unit that cannot be
  enabled do not stop setup, and a failed step leaves no version stamp; a kernel without IPv6
  (simulated) installs and builds the torrent namespace; with `secure_path` switched off and a
  fake of every command first in the caller's PATH, none of the seven passwordless helpers runs
  one as root (a control script without its own PATH does); setup refuses, then with
  `--move-aside` keeps, an admin's own `google-chrome-stable`, and the uninstaller puts it back
  and keeps a file of the user's; the user's qBittorrent and Chrome launcher entries are kept,
  backed up only when asked, and put back; a 0.4.0 command and launcher entry are recognised;
  a profile or config of the user's with the kit's prefix is not deleted, armed for, chosen for
  torrents or overwritten, and a server under an earlier prefix is purged; the leak check does
  not read a root-only file through a symlink or hang on a FIFO; setup run by another user
  changes nothing; the install log is private. The suite also waits for its simulated lookup
  service to listen before using it. Added after the final review: v0.4.0 (from its git tag) is
  installed, imports two servers, is updated to this release through `install.sh` with no
  options, and is uninstalled with `--purge --restore-ipv6`, with nothing refused, no launcher
  left to the user, nothing kept as not the kit's, the 0.4.0 servers deletable, armed for and
  purged, and the user's own qBittorrent entry and IPv6 settings back at the end; setup and
  `vpn-direct` finish when the launcher cache cannot be updated or the qBittorrent entry is a
  dangling link; setup in German does not warn about a `secure_path` sudo has; a quoted
  `TARGET_USER` with a comment is not refused; an existing `~/.cache` keeps its mode; a server
  whose profile was deleted outside the kit gets its name back on the same import.

## 0.4.0 (2026-11-09)

- **New, off until you turn it on: Chrome direct.** Google Chrome keeps your normal connection
  (your own IP) all the time, also while a server is selected; everything else keeps following
  the bar, and qBittorrent keeps its tunnel. For the sites that expect your home address. Turn
  it on with the panel's new switch **Chrome uses your own IP**, or `vpn-direct on` (`off` to
  undo), then close Chrome once so its next start lands in the right place. Chrome runs in a
  system slice that only root can put a process into, started by a new root launcher
  (`direct-launch`); the kill switch lets that slice's packets out, but never its plain DNS
  outside a tunnel. Every normal way to open Chrome lands there: the launcher entry, Omarchy's
  browser shortcut and links from other apps when Chrome is your default browser, and
  `google-chrome-stable` in a terminal. README: "Chrome direct".
- **Chrome stays in its slice.** Chrome asks your user's service manager for a place of its own
  on every start, which would move it out of the slice and onto the VPN. It therefore gets a
  filtered session bus (`xdg-dbus-proxy`, a new prerequisite from the official repositories,
  installed by setup) without that service manager; portals, saved passwords, notifications
  and media keys keep working, Chrome's tray icon is not shown. If the filter cannot start,
  Chrome is not started.
- **Apps Chrome opens follow the bar.** Links handed to other apps, downloads opened from
  Chrome and `mailto:` go through the kit's own `xdg-open`, which starts the app outside
  Chrome's slice.
- **`DIRECT_DNS`, a resolver for Chrome alone.** Empty by default: Chrome uses the system
  resolver, which follows the bar. Set to a loopback address (for example a local ad-blocking
  resolver on `127.0.0.1`), Chrome asks that one only, with a server selected or not. Other
  addresses are refused, and so is a resolver that does not answer when you turn Chrome direct
  on. While the bar says blocked, such a resolver can only answer from its cache if its own
  lookups follow the bar.
- **The status, the panel and the leak check know about it.** While it is on, the panel shows a
  Chrome line and `vpn-status` a `Chrome direct` line; the bar turns the urgent colour when
  something is wrong with it. The leak check proves Chrome leaves from your own address while a
  server is selected, that `DIRECT_DNS` answers and is the only resolver Chrome sees, and names
  every program in Chrome's slice that is not Chrome: a Chrome native-messaging helper is a
  warning, anything else a failure (it uses your own IP too, because Chrome started it).
  Chrome's own start-up processes (the `cat`s its start script keeps) count as Chrome, and the
  bar waits for two polls in a row before it alerts on anything else.
- What you should know before turning it on: sites see your home IP in Chrome; what Chrome
  starts by itself (an extension's helper) shares the exemption; Omarchy web apps go direct too
  when Chrome is your default browser; Tailscale hosts stay reachable from Chrome (the tailnet
  rule is always in place while it is on); do not run a second `wg-quick` tunnel alongside it
  (mark 51821). Like the kill switch, it protects against accidents, not against software
  running as you. Two new passwordless helpers, `vpnkit-direct` (exactly `on`, `off` or
  `status`) and `direct-launch`, are listed in SECURITY.md.
- Also: qBittorrent and Chrome started by the kit get your language, `XDG_DATA_DIRS` and
  input-method settings; the helpers that run through sudo name `/usr/bin/bash` directly;
  `uninstall.sh` finishes your part when the system part reports a failed step.
- **Upgrading:** nothing changes until you turn Chrome direct on; after "Update the system
  part" Chrome follows the bar as before. If you want Chrome on a local resolver, set
  `DIRECT_DNS` in `/etc/vpnkit/vpnkit.conf` first, then turn it on.
- Tests: static checks pass; the marketplace scan is review-required with no findings. VM
  suite: 436 passed, 0 failed. The VM tests cover the slice and its rules, the kill switch's exception
  (present only while on), DNS from the slice, Tailscale's addresses, the launcher's refusals
  (child-program flags, also in `chrome-flags.conf`, Chrome already running outside the slice,
  rules missing, no bus filter), Chrome's private resolver files surviving a host-side rewrite,
  the filtered bus, the kit's `xdg-open`, the status, the leak check's findings, turning it
  off while Chrome runs, and a clean uninstall; most with a stand-in Chrome, and the
  containment with real Google Chrome on a virtual display (still in the slice after a minute,
  a restarted network service too, pages from the home IP, an app it opens on the VPN). The
  panel's new row and switch have not been checked on screen.

## 0.3.7 (2026-11-08)

- **qBittorrent can no longer enter the torrent namespace before its resolver files exist.**
  `qbt-netns-up` gave the tunnel its default route before it wrote `/etc/netns/qbtvpn/resolv.conf`
  and `nsswitch.conf`, and `qbt-launch` only checked for that route. `ip netns exec` bind-mounts
  those files only if they exist when a process enters, and the process keeps that view for its
  whole life. So a qBittorrent started in that window during first-time setup (or after a setup
  that failed there) kept the host's `nsswitch.conf`; on a host using `nss-resolve`, tracker
  lookups reached systemd-resolved over its Unix socket and left through the normal connection.
  Now the files are written, each one complete (temporary file and rename), before the namespace
  even exists, and the build stops if they are not safe; `qbt-launch` and the wrapper refuse
  while they are missing or list `resolve`/`mdns` (the wrapper, inside the namespace, checks the
  `/etc` it actually sees); and the leak check reads the `nsswitch.conf` and `resolv.conf` each
  running qBittorrent sees, so one that entered too early fails it. Reported in the marketplace
  review of 0.3.6.
- Tests: static checks pass, the marketplace security baseline is `review-required` with no
  findings, and the VM suite is 207 of 207. The 9 new VM tests check that the resolver files are
  written before the route and leave no temporary entries in `/etc/netns/qbtvpn`, that `qbt-launch`
  and the wrapper refuse without them or with `resolve` in them (the wrapper also from inside the
  namespace), and that a qBittorrent that entered before they existed fails the leak check.

## 0.3.6 (2026-11-07)

- **IPv6 is now switched off in saved network profiles that carry IPv6 DNS servers.**
  Omarchy's DNS picker (`omarchy dns Cloudflare`) puts IPv6 DNS servers on every wired and
  Wi-Fi profile, and NetworkManager refuses `ipv6.method=disabled` while they are there. The
  installer printed NetworkManager's error and carried on, so the profile kept IPv6 on and could
  turn it back on for that link at its next activation (the running link stayed covered by the
  sysctl). The installer now clears the profile's static IPv6 settings in the same call, warns
  loudly if a profile still cannot be changed, and saves what was there in
  `/etc/vpnkit/ipv6-profiles.saved`, so the install's rollback and `uninstall.sh
  --restore-ipv6` put the IPv6 DNS servers back instead of dropping them. Found on a real
  install.
- **The leak check fails on a global DNS setting.** A NetworkManager `[global-dns]` section or
  `DNS=` in `resolved.conf` (both written by `omarchy dns Cloudflare|Google|Custom`) overrides
  the VPN's DNS: lookups went to that provider instead of the server's resolver. They stayed
  inside the tunnel, so the home IP never showed, but the VPN's resolver (and Proton's
  NetShield) went unused, and leak test sites showed the other provider. The check now names
  global DNS servers, and flags any that is routed outside the VPN as a DNS leak; the
  installer warns about them. New README section: "DNS and Omarchy's DNS setting".
- Tests: static checks pass (now with a `.private-patterns` file), the marketplace security
  baseline is `review-required` with no findings, and the VM suite is 198 of 198. The new VM
  tests put an IPv6 DNS server on the physical profile before installing (as Omarchy's DNS
  picker leaves it) and check it is disabled, saved and restored on uninstall, and set a global
  DNS server and check that the leak check fails and names it.

## 0.3.5 (2026-10-14)

- **The 0.3.4 guard also covers `qbittorrent-nox`.** The GUI and `qbittorrent-nox` share the
  default profile and its socket file, so a `qbittorrent-nox` running outside the tunnel was
  handed magnet links from the protected launcher just like an outside GUI. The wrapper and
  `qbt-launch` now refuse while either runs outside the namespace. Reported in the
  marketplace review of 0.3.4.
- Tests: static checks pass, the marketplace security baseline is `review-required` with no
  findings, and the VM suite is 187 of 187 (two runs). The two new VM tests start qBittorrent
  while a stand-in `qbittorrent-nox` runs outside the namespace, and both fail without this fix.

## 0.3.4 (2026-10-13)

- **qBittorrent no longer starts while another one runs outside the tunnel.** A qBittorrent
  started as `/usr/bin/qbittorrent` (skipping the wrapper) runs on the regular connection, and
  a second qBittorrent of the same user hands every torrent and magnet link it is asked to open
  to that running one, over a socket file that a network namespace does not isolate. So
  opening a magnet link went to the instance outside the tunnel, even though the new process
  was started inside it. The wrapper and `qbt-launch` now refuse to start while a qBittorrent
  of the desktop user is running outside the namespace, and say which process to close. This
  was already reported as `TORRENT LEAK` in the bar; now it also cannot be fed new torrents.
  Reported in the marketplace review of 0.3.3.
- Tests: static checks pass, the marketplace security baseline is `review-required` with no
  findings, and the VM suite is 185 of 185. Four new VM tests start qBittorrent while one runs
  outside the namespace (through the wrapper, through `qbt-launch`, and through the wrapper from
  inside the namespace) and all four fail without this fix. The VM uses a stand-in binary, so
  qBittorrent's own handover between instances is not exercised there.

## 0.3.3 (2026-10-09)

- **No more false "VPN dropped" alarm when you switch servers or go back to your own
  connection.** The panel reported a drop whenever a server was selected while no tunnel was
  up, which is also true for a moment during every switch: the kill switch is armed before a
  profile connects and removed only after it disconnects, so a poll landing in that second saw
  "wanted but not connected". With the default five-second refresh that was easy to hit, and
  the result was a critical notification that got through Do Not Disturb and offered to hand a
  problem that no longer existed to an AI agent. The bar and the panel still show the live
  state at once; only the notification now waits for the state to hold still (two polls plus a
  margin) and is dropped if it clears on its own. The same wait applies to "Torrent tunnel
  down", which flickered while the torrent server was being switched. qBittorrent outside its
  tunnel is still reported the instant it is seen, with no delay. Whatever is already wrong
  when the panel starts is shown but not announced, as before.
- The panel header no longer says "Traffic blocked" while a switch is running; it keeps the
  server name with "Switching" underneath, and "Troubleshoot with AI" appears once a problem
  has settled instead of blinking in and out during a switch.
- **"Troubleshoot with AI" is honest about when the alert was raised.** A critical notification
  stays on screen until it is clicked, so the sentence it carries can be hours old.
  `vpn-diagnose` now labels it as what the panel reported at the time, next to the live
  `vpn-status --json`, and asks the agent to say so if the two disagree. The `diagnose-vpn`
  skill starts by comparing them, and documents how to tell a real drop from a deliberate
  *Normal connection* in the NetworkManager journal, and that a server which is up but silent
  shows as connected with an unknown IP rather than as blocked.
- Tests: static checks pass, the marketplace security baseline is `review-required` with no
  findings, and the VM suite is 181 of 181. The panel's QML is not covered by the VM, so the
  notification timing was reasoned through and checked with `qmllint`, not exercised there.

## 0.3.2 (2026-10-02)

- **One line to install.** The top of the README now has a single copy-ready line that adds
  the widget and then runs the system setup in the same terminal:
  `omarchy plugin add https://github.com/ralphk-86/omarchy-proton.git --enable && ~/.config/omarchy/plugins/io.github.ralphk-86.omarchy-proton/install.sh`.
  The two-step way (add the widget, then **Finish setup** in its panel) still works and is
  described next to it. The marketplace lists the plugin as *Manual setup* and shows no
  install button, so the README is where people copy it from.
- **New display name: Proton VPN + Kill Switch + Torrent Tunnel**, in Omarchy, the marketplace
  and the README, so it says what it does. Still unofficial and not affiliated with Proton AG;
  the description now starts with "Unofficial". The
  plugin id (`io.github.ralphk-86.omarchy-proton`), the repository and every command stay the
  same, so updates work as before.
- **A lock in the bar.** A closed lock means your regular traffic goes through a server with
  the kill switch on; the globe means your own connection. A VPN up without its kill switch
  shows an open lock in the urgent colour. The panel header uses the same icon.
- **Show IP addresses in the bar** is now a row at the bottom of the panel, with a switch.
  Off leaves only the lock (or globe) and the torrent icon. The setting is saved in the
  widget's entry in `shell.json`, as before.
- **Deeper leak checks for the desktop VPN.** With a server selected the check now also
  proves that the server answered with a recent handshake (NetworkManager keeps showing a
  WireGuard profile as connected when the server stopped answering or the key was revoked),
  that every DNS server the machine would ask is routed into the tunnel, and that the physical
  interface cannot answer DNS questions. With IPv6 kept on (`--keep-ipv6`) it now tests that
  IPv6 cannot get out instead of only noting it.
- **Saved leak-check reports.** Every check, from the panel or the new `vpn-check` command, is
  saved as a text file in **Documents > VPN leak checks**: a header (date, version, selected
  servers, kill switch), every check, the result. The newest 20 are kept, `latest.txt` is the
  most recent, and `latest-redacted.txt` masks public IP addresses, MAC addresses, home paths
  and anything key-like for sharing. The folder icon on **Check for leaks** opens the folder;
  "Troubleshoot with AI" hands the agent the newest report. `uninstall.sh --purge` deletes the
  reports; a plain uninstall keeps them. No new root helper and no new sudo rule: `vpn-check`
  runs as you and calls `vpn-verify` through its existing rule.
- README: what the leak check looks at, the reports folder, and a note on WebRTC.
- **Marketplace preview and description.** `preview.png` is now a 3200x1800 landscape image:
  a large title and four short features next to the bar and a shortened panel, all drawn with
  the widget's own font, glyphs and colours (checked against a capture), so it is sharp on
  high-density screens and survives the marketplace card's centre crop. The full-height panel
  screenshots stay in the README (`screenshots/regular.png`, `screenshots/torrents.png`), with
  a new `screenshots/bar-states.png` of the bar in four states. `tests/preview/make-preview.sh`
  makes them. The description now opens with the features ("Proton VPN kill switch, torrent
  tunnel & leak checks in the bar.") and mentions the leak check, so a search for "leak"
  finds it.
- The system part changed (`vpn-verify`, `vpn-check`, `vpn-status`, `vpn-diagnose`, the
  shared library, the uninstaller): after updating, click **Update the system part**. Until
  then the panel's check works the old way. VM suite: 181 of 181 (the leak check inside it: 32 passed,
  0 failed, 2 skipped).

## 0.3.1 (2026-09-30)

- Every HTTP body the kit reads (the external-IP lookups, some of them in root helpers) is
  now capped at 256 bytes with curl's `--max-filesize`, which also aborts a stream of unknown
  size. A hostile or broken lookup server can no longer make `qbt-netns-status`, `vpn-status`,
  `vpn-verify`, `vpn-rescue` or the installer buffer an unbounded response. Raised by the
  marketplace review (omacom/omarchy-plugin-marketplace#9451). VM suite: 153 of 153.

## 0.3.0 (2026-09-30)

- **Regular traffic / Torrents** switch in the panel over one server list: pick where your
  apps go and which server qBittorrent uses. The server used by the other tab is greyed and
  labelled.
- **Import from files:** the standard file dialog, for configs in any folder. The drop folder
  stays the easiest way to add several.
- **Notifications** when the VPN drops and the kill switch starts blocking, when the torrent
  tunnel goes down, and if qBittorrent is found outside its tunnel.
- The kill switch has no off setting any more: a selected server always means through the
  tunnel or not at all. The panel says so under the tabs.
- **Troubleshoot with AI**, the way Omarchy offers it for crashed programs: a failed leak
  check, a dropped VPN, a torrent tunnel that is down or a stray qBittorrent raises a
  notification that opens your default AI agent with the facts, and the panel shows a
  *Troubleshoot with AI* row. The agent follows a shipped `diagnose-vpn` skill: read-only
  first, asks before any change, never prints keys or weakens the kill switch.
  `vpn-diagnose` runs it by hand.
- A failed leak check now also sends a notification.
- The torrent namespace's firewall is loaded before its tunnel interface exists, so there is
  never a moment without it.
- Clear about interfaces: the README has a table of which interface carries what, and the
  Torrents tab says that only qBittorrent uses the torrent tunnel (`pqbt0`, inside the
  namespace). Other torrent apps (Transmission, Deluge, qbittorrent-nox, ...) found running
  outside the tunnel raise a warning in the bar and panel, and fail the leak check. Under the
  tabs the panel shows the interface each kind of traffic uses (with a copy button).
- README rewritten around the tabs, the two ways to import, and the always-on kill switch.

## 0.2.0 (2026-09-30)

- Any server can carry torrents: choose it under **Torrents** in the panel or with
  `vpnkit-sync torrent <server>`. One config is never used for regular traffic and torrents at
  the same time; the panel greys out the one in use on the other side. A config in `torrent/`
  is imported as a server and chosen for torrents. An existing torrent config becomes a server
  on update.
- **Finish setup** runs in a visible Omarchy terminal.
- The leak check covers qBittorrent's interface setting and any launcher that skips the
  wrapper.
- README: quick start, "What you choose", "How to use it", Tailscale, security and privacy;
  issue and PR templates, RELEASING.md.
- VM suite: 139 passed, 0 failed.

## 0.1.0 (2026-09-30)

First version, extracted from a private setup and a Fedora/KDE predecessor.

- Bar widget: external IP of regular traffic and of the torrent tunnel; panel to switch server,
  import configs, delete servers and run the leak check.
- Drop folder (`~/Documents/WireGuard`): configs are imported on Refresh and removed from the
  folder afterwards.
- Kill switch for the desktop VPN, armed when a server is picked and removed only by "Normal
  connection".
- qBittorrent confined to a network namespace with its own WireGuard tunnel.
- `vpn-status`, `vpn-toggle`, `vpn-import`, `vpn-verify`, `vpn-rescue` on the command line.
