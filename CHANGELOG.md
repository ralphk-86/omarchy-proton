# Changelog

## 0.3.2 (unreleased)

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
