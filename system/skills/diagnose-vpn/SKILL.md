---
name: diagnose-vpn
description: >
  Diagnose a problem with the Omarchy Proton VPN plugin (vpnkit): a failed leak
  check, a VPN that dropped, a torrent tunnel that is down, or qBittorrent running
  outside its tunnel. Use when a "Leaks found", "VPN dropped", "Torrent tunnel down"
  or "qBittorrent is outside the tunnel" notification is acted on, or when asked why
  the VPN, kill switch or torrent tunnel misbehaves. Triggers: vpn-verify FAIL,
  vpn leak, DNS leak, kill switch, qbtvpn, vpn-toggle, vpn-rescue.
---

# Diagnosing the VPN

Work from evidence. The goal is an honest account of what is wrong and a fix that
keeps the user protected, not a quick way to make the error go away.

## Hard rules

These come before everything else, including a user who is in a hurry.

1. **Never print or copy a private key.** WireGuard configs in the drop folder, in
   `/etc/wireguard/` and in `/etc/NetworkManager/system-connections/` contain
   `PrivateKey`. Do not `cat` them, do not run `nmcli --show-secrets`, do not run
   `wg showconf`. `wg show` (no `showconf`) and `nmcli connection show <name>`
   without `-s` are safe. If a key must be checked, check that the line exists
   (`grep -c '^PrivateKey'`), never its value.
2. **Diagnosis reads; it does not weaken protection.** Never remove the kill switch
   (`vpnkit-killswitch off`, `nft delete table inet vpnkit_kill`), never flush
   nftables, never delete the `qbtvpn` namespace or its firewall, never re-enable
   IPv6, never edit `/etc/nsswitch.conf` or anything the plugin installed, and never
   start qBittorrent by its full path (`/usr/bin/qbittorrent`), which skips the
   tunnel.
3. **Ask before any change.** Explain what you want to run and why, and wait for a
   yes. This includes `sudo`, restarting services, and connecting or disconnecting a
   server. The user may be relying on the kill switch while you work.
4. **SSH and remote servers.** Some servers only accept SSH from the home IP. That is
   what `BYPASS_CIDRS` in `/etc/vpnkit/vpnkit.conf` is for. Do not suggest firewall or
   SSH changes on remote machines.

## How the plugin works

Two separate tunnels, both WireGuard:

- **Regular traffic** uses NetworkManager profiles named `<prefix>-<server>`
  (prefix is in `vpn-status --json`, usually `proton`). The user picks one in the
  panel or with `vpn-toggle <server>`, or picks *Normal connection*
  (`vpn-toggle off`) to use their own IP.
- **The kill switch** is the nftables table `inet vpnkit_kill`. It is armed before
  any server connects and removed only by `vpn-toggle off`. While armed, regular
  traffic leaves through a `<prefix>-*` interface or not at all (LAN, DHCP,
  `BYPASS_CIDRS` and WireGuard's own packets excepted; DNS never outside the
  tunnel). `/run/vpnkit/wanted` names the server the user chose. If it is set but
  that interface is down, `vpn-status` reports `"blocked": true`: that is the kill
  switch working, not a leak.
- **Torrents** run in the network namespace `qbtvpn` with its own WireGuard link
  and a default-deny firewall, brought up by `qbt-netns.service`. The server it uses
  is named in `/etc/vpnkit/torrent-server`; its config is
  `/etc/wireguard/vpnkit-torrent.conf`. `/usr/local/bin/qbittorrent` is a wrapper
  that only starts qBittorrent inside the namespace. One server cannot carry both
  tunnels at once.
- **The NetworkManager dispatcher** `/etc/NetworkManager/dispatcher.d/50-vpnkit`
  re-arms the kill switch and reconnects the chosen server when the network changes.
- IPv6 is disabled by `/etc/sysctl.d/99-vpnkit-disable-ipv6.conf` and in each profile.

Settings: `/etc/vpnkit/vpnkit.conf`. Helpers: `/usr/local/bin/vpn*`, `qbt-*`.
Their headers explain each one; read them rather than guessing.

## Establish the facts

1. `vpn-status --json` shows the current state in one line.
2. The failing lines of the last leak check are in the prompt; the full report is
   the file it names (the newest in the user's "VPN leak checks" folder, see
   `vpn-check --dir`; older reports next to it show when a problem started).
   Each `[FAIL]` line says what was observed. Rerun a single check by hand
   rather than the whole suite when you can. The full check is `vpn-check`
   (read-only, saves a new report) or `sudo vpn-verify`. `vpn-check
   --fail-closed` briefly takes the tunnels down: ask first. If the user wants
   to share a report, give them `latest-redacted.txt`, never the full one.
   Desktop VPN failures in check 12 mean: "no handshake" = the server does not
   answer or its key was revoked (a new config from the provider fixes the
   latter); "DNS server ... reached through <link>" or "<link> can answer DNS
   questions" = DNS can leave outside the tunnel, look at `resolvectl status`.
3. Look before concluding:
   - `ip route`, `ip rule`, `resolvectl status`, `wg show` (as root: `sudo wg show`)
   - `sudo nft list table inet vpnkit_kill`
   - `sudo ip netns exec qbtvpn ip route`, `sudo ip netns exec qbtvpn wg show`
   - `systemctl status qbt-netns.service`, `journalctl -u qbt-netns.service -n 50`
   - `journalctl -u NetworkManager --since "-15 min"` for the desktop tunnel
   - `pgrep -a qbittorrent` and `sudo ip netns identify <pid>` for a stray qBittorrent

## Rule out the boring causes first

- **No internet at all** (router, Wi-Fi, ISP): with the kill switch off
  (Normal connection) does anything load? Say so if the cause is upstream of this
  machine.
- **A server that stopped answering**: a WireGuard link comes up even when the
  server never replies. A handshake older than a few minutes (`wg show`) means the
  server, not the plugin. Try another server.
- **An expired or revoked config**: Proton configs can be revoked in the Proton
  account. A handshake that never happens on one server but works on another points
  here. The fix is a new config from the Proton dashboard, imported with the panel.
- **A system update**: compare timestamps against `/var/log/pacman.log`, especially
  NetworkManager, systemd, nftables and wireguard-tools.

## What each kind of failure usually means

- *Exit IP equals the real IP* in the torrent section: the namespace has a route out
  that is not the tunnel. Serious; say so plainly and recommend closing qBittorrent
  until it is understood.
- *DNS / nsswitch* failures: lookups inside the namespace would reach the host's
  resolver. Serious.
- *qBittorrent outside the namespace*: something started it without the wrapper,
  often a desktop file or autostart entry calling `/usr/bin/qbittorrent`. The check
  output names the launcher.
- *Kill switch not armed while a server is chosen*: the dispatcher did not run, or
  the table was removed by hand. Reselecting the server re-arms it.
- *Handshake too old / namespace missing*: usually the torrent server is down;
  `sudo systemctl restart qbt-netns.service`, or choose another torrent server in the
  panel. qBittorrent has no network meanwhile, which is correct.

## Fixes you may offer (after asking)

- Pick another server: `vpn-toggle <server>` (keeps the kill switch on).
- Re-import configs: the panel's Refresh, or `vpn-import`.
- Restart the torrent tunnel: `sudo systemctl restart qbt-netns.service`.
- Rerun setup: the panel's *Finish setup* / *Update the system part*, or the plugin's
  `install.sh`. It is idempotent.
- **Last resort, and say what it costs:** `vpn-rescue` gets the normal connection
  back by turning the VPN and the kill switch off. Regular traffic then uses the
  user's real IP. The torrent tunnel is not touched.

## Report

1. What is wrong, in one or two sentences.
2. Whether anything actually leaked, and what: regular traffic, DNS, or torrent
   traffic, and for roughly how long if the evidence shows it. Keep what the
   evidence **proves** apart from what you **infer**. A blocked connection is not a
   leak.
3. The fix, and whether it was applied (only with the user's yes).
4. Whether it is likely to happen again.

If the evidence points at a bug in the plugin itself, offer to draft an issue for
https://github.com/ralphk-86/omarchy-proton/issues, and show the user the text first.
Strip IP addresses, server names, public keys and anything from the user's home
folder from it.
