# Firefox tunnel: design

Status: approved by the owner, 2026-11-09.

## Intent

The user wants two browsers with two different jobs:

- **Firefox** for private browsing: always through a VPN, from boot, and never on the home IP,
  even when a tunnel drops.
- **Chrome** (the Omarchy default browser) on the normal connection, for sites that expect
  the home IP and for the Claude browser extension.

Today the only way to put Firefox on a VPN is the desktop VPN, which moves the whole machine.
Every switch, toggle or reconnect changes the public IP and cuts every open connection,
including long-lived ones such as an AI coding agent's API stream. That is what prompted this
request. The plugin already solves the same problem for qBittorrent with an always-on tunnel in
a network namespace. This adds a second, independent one for Firefox, built the same way.

## Goals

1. Firefox runs only inside its own network namespace, whose only way out is its own WireGuard
   tunnel. No tunnel, no network (including DNS), by construction, as for qBittorrent.
2. The tunnel comes up at boot without anyone clicking anything, and is independent of the
   desktop VPN and of the torrent tunnel. Toggling or switching the desktop VPN never touches it.
3. Every normal way to start Firefox lands in the namespace: the launcher entry and its
   actions (new window, private window), typing `firefox` in a terminal, and a link opened from
   another app when Firefox is the chosen handler.
4. Firefox has its own server and key, separate from the torrent tunnel, so websites cannot
   link browsing to the torrent IP. (Proton drops both connections when one key is used twice.)
5. The bar and panel show Firefox's tunnel IP and state next to the torrent tunnel's; the leak
   check covers it.
6. Fail closed, with a clear message: a missing namespace, missing resolver files, no route, or
   a Firefox already running outside the namespace means Firefox is refused, never started on
   the normal connection.

## Non-goals

- Chrome or any other browser. Chrome stays on the normal connection, unchanged.
- Making Firefox the default browser. Links from other apps keep opening in Chrome unless the
  user changes the default themselves.
- Choosing or switching Firefox's server from the bar in this first version. The server is
  chosen at import time, like the torrent server (see "Left to the builder").
- Ad blocking. Firefox gets uBlock Origin from its add-on store and Proton's NetShield through
  the config the user downloads; neither is part of this plugin.
- Other apps in the Firefox namespace. One app per tunnel.

## Anti-goals (would be a failure even if it worked)

- Firefox ever reaching the network outside its tunnel, including DNS through
  systemd-resolved's Unix socket, Firefox's own DNS-over-HTTPS going out another way, or WebRTC
  exposing the home IP.
- A Firefox started outside the namespace (for example before the install, or via
  `/usr/lib/firefox/firefox` directly) silently receiving URLs from the protected launcher. That
  is the same remoting trap the qBittorrent guard closes.
- Weakening anything that protects the torrent tunnel or the desktop kill switch.
- New passwordless root helpers that take paths, or arguments that reach anything but Firefox.

## Constraints

- Everything in the repository's `CLAUDE.md`: public repo, no personal data, nothing downloaded
  is executed, root helpers take no paths and validate every argument, user config is not
  overwritten without a flag, network changes are tested in the VM, never on the developer's
  machine.
- Each new passwordless sudo rule gets a row in `SECURITY.md` and a suite test showing it cannot
  be abused.
- Packages only from the official repositories (Firefox is in `extra`).
- The torrent tunnel's behaviour, names and files do not change for existing users.

## Decided

- **Model:** a per-app namespace for Firefox, not "whole machine on VPN with Chrome exempt".
  Decided by the user, who picked it over a desktop VPN with exemptions because exemptions put
  holes in the kill switch and the desktop VPN still cuts open connections.
- **Own config:** Firefox uses its own WireGuard config, not the torrent tunnel's. Decided by
  the user.
- **Default:** the Firefox tunnel is on from boot, like the torrent tunnel. The desktop VPN keeps
  its current default (off after reboot).
- **Same mechanics as the torrent tunnel:** resolver files (`resolv.conf` and an
  `nsswitch.conf` without `resolve`/`mdns`) written before the namespace has a route, an
  in-namespace nftables default-deny allowing only `lo` and the tunnel interface, the WireGuard
  socket left in the root namespace with `VPN_FWMARK` so the desktop VPN never wraps it, IPv6
  off inside the namespace when `DISABLE_IPV6=1`, a oneshot systemd unit with
  `Restart=on-failure`, a PATH wrapper in `/usr/local/bin`, a root launcher that hardcodes the
  binary and drops to the desktop user before exec, and a desktop file override.
- **Drop folder:** a `firefox/` subfolder of the drop folder, next to `torrent/`, imported by
  `vpnkit-sync` the same way.

## Opt-in (settled by the designer, not the user)

Firefox is a common browser, so the Firefox tunnel is **off until the user turns it on**. An
update must never start refusing Firefox for a plugin user who has not set the tunnel up.

- Installing or updating the plugin changes nothing for Firefox. The `firefox` PATH wrapper,
  the desktop file override and the boot unit take effect only once a Firefox config has been
  imported from the `firefox/` drop folder (the import is the consent).
- From that moment on, Goal 6 applies in full: no namespace, no Firefox.
- Turning it off is a supported action without uninstalling the plugin (for example
  `vpnkit-sync firefox off`, validated like the other `vpnkit-sync` verbs): it removes the
  wrapper's effect, the override and the unit, and deletes the imported config. Uninstalling
  the plugin does the same.
- README and CHANGELOG say this plainly for upgraders.

## Separate exit (settled by the designer, not the user)

"Its own server" means a different exit, not only a different key, because the point is that
websites cannot link browsing to the torrent IP.

- Import refuses a Firefox config whose endpoint (host and port) matches the torrent tunnel's,
  and the torrent import refuses the reverse. It also refuses a key already used by either
  tunnel or any desktop profile.
- The leak check fails if the Firefox tunnel and the torrent tunnel show the same external IP
  (one server can sit behind several endpoints).

## What the namespace means for Firefox (to put in the README)

Inside the namespace Firefox sees only the tunnel. So these do not work from Firefox, by
design, and Chrome is the browser for them: `localhost` and other services on this machine
(local dev servers), the local network (router and printer pages), and Tailscale hosts.
WebRTC can only see the tunnel address. The Wayland and D-Bus sockets are filesystem sockets,
so the window, clipboard, file dialogs, audio and notifications work as normal.

## Left to the builder

- **Shared code or a copy.** Whether the torrent namespace scripts become one parameterised set
  (a fixed allowlist of tunnel names, never a caller-supplied path) or Firefox gets its own
  copies. A shared set is preferred if it does not change the torrent tunnel's files, unit name,
  or behaviour.
- **Names.** Namespace, interface, config path, unit name and `vpnkit.conf` keys, following the
  existing `NS`/`WG_IF`/`QBT_CONF` pattern and kept configurable.
- **Firefox remoting.** How to detect a Firefox of the user running outside the namespace
  (process namespace inode, as `vpnkit_qbt_outside_pids` does) and what to do about
  remote-instance handover inside the namespace.
- **Firefox's own DNS-over-HTTPS.** It cannot leak (the namespace has only the tunnel), but it
  would bypass the tunnel's resolver and NetShield. Whether to switch it off with a Firefox
  enterprise policy, and if so how without overwriting a user's existing `policies.json`.
- **The bar.** How the Firefox tunnel appears in the widget and the panel, following the
  torrent tunnel's existing display.
- **Choosing the server.** Import-time selection like `vpnkit-sync torrent <name>`, extended
  with a Firefox equivalent; a picker in the panel can come later.
- **Tests.** Static checks, suite, and VM tests mirroring the torrent tunnel's, plus a VM test
  that Firefox inside the namespace cannot reach the host's resolver or a LAN address.

## Rollout on the user's machine

After the release: the user downloads one more Proton WireGuard config (GNU/Linux, with
NetShield set to block ads, trackers and malware), puts it in the drop folder's `firefox/`
subfolder, and clicks "Update the system part" in the panel (or runs `install.sh` in a
terminal). Agents cannot run the root half.
