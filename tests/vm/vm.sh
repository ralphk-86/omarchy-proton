#!/usr/bin/env bash
# ============================================================================
#  vm.sh - run the integration suite in a throwaway Omarchy VM.
#
#  The suite arms kill switches, builds network namespaces and changes
#  NetworkManager settings. None of that may touch the machine you work on, so
#  it runs in QEMU. The VM starts from the official Arch cloud image and is
#  turned into an Omarchy machine (Omarchy's mirror, the omarchy package, its
#  own network and firewall setup scripts); see user-data.yaml for exactly
#  what that does and does not include. Nothing here needs root on the host.
#
#  USAGE
#    tests/vm/vm.sh prepare     download the image, build the Omarchy base VM (once, ~15 min)
#    tests/vm/vm.sh test        fresh VM from the base, run tests/vm/suite.sh
#    tests/vm/vm.sh shell       fresh VM with the repo copied in, then an SSH shell
#    tests/vm/vm.sh up          the same, left running; then `vm.sh ssh <cmd>`, `vm.sh stop`
#    tests/vm/vm.sh clean       delete the base VM (the downloaded image stays)
#
#  Needs qemu-system-x86_64 and qemu-img (omarchy pkg add qemu-base), bsdtar,
#  ssh and curl. Everything is kept in $VM_CACHE (~/.cache/omarchy-plugin-vm).
#
#  The harness is not specific to this plugin: prepare/boot/ssh know nothing
#  about VPNs. Another plugin can reuse it with its own suite.sh.
# ============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$REPO/tests/vm"
CACHE="${VM_CACHE:-$HOME/.cache/omarchy-plugin-vm}"
IMG_URL="${VM_IMAGE_URL:-https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2}"
IMG="$CACHE/img/arch-cloudimg.qcow2"
BASE="$CACHE/base.qcow2"
RUN="$CACHE/run.qcow2"
KEY="$CACHE/id_ed25519"
PORT="${VM_SSH_PORT:-2222}"
PIDFILE="$CACHE/qemu.pid"
PLUGIN_ID="$(jq -r .id "$REPO/manifest.json")"

# A user-local QEMU unpacked into the cache works as well as an installed one.
if [[ -x "$CACHE/qemu-root/usr/bin/qemu-system-x86_64" ]] && ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
  export PATH="$CACHE/qemu-root/usr/bin:$PATH"
  export LD_LIBRARY_PATH="$CACHE/qemu-root/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  QEMU_DATA=(-L "$CACHE/qemu-root/usr/share/qemu")
else
  QEMU_DATA=()
fi
for c in qemu-system-x86_64 qemu-img bsdtar ssh ssh-keygen curl jq; do
  command -v "$c" >/dev/null 2>&1 || { echo "missing: $c (omarchy pkg add qemu-base)"; exit 1; }
done

say() { printf '==> %s\n' "$*"; }

# One VM at a time: two runs would share the disk, the SSH port and the log.
mkdir -p "$CACHE"
exec 9>"$CACHE/lock"
if [[ "${1:-}" != "ssh" ]] && ! flock -n 9; then
  echo "another vm.sh is running (lock: $CACHE/lock)"; exit 1
fi
SSH_OPTS=(-i "$KEY" -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes)
vssh() { ssh "${SSH_OPTS[@]}" admin@127.0.0.1 "$@"; }

boot() {  # boot <disk> [extra qemu args...]
  local disk="$1"; shift
  local accel=(-accel tcg -cpu max)
  [[ -w /dev/kvm ]] && accel=(-accel kvm -cpu host)
  qemu-system-x86_64 "${QEMU_DATA[@]}" "${accel[@]}" -m 2048 -smp 2 \
    -drive "file=$disk,if=virtio,format=qcow2" \
    -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$PORT-:22" \
    -display none -serial "file:$CACHE/console.log" -pidfile "$PIDFILE" -daemonize "$@"
}

wait_ssh() {
  local i
  for i in $(seq 1 120); do
    vssh true 2>/dev/null && return 0
    sleep 2
  done
  echo "the VM did not answer on SSH; see $CACHE/console.log"; return 1
}

stop() {
  [[ -f "$PIDFILE" ]] || return 0
  local pid; pid=$(cat "$PIDFILE")
  vssh sudo poweroff 2>/dev/null || true
  local i
  for i in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  kill "$pid" 2>/dev/null || true
  rm -f "$PIDFILE"
}

prepare() {
  mkdir -p "$CACHE/img"
  [[ -f "$KEY" ]] || ssh-keygen -q -t ed25519 -N "" -C vm-test -f "$KEY"
  if [[ ! -f "$IMG" ]]; then
    say "Downloading the Arch cloud image"
    curl -fL --progress-bar -o "$IMG.part" "$IMG_URL" && mv "$IMG.part" "$IMG"
  fi
  say "Building the base VM (packages, NetworkManager, test users)"
  local seed="$CACHE/seed"
  rm -rf "$seed" "$BASE"; mkdir -p "$seed"
  printf 'instance-id: omarchy-plugin-vm\nlocal-hostname: plugin-test\n' > "$seed/meta-data"
  sed "s|@PUBKEY@|$(cat "$KEY.pub")|" "$HERE/user-data.yaml" > "$seed/user-data"
  ( cd "$seed" && bsdtar -c -f "$CACHE/seed.iso" --format=iso9660 --options='volume-id=CIDATA,rockridge,joliet' user-data meta-data )
  qemu-img create -q -f qcow2 -F qcow2 -b "$IMG" "$BASE" 20G
  boot "$BASE" -drive "file=$CACHE/seed.iso,if=virtio,format=raw,readonly=on"
  # Two stages with a reboot in between; the second one powers the machine off.
  local pid i; pid=$(cat "$PIDFILE")
  for i in $(seq 1 1500); do kill -0 "$pid" 2>/dev/null || break; sleep 2; done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid"; rm -f "$PIDFILE"
    echo "the base VM did not finish; see $CACHE/console.log"; exit 1
  fi
  rm -f "$PIDFILE"
  grep -q "BASE-READY" "$CACHE/console.log" || { echo "setup did not complete; see $CACHE/console.log"; exit 1; }
  say "Base VM ready: $BASE"
}

start_fresh() {
  [[ -f "$BASE" ]] || prepare
  stop
  rm -f "$RUN"
  qemu-img create -q -f qcow2 -F qcow2 -b "$BASE" "$RUN"
  boot "$RUN"
  wait_ssh
  # The plugin arrives the way `omarchy plugin add` leaves it: a checkout in
  # the user's plugin folder. Tracked files, plus new ones not yet added (never ignored ones) go in.
  local dest="/home/tester/.config/omarchy/plugins/$PLUGIN_ID"
  vssh "sudo install -d -o tester -g tester /home/tester/.config /home/tester/.config/omarchy /home/tester/.config/omarchy/plugins $dest"
  git -C "$REPO" ls-files -z --cached --others --exclude-standard | tar -C "$REPO" --null -T - -cf - | vssh "sudo -u tester tar -C $dest -xf -"
}

case "${1:-}" in
  prepare) prepare ;;
  test)
    start_fresh
    say "Running the suite"
    rc=0
    vssh "sudo bash /home/tester/.config/omarchy/plugins/$PLUGIN_ID/tests/vm/suite.sh" 2>&1 | tee "$CACHE/last-run.log" || rc=$?
    rc=${PIPESTATUS[0]}
    stop
    say "Log: $CACHE/last-run.log"
    exit "$rc"
    ;;
  shell)
    start_fresh
    say "VM is up. Plugin: ~tester/.config/omarchy/plugins/$PLUGIN_ID   (exit the shell to shut it down)"
    ssh "${SSH_OPTS[@]}" -o BatchMode=no -t admin@127.0.0.1 || true
    stop
    ;;
  up)
    # Fresh VM with the plugin copied in, left running for `vm.sh ssh`.
    start_fresh
    say "VM is up on port $PORT. Run commands with: tests/vm/vm.sh ssh <command>; stop with: tests/vm/vm.sh stop"
    ;;
  ssh)
    shift
    vssh "$@"
    ;;
  stop)  stop ;;
  clean) stop; rm -f "$BASE" "$RUN" "$CACHE/seed.iso"; rm -rf "$CACHE/seed" ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac
