#!/usr/bin/env bash
# ============================================================================
#  uninstall.sh - remove the system part of omarchy-proton.
#
#  USAGE
#    uninstall.sh                  remove the kit; keep your servers, the
#                                  torrent config, your settings and IPv6 off
#    uninstall.sh --restore-ipv6   also turn IPv6 back on
#    uninstall.sh --purge          also delete the servers, the WireGuard
#                                  configs, /etc/vpnkit and your saved
#                                  leak-check reports
#
#  Afterwards qBittorrent is no longer confined: it runs on the normal
#  connection again. Remove the widget itself with
#    omarchy plugin remove io.github.ralphk-86.omarchy-proton
# ============================================================================
set -euo pipefail

[ "$(uname -s)" = "Linux" ] || { echo "omarchy-proton is for Linux (Omarchy)."; exit 1; }
[[ $EUID -eq 0 ]] && { echo "Run as your normal user, without sudo."; exit 1; }
for a in "$@"; do
  case "$a" in
    --restore-ipv6|--purge) ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown option: $a"; exit 1 ;;
  esac
done

if pgrep -x qbittorrent >/dev/null; then echo "Close qBittorrent first."; exit 1; fi

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SRC/system/uninstall-root.sh"
[[ -f "$ROOT" ]] || ROOT=/usr/local/lib/vpnkit/uninstall-root.sh

echo "==> Turning the VPN off"
[[ -x /usr/local/bin/vpn-toggle ]] && /usr/local/bin/vpn-toggle off >/dev/null 2>&1 || true

# The leak-check reports are yours, in your Documents; only --purge removes
# them. Find the folder now: the helper that knows it is about to go.
REPORTS=""
for a in "$@"; do
  if [[ "$a" == "--purge" ]]; then
    REPORTS=$(bash -c '. /usr/local/lib/vpnkit/common.sh && vpnkit_report_dir' 2>/dev/null) || REPORTS=""
  fi
done

echo "==> Removing the qBittorrent launcher override"
rm -f "$HOME/.local/share/applications/org.qbittorrent.qBittorrent.desktop"

echo "==> Removing the system files (one password prompt)"
if [[ -t 0 ]]; then sudo /usr/bin/bash "$ROOT" "$@"; else pkexec /usr/bin/bash "$ROOT" "$@"; fi

if [[ -n "$REPORTS" && -d "$REPORTS" ]]; then
  echo "==> Removing the leak-check reports in $REPORTS"
  # Only the files vpn-check writes; the folder goes only if that empties it.
  rm -f -- "$REPORTS"/leak-check-*.txt "$REPORTS/latest.txt" "$REPORTS/latest-redacted.txt" "$REPORTS"/.running.*
  rmdir -- "$REPORTS" 2>/dev/null || echo "    (kept the folder: it holds other files)"
fi

echo "==> Done. The widget stays until you run: omarchy plugin remove io.github.ralphk-86.omarchy-proton"
