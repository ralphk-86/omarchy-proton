# Test VM

`vm.sh` runs `suite.sh` inside a throwaway QEMU virtual machine, because the suite arms kill
switches, pulls tunnels down and installs root helpers: things you do not test on the machine
you work on.

## What the VM is

The official Arch Linux cloud image, turned into an Omarchy machine on first boot
(`user-data.yaml`):

- packages from Omarchy's stable mirror and the `[omarchy]` repository, brought to exactly
  those versions
- the `omarchy` package itself (its CLI, the shell, Hyprland)
- network and firewall configured by Omarchy's own install scripts
  (`install/hardware/network.sh`, `install/config/firewall.sh`): NetworkManager with
  systemd-resolved, `NetworkManager-wait-online` masked, UFW denying incoming
- a desktop user `tester` (in `wheel`, sudo asks for the password `tester`) and an `admin`
  account the harness uses

What it is not: a full desktop. The applications of Omarchy's base list are not installed, the
bootloader integration (limine, snapper) is left out, and no graphical session runs. The
panel's QML is not exercised here; test that on a real Omarchy.

## Requirements on the host

`qemu-system-x86_64` and `qemu-img` (`omarchy pkg add qemu-base`), plus `bsdtar`, `ssh`, `curl`
and `jq`. KVM is used when `/dev/kvm` is writable. No root. About 3 GB in
`~/.cache/omarchy-plugin-vm` (`VM_CACHE` to change it).

## What the suite simulates

No VPN account is needed. Inside the VM a network namespace plays the internet and the
provider: two WireGuard servers, an in-tunnel DNS resolver, and a "what is my IP" service that
answers with the address a request came from. Every path therefore has a known answer: the
"home" address, server A, server B, or the torrent tunnel. A leak is a request that arrives
from the home address when it should not. See the header of `suite.sh`.

## Reusing it for another plugin

`vm.sh` and `user-data.yaml` know nothing about VPNs. Copy `tests/vm/` into another plugin
repository and replace `suite.sh` (and `with-password.py` if you need the sudo prompt
answered). The base VM in the cache is shared.
