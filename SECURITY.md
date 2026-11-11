# Security

This plugin installs helpers that run as root and a firewall rule set. Problems in it matter.

## Reporting

Please report a vulnerability privately through GitHub's
[private vulnerability reporting](https://github.com/ralphk-86/omarchy-proton/security/advisories/new)
rather than in a public issue. Include the version (`cat /usr/local/lib/vpnkit/VERSION`), what
you observed and how to reproduce it. Do not include private keys or your WireGuard configs.

A leak is a vulnerability here: traffic that leaves outside a tunnel while a server is
selected, DNS answered outside the tunnel, or a qBittorrent process that reaches the network
outside its namespace.

## What runs as root

- `system/install-root.sh` and `system/uninstall-root.sh`, once each, when you run setup or
  the uninstaller and enter your password. Both save and restore the IPv6 settings of your
  network profiles through the same code, `system/lib/ipv6.sh` (installed to
  `/usr/local/lib/vpnkit/ipv6.sh`; the uninstaller uses the copy next to it). Both decide what
  is the kit's through `system/lib/owned.sh`: commands in `/usr/local/bin` by a marker line
  (or, for those of 0.3.0 to 0.4.0, by checksum: `system/lib/released-bin.sha256`; setup replaces a file without it only with `--move-aside`, keeping it aside; the
  uninstaller deletes only marked files and puts kept ones back), servers by the uuid
  `vpnkit-import` gives them, launcher entries in your home folder by a marker line, and
  those are handled as you (`runuser`), never as root. Setup stops before changing anything
  when it is run by a user other than the one the kit is set up for.
- Eight helpers the desktop user may run through `sudo` without a password
  (`/etc/sudoers.d/99-vpnkit`):

| Helper | Arguments | What it can do |
|---|---|---|
| `qbt-netns-status` | none allowed | read the namespace and kill switch state, and Chrome direct's: its unit and rules, which programs run in its slice (it reads Chrome's native-messaging manifests in `/etc/opt/chrome` as root and the ones in your home folder with your permissions), and whether Chrome's resolver files still name `DIRECT_DNS` only (read through `/proc/<pid>/root`, nothing is run there); it writes only its own caches in `/run`, including whether `DIRECT_DNS` answered (asked at most every 30 s) |
| `qbt-launch` | passed to qBittorrent only | start `/usr/bin/qbittorrent` inside the namespace, as the desktop user; refuses while the tunnel is down or a qBittorrent (GUI or `qbittorrent-nox`) of that user runs outside the namespace |
| `ff-launch` | passed to Firefox only | start `/usr/lib/firefox/firefox` inside the Firefox namespace, as the desktop user (`runuser` before exec); refuses while the tunnel is off (no Firefox config) or down, the namespace's resolver files are missing or unsafe, `FF_NS` names the torrent namespace, or a Firefox of that user runs outside the namespace. Whatever the arguments make Firefox do, it does as you, with only the tunnel for network |
| `vpnkit-killswitch` | `on <profile>`, `off`, `status`; validated | load or remove one nftables table |
| `vpnkit-sync` | `sync`, `torrent <name>`, `firefox <name>`, `firefox off`, `remove <name>`; validated | import configs from the fixed drop folder, choose the torrent server, choose the Firefox server (which turns the Firefox tunnel on: its fixed config file, record and unit) or turn that tunnel off, delete a server; `torrent`, `firefox` and `remove` act only on a server the kit imported (its uuid), never on a WireGuard profile or config of yours with the same prefix, and an import never overwrites one. A server serves one of regular traffic, torrents and Firefox at a time, and the torrent and Firefox tunnels never share an endpoint or a key; an import refuses a config with either tunnel's key. Choosing a Firefox server or turning that tunnel off also updates your Firefox launcher entry (`vpn-firefox-launcher`, run as you through `runuser`, never as root) |
| `vpnkit-direct` | exactly `on`, `off` or `status` | turn Chrome direct on or off (start or stop `vpnkit-direct.service`, write or delete `/etc/vpnkit/direct-apps`, re-arm the kill switch for the same server), or read its state; `on` refuses a `DIRECT_DNS` outside 127.0.0.0/8 or one that does not answer, `off` refuses while anything runs in its slice |
| `direct-launch` | passed to Chrome only; refuses `--*-cmd-prefix`, `--*-launcher` and `--browser-subprocess-path`, also in `~/.config/chrome-flags.conf` (read as the desktop user); refuses that file when it is over 64 KiB, cannot be read or times out, or has a wildcard word (`*`, `?`, `[`: Chrome's start script expands those). The file check is best-effort against software running as you: Chrome's start script reads the file again at launch | start `/usr/bin/google-chrome-stable` as the desktop user in `vpnkitdirect.slice` (the normal connection) and, with `DIRECT_DNS` set, in a private mount namespace whose resolver files name `DIRECT_DNS` only; Chrome gets a filtered session bus (`xdg-dbus-proxy`, started as the desktop user outside the slice, socket in the user's runtime folder) without the user's service manager, and a `PATH` that starts with the kit's `xdg-open` (`/usr/local/lib/vpnkit/direct-bin`); refuses while Chrome direct is off, its unit is not active or its rules are not loaded, while a Chrome of that user runs outside the slice, and when the bus filter or the kit's `xdg-open` is missing or the filter does not start |
| `vpn-verify` | none allowed | the read-only leak check; with Chrome direct on it also starts one `curl` in `vpnkitdirect.slice` as the desktop user, to see where it exits. Files in your home folder (qBittorrent's settings, launcher and autostart entries, Hyprland config) are read with your permissions, size- and time-capped; a running qBittorrent's resolver files with that process owner's |

None of them takes a path from the caller. Files in the drop folder are read with the desktop
user's permissions, not root's. The helpers are installed root-owned in `/usr/local/bin`.

**The environment is not trusted either.** With `env_reset`, sudo replaces the caller's `PATH`
only when sudoers sets `secure_path`; without it (an older or edited `/etc/sudoers`) the
caller's `PATH` reaches root. So every script that runs as root, the eight above and
everything they, systemd or NetworkManager start (`vpnkit-import`, `vpnkit-direct-rules`,
`qbt-netns-up`, `qbt-netns-down`, `ff-netns-up`, `ff-netns-down`, the dispatcher hook, setup and the uninstaller), sets
`PATH=/usr/local/sbin:/usr/local/bin:/usr/bin` before it runs any command; `tests/check.sh`
fails otherwise. As root, the settings folder is always `/etc/vpnkit`, whatever the
environment says. Setup warns (and changes nothing) when sudo has no `secure_path`, because
other sudo rules on the machine may depend on it. The VM suite switches `secure_path` off,
puts a fake of every command in `/usr/bin` first in the caller's `PATH`, and checks that none
of the eight helpers runs one as root, against a control script without its own `PATH` that
does.

## Troubleshoot with AI

`vpn-diagnose` runs as you, never as root, and only when you click *Troubleshoot with AI* or
run it. It starts your Omarchy default agent with the problem, the `vpn-status` output (which
includes your external IPs and server names) and the failing lines of the last leak check, so
that information goes to whichever AI service your agent uses. Private keys are never part of
it, and the `diagnose-vpn` skill tells the agent not to read them, not to weaken the kill
switch, and to ask before running anything that changes the system. Omarchy starts agents in
their unattended mode, so the skill's rules are guidance to the agent, not a sandbox.

## Scope and limits

Chrome direct (off unless you turn it on) is a deliberate hole in the kill switch for one app:
whatever runs in `vpnkitdirect.slice` leaves on the normal connection. Only root can put a
process there, and only two helpers do: `direct-launch` (Chrome) and `vpn-verify` (its one
`curl` probe, which ends within 20 s and which the status leaves out of what it counts).

- **Leaving the slice is possible, but only towards the VPN.** Any process of yours in it can
  ask your user's service manager to move it into a scope of its own, and the system allows
  that for your own processes. Chrome does so on every start, so it gets a filtered session
  bus (`xdg-dbus-proxy --filter`) on which `org.freedesktop.systemd1` does not exist; it can
  still reach the portals, the secret service, notifications, the screen saver, the file
  manager, accessibility, the tray's watcher, dconf, GVfs and its media-key name, and nothing
  else. Other ways to the service manager (its private socket, the real bus socket's path) are
  not blocked; a process that takes them lands on the VPN, and a Chrome that did so shows in
  the status as outside the slice. Entering the slice needs root.
- **Apps Chrome opens through `xdg-open`** (links to other apps, downloads it opens,
  `mailto:` and other protocols) run the kit's `xdg-open`, first in Chrome's `PATH`, which
  starts the app with `systemd-run --user --scope` outside the slice, on the real session
  bus. If that scope cannot be made, nothing is opened.
- **What Chrome starts directly still inherits the exemption** (an extension's
  native-messaging helper, anything an extension or a flag makes it run), and software
  running as you can ask Chrome to start things. Refusing the flags above, on the command line
  and in `chrome-flags.conf`, keeps accidents out; the `chrome-flags.conf` check is
  best-effort (Chrome's start script reads the file again), and none of it is a wall against
  your own software.

See "Limits" in the README. In short: the kill switch protects against accidents, not against
software running as you, and the external-IP display makes a request to a third party.
