#!/usr/bin/env bash
# ============================================================================
#  make-preview.sh - build the landscape preview.png (1600x900) for the
#  Omarchy plugin marketplace from a screenshot-mode capture of the widget.
#
#    tests/preview/make-preview.sh capture   take the capture (Omarchy only)
#    tests/preview/make-preview.sh compose   build preview.png from it
#    tests/preview/make-preview.sh           both
#
#  capture: shows the made-up state in tests/preview/status.json (screenshot
#  mode, see CONTRIBUTING.md), switches to an empty workspace, opens the
#  panel, takes one screenshot, closes the panel, switches back and turns
#  screenshot mode off again. It sends no key presses or clicks.
#
#  compose: cuts the bar strip, the panel header with the torrents line, and
#  the leak-check row out of that capture, frames them like the panel, and
#  sets them next to a title and four feature lines. Everything that matters
#  sits in the middle 60% of the height, because the marketplace card crops
#  the image to between 2:1 and 3:1 around the centre.
#
#  Needs ImageMagick 7 (`magick`) and the JetBrainsMono Nerd Font that Omarchy
#  ships; capture also needs grim, jq, hyprctl and omarchy. The crop
#  coordinates below were measured on a 2560x1440 monitor at scale 1.25 with
#  the panel on the right; on another layout set them in the environment.
# ============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ID=io.github.ralphk-86.omarchy-proton
WORK="${WORK:-${TMPDIR:-/tmp}/omarchy-proton-preview}"
CAPTURE="$WORK/capture.png"
OUT="${OUT:-$REPO/preview.png}"
WORKSPACE="${WORKSPACE:-8}"

# Capture geometry, in screenshot pixels: the panel's frame, the two pieces
# of it that are used, and the part of the bar with the widget.
PANEL_X="${PANEL_X:-2145}"; PANEL_W="${PANEL_W:-412}"
TOP_Y="${TOP_Y:-33}";       TOP_H="${TOP_H:-132}"      # header + torrents line
CHECK_Y="${CHECK_Y:-828}";  CHECK_H="${CHECK_H:-100}"  # "Check for leaks" + saved report line
BAR_X="${BAR_X:-2215}";     BAR_W="${BAR_W:-269}";  BAR_H="${BAR_H:-28}"

BG="#1a1b26"; FG="#c0caf5"; DIM="#7f86ad"; ACCENT="#7aa2f7"

capture() {
  for c in grim jq hyprctl omarchy omarchy-shell; do
    command -v "$c" >/dev/null || { echo "capture needs $c (run it on Omarchy)"; exit 1; }
  done
  mkdir -p "$WORK"
  [ "$(hyprctl clients -j | jq --argjson w "$WORKSPACE" '[.[] | select(.workspace.id == $w)] | length')" = 0 ] \
    || { echo "workspace $WORKSPACE is not empty; set WORKSPACE to an empty one"; exit 1; }
  local prev; prev=$(hyprctl activeworkspace -j | jq .id)
  omarchy bar set "$ID" demoStatusFile "$REPO/tests/preview/status.json" >/dev/null
  hyprctl dispatch "hl.dsp.focus({ workspace = \"$WORKSPACE\" })" >/dev/null; sleep 1.2
  omarchy-shell shell summon "$ID" '{}' >/dev/null; sleep 2.5
  local ok=0
  [ "$(hyprctl activeworkspace -j | jq .id)" = "$WORKSPACE" ] && grim "$CAPTURE" && ok=1
  omarchy-shell shell hide "$ID" >/dev/null 2>&1 || true
  hyprctl dispatch "hl.dsp.focus({ workspace = \"$prev\" })" >/dev/null
  omarchy bar set "$ID" demoStatusFile "" >/dev/null
  (( ok )) || { echo "the workspace changed during the capture; try again"; exit 1; }
  echo "captured $CAPTURE"
}

compose() {
  command -v magick >/dev/null || { echo "compose needs ImageMagick 7 (magick)"; exit 1; }
  [ -r "$CAPTURE" ] || { echo "no capture at $CAPTURE; run: $0 capture"; exit 1; }
  local font; font=$(fc-match -f '%{file}' "JetBrainsMono Nerd Font" 2>/dev/null || true)
  [ -r "$font" ] || { echo "JetBrainsMono Nerd Font not found"; exit 1; }
  local bold; bold=$(fc-match -f '%{file}' "JetBrainsMono Nerd Font:bold" 2>/dev/null || echo "$font")
  local inner=$((PANEL_W - 6)) x0=$((PANEL_X + 3))

  # The panel, shortened: header and torrents line, then the leak check.
  magick "$CAPTURE" \
    \( -clone 0 -crop "${inner}x${TOP_H}+${x0}+${TOP_Y}" +repage \) \
    \( -size "${inner}x10" xc:"$BG" \) \
    \( -size "${inner}x1" xc:"#3b4261" \) \
    \( -size "${inner}x10" xc:"$BG" \) \
    \( -clone 0 -crop "${inner}x${CHECK_H}+${x0}+${CHECK_Y}" +repage \) \
    \( -size "${inner}x8" xc:"$BG" \) \
    -delete 0 -append -bordercolor "$ACCENT" -border 3 \
    -filter Lanczos -resize 135% "$WORK/panel.png"
  magick "$CAPTURE" -crop "${BAR_W}x${BAR_H}+${BAR_X}+0" +repage \
    -filter Lanczos -resize 135% "$WORK/bar.png"

  local lock kill tor shield folder
  lock=$(printf '\U000F033E'); tor=$(printf '\U000F01DA'); shield=$(printf '\U000F0565'); folder=$(printf '\U000F024B')
  kill="$lock"

  local pw ph bw
  pw=$(magick identify -format %w "$WORK/panel.png"); ph=$(magick identify -format %h "$WORK/panel.png")
  bw=$(magick identify -format %w "$WORK/bar.png")
  local px=$((1600 - 84 - pw)) py=$(( (900 - ph) / 2 + 28 ))
  local barx=$((1600 - 84 - bw)) bary=$((py - 56))

  magick -size 1600x900 xc:"$BG" \
    "$WORK/bar.png" -geometry "+${barx}+$((bary))" -composite \
    "$WORK/panel.png" -geometry "+${px}+${py}" -composite \
    -font "$font" -fill "$DIM" -pointsize 22 -annotate +90+236 "OMARCHY BAR WIDGET" \
    -font "$bold" -fill "$FG" -pointsize 50 -annotate +90+306 "Proton VPN" \
    -annotate +90+366 "+ Kill Switch" -annotate +90+426 "+ Torrent Tunnel" \
    -font "$font" -pointsize 25 \
    -fill "$ACCENT" -annotate +92+500 "$kill"   -fill "$FG" -annotate +136+500 "Kill switch on whenever a server is in use" \
    -fill "$ACCENT" -annotate +92+548 "$tor"    -fill "$FG" -annotate +136+548 "qBittorrent in its own WireGuard tunnel" \
    -fill "$ACCENT" -annotate +92+596 "$shield" -fill "$FG" -annotate +136+596 "Leak checks, saved as reports" \
    -fill "$ACCENT" -annotate +92+644 "$folder" -fill "$FG" -annotate +136+644 "Drop .conf files in a folder, press Refresh" \
    -fill "$DIM" -pointsize 18 -annotate +90+850 "Unofficial. Not affiliated with Proton AG. Made-up servers and documentation IP addresses." \
    -strip "$OUT"
  echo "wrote $OUT"

  # What the marketplace card shows: the image scaled to cover 352x175
  # (3 columns) and 518x175 (2 columns), centre-cropped.
  magick "$OUT" -resize 352x175^ -gravity center -extent 352x175 "$WORK/card-3col.png"
  magick "$OUT" -resize 518x175^ -gravity center -extent 518x175 "$WORK/card-2col.png"
  echo "card simulations: $WORK/card-3col.png $WORK/card-2col.png"
}

case "${1:-all}" in
  capture) capture ;;
  compose) compose ;;
  all) capture; compose ;;
  *) echo "usage: $0 [capture|compose]"; exit 1 ;;
esac
