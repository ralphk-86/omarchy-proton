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
  the uninstaller and enter your password.
- Seven helpers the desktop user may run through `sudo` without a password
  (`/etc/sudoers.d/99-vpnkit`):

| Helper | Arguments | What it can do |
|---|---|---|
| `qbt-netns-status` | none allowed | read the namespace and kill switch state, and Chrome direct's: its unit and rules, which programs run in its slice (it reads Chrome's native-messaging manifests in `/etc/opt/chrome` as root and the ones in your home folder with your permissions), and whether Chrome's resolver files still name `DIRECT_DNS` only (read through `/proc/<pid>/root`, nothing is run there); it writes only its own caches in `/run`, including whether `DIRECT_DNS` answered (asked at most every 30 s) |
| `qbt-launch` | passed to qBittorrent only | start `/usr/bin/qbittorrent` inside the namespace, as the desktop user; refuses while the tunnel is down or a qBittorrent (GUI or `qbittorrent-nox`) of that user runs outside the namespace |
| `vpnkit-killswitch` | `on <profile>`, `off`, `status`; validated | load or remove one nftables table |
| `vpnkit-sync` | `sync`, `torrent <name>`, `remove <name>`; validated | import configs from the fixed drop folder, choose the torrent server, delete a server |
| `vpnkit-direct` | exactly `on`, `off` or `status` | turn Chrome direct on or off (start or stop `vpnkit-direct.service`, write or delete `/etc/vpnkit/direct-apps`, re-arm the kill switch for the same server), or read its state; `on` refuses a `DIRECT_DNS` outside 127.0.0.0/8 or one that does not answer, `off` refuses while anything runs in its slice |
| `direct-launch` | passed to Chrome only; refuses `--*-cmd-prefix`, `--*-launcher` and `--browser-subprocess-path`, also in `~/.config/chrome-flags.conf` (read as the desktop user); refuses that file when it is over 64 KiB, cannot be read or times out, or has a wildcard word (`*`, `?`, `[`: Chrome's start script expands those). The file check is best-effort against software running as you: Chrome's start script reads the file again at launch | start `/usr/bin/google-chrome-stable` as the desktop user in `vpnkitdirect.slice` (the normal connection) and, with `DIRECT_DNS` set, in a private mount namespace whose resolver files name `DIRECT_DNS` only; refuses while Chrome direct is off or its unit is not active, and while a Chrome of that user runs outside the slice |
| `vpn-verify` | none allowed | the read-only leak check; with Chrome direct on it also starts one `curl` in `vpnkitdirect.slice` as the desktop user, to see where it exits |

None of them takes a path from the caller. Files in the drop folder are read with the desktop
user's permissions, not root's. The helpers are installed root-owned in `/usr/local/bin`.

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
process there, and only `direct-launch` does. But anything Chrome itself starts inherits the
exemption (a file opened from a download, a native-messaging helper, an extension's helper),
and software running as you can ask Chrome to start things. Refusing the flags above keeps
accidents out; it is not a wall against your own software.

See "Limits" in the README. In short: the kill switch protects against accidents, not against
software running as you, and the external-IP display makes a request to a third party.
