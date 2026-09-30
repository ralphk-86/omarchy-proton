# Contributing

## Layout

```
manifest.json, VpnWidget.qml   the Omarchy plugin (bar widget + panel)
install.sh, uninstall.sh       what the user runs; they call the root halves below once
system/install-root.sh         privileged install: packages, files, sudoers, IPv6, services
system/uninstall-root.sh       privileged removal
system/bin/                    everything that lands in /usr/local/bin
system/lib/common.sh           settings loader shared by all scripts
system/vpnkit.settings         template for /etc/vpnkit/vpnkit.conf
providers/                     naming presets per VPN provider
tests/                         see below
```

The widget holds no VPN logic. It shows `vpn-status --json` and runs the commands in
`system/bin`. Fix behaviour in the scripts, not in QML.

## Tests

Run all three before a release.

**1. Static checks** (seconds, no root):

```sh
tests/check.sh
```

It fails on personal data. Create `.private-patterns` (gitignored) with one extended regex per
line for the things of yours that must never be published: your name, domains, home IP,
server addresses. The check greps the tree and the whole git history for them.

**2. The marketplace's security scan.** The Omarchy plugin marketplace scans every submission
statically and fails closed. Get its scanner and run it here first:

```sh
git clone https://github.com/omacom/omarchy-plugin-marketplace.git ~/src/omarchy-plugin-marketplace
tests/marketplace-scan.sh ~/src/omarchy-plugin-marketplace
```

Expected: `outcome: review-required` with no findings. Things it has flagged in this repo
before, so you know the patterns:

- `curl ... -o file` or `curl ... | something` followed later by any command that mentions
  that file, even `/dev/null`: reported as "downloaded content is executed". Capture into a
  variable instead: `body=$(curl -s "$url")`.
- a script with many independent `[[ ... ]] && VAR=1` lines: the scanner gives up ("shell-state
  expansion limit") and the scan counts as failed. Compute such values with `jq` or in one
  expression.
- `git clone` followed by running something from the clone.
- `NOPASSWD: ALL`, or passwordless rules for shells, interpreters, `systemctl`, `kill`.

**3. The VM suite** (a few minutes; first run builds the VM):

```sh
tests/vm/vm.sh prepare
tests/vm/vm.sh test
tests/vm/vm.sh shell      # the same VM with a shell, to poke around
```

See `tests/vm/README.md`.

## Rules for changes

- Nothing a script downloads may be executed. Packages come from `pacman`, from the official
  repositories only.
- A helper that gets a passwordless sudo rule takes no paths from the caller and validates
  every argument. Add it to the table in `SECURITY.md`.
- Never overwrite a user's existing configuration without them asking. Back up what you
  replace.
- Fail closed. When state is unknown, show "unknown" or block; never show a guess.
- Bump `VERSION`, `manifest.json`, `kitVersion` in `VpnWidget.qml` and `CHANGELOG.md` together;
  `tests/check.sh` checks they agree.
- Commit with a GitHub noreply address.

## Preview image

`preview.png` must never show anyone's real servers or IP addresses. The widget has a
screenshot mode that shows `tests/preview/status.json` (made-up servers, IPs from the ranges
reserved for documentation) instead of the real status, and ignores clicks:

```sh
ID=io.github.ralphk-86.omarchy-proton
omarchy bar set $ID demoStatusFile "$PWD/tests/preview/status.json"
omarchy-shell shell summon $ID '{}'      # open the panel, take the screenshot
omarchy bar set $ID demoStatusFile ""    # back to real data
```
