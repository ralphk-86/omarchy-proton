# CLAUDE.md

Guidance for Claude Code (and any other agent) working in this repository.

## What this is

`omarchy-proton` is an Omarchy shell plugin: Proton VPN over WireGuard in the bar, with a kill
switch, and a second always-on tunnel in a network namespace that qBittorrent cannot leave.
Plugin id `io.github.ralphk-86.omarchy-proton`. The engine underneath is called `vpnkit`
(paths `/etc/vpnkit`, `/usr/local/lib/vpnkit`, helpers `vpnkit-*`); that name is internal and
stays.

The repository is meant to be public. Treat every file and every commit as published.

## Read first

- `README.md`: what users are promised. Behaviour changes start there.
- `CONTRIBUTING.md`: layout, the three test layers, rules for changes.
- `SECURITY.md`: the table of root helpers. Keep it true.
- `tests/vm/README.md`: what the test VM is and is not.

## Architecture in five lines

1. `VpnWidget.qml` shows `vpn-status --json` and runs commands. No VPN logic in QML.
2. `system/bin/*` are installed to `/usr/local/bin`. `vpn-*` are user commands; `vpnkit-*` and
   `qbt-*` are helpers, five of them callable through passwordless sudo.
3. Desktop VPN = NetworkManager WireGuard profiles named `<prefix>-<tag>`, written as keyfiles
   by `vpnkit-import`, never connected automatically. Kill switch = nftables table
   `inet vpnkit_kill`, armed by `vpn-toggle <server>` and by the dispatcher hook, removed only
   by `vpn-toggle off`.
4. Torrent tunnel = namespace `qbtvpn` with interface `pqbt0`, built by `qbt-netns-up` from
   `/etc/wireguard/vpnkit-torrent.conf`. `/usr/local/bin/qbittorrent` shadows the real binary.
5. Configs arrive through the drop folder (`~/Documents/WireGuard`, `torrent/` inside it for
   the torrent tunnel); `vpnkit-sync` imports and then removes them from the folder.

## Non-negotiable rules

1. **No personal data, ever.** No real names, domains, IP addresses, hostnames or home paths in
   files, commit messages or commit metadata. Commits use the GitHub noreply address
   (`git config user.email` in this repo is already set to it). `tests/check.sh` enforces this
   against `.private-patterns`, which is gitignored and must stay that way. Screenshots must
   not show a home IP: take them with a VPN server selected.
2. **Fail closed.** Unknown state is shown as unknown or blocks; never a guess, never a stale
   address.
3. **Nothing downloaded is executed.** Packages only through `pacman` from official repos.
4. **Root helpers take no paths and validate every argument.** New passwordless rule means a
   new row in `SECURITY.md` and a suite test that the rule cannot be abused.
5. **Do not overwrite user configuration without an explicit flag.** Back up what is replaced.
6. **Never test network changes on the developer's machine.** Kill switch, namespace, IPv6 and
   NetworkManager changes are tested in the VM (`tests/vm/vm.sh test`). On a real machine,
   arm a timer first (`nohup bash -c 'sleep 90; vpn-toggle off' &`) and keep `vpn-rescue` in
   mind.
7. **The installer's root half cannot be run from an agent session** on the developer's
   machine (permission mode blocks it, and it needs a password). Ask the user to click
   "Update the system part" in the panel or run `install.sh` in a terminal.

## Testing, in the order to run it

```sh
tests/check.sh                                   # static; must pass before every commit
tests/marketplace-scan.sh <marketplace checkout> # expect: review-required, no findings
tests/vm/vm.sh test                              # full behaviour in an Omarchy VM
```

The VM needs QEMU. If it is not installed system-wide, a user-local copy unpacked from the
official Arch packages into `~/.cache/omarchy-plugin-vm/qemu-root` works and is picked up
automatically.

What no automated test covers: the panel's QML on screen, the polkit prompt from "Finish
setup", suspend/resume, and real Proton servers. Those need a person on a real Omarchy.

## Omarchy plugin marketplace: what compliance means

Source of truth: <https://plugins.omarchy.org/publish.html>,
<https://plugins.omarchy.org/develop.html>, and `SUBMISSION.md`, `SECURITY.md`,
`VERIFICATION.md` in <https://github.com/omacom/omarchy-plugin-marketplace>. Summary as of
2026-09-30:

- Public GitHub repository, exactly one plugin, `manifest.json` in the root.
- Root README with installation **and removal** instructions; root licence file; external
  dependencies documented. Optional root `preview.png` (any size, optimised by them).
- Manifest: `schemaVersion`, `id`, `name`, `version`, `author`, `description`, `kinds`,
  `entryPoints` are required. `omarchy plugin validate .` must pass. No symlinks in the repo.
  Ids under `omarchy.*` are reserved.
- **The plugin id is permanent and globally unique**, also across retired listings. The
  recommended form is `io.github.<user>.<plugin>`; that is why this one is
  `io.github.ralphk-86.omarchy-proton`. Changing it later means a new listing.
- Submission: an issue in the marketplace repo from the `submit-plugin` form (or `gh issue
  create` with the exact body format in their `SUBMISSION.md`). One category, one to three
  tags from their fixed lists. Five checklist statements, all of which must be true, including
  "does not overwrite user configuration without explicit consent".
- An **Automated Security Baseline** statically scans the exact commit. Outcomes: `passed`,
  `review-required` (capabilities such as installer, privilege, sudoers-modification,
  service-management, package-manager: a maintainer must review), `needs-fixes` (findings).
  A scan that errors out counts as failed. This plugin cannot do better than
  `review-required`; it must have zero findings. `CONTRIBUTING.md` lists the patterns that
  tripped it here.
- Listing is bound to one commit. After a release, the listing shows "Update unverified"
  until a "Plugin verification" issue promotes the new commit.
- An agent may prepare the submission but must show the owner the final title and body and
  create the issue only after the owner explicitly approves (their rule, and ours).

Planned listing metadata: category `System`; tags `vpn`, `security`, `bar`.

## Release checklist

1. `VERSION`, `manifest.json`, `kitVersion` in `VpnWidget.qml`, `CHANGELOG.md` agree.
2. All three test layers pass; VM suite result pasted into the release notes.
3. `preview.png` current and free of personal data.
4. `git log` shows only noreply addresses; `tests/check.sh` history check passes.
5. Tag `vX.Y.Z`, push, then (if listed) open the marketplace "Plugin verification" issue with
   the new commit SHA.

## Going public (one time, owner's decision)

The history was squashed to one clean commit on 2026-09-30 because the first commits carried
personal data (a local bundle of the old history is in `~/.cache` on the owner's machine).
GitHub can keep unreferenced old commits of a repository for a while, so before going public
the safest path is to recreate the repository from the clean history rather than flip the
existing one: delete it, `gh repo create ralphk-86/omarchy-proton --private --source . --push`,
check it, then `gh repo edit ralphk-86/omarchy-proton --visibility public
--accept-visibility-change-consequences`. Then the marketplace submission. Every one of these
steps needs the owner's explicit go-ahead in the session.

## Gotchas learned the hard way

- `nmcli connection import` creates a profile with autoconnect on and activates it at once.
  Write keyfiles instead (`vpnkit-import`).
- A stock Omarchy has NetworkManager, nftables, jq and curl but **not** `wireguard-tools`.
- Omarchy masks `NetworkManager-wait-online`, so `network-online.target` does not mean the
  network is up. `qbt-netns.service` retries.
- Omarchy runs UFW (deny incoming). The kit's nftables tables coexist with it.
- A new network namespace does not inherit the host's `disable_ipv6` sysctl.
- `systemd-resolved` answers over a Unix socket that a network namespace does not isolate;
  hence the namespace's own `nsswitch.conf`.
- `pkill -f <pattern>` from an agent shell kills the shell itself when the pattern appears in
  its own command line. Kill by PID.
- grim cannot capture while the monitor is in DPMS sleep.
