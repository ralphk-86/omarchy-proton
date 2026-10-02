#!/usr/bin/env bash
# ============================================================================
#  make-preview.sh - build the presentation images of the plugin.
#
#    make-preview.sh compose      preview.png, 3200x1800, drawn (no capture)
#    make-preview.sh cards        marketplace card simulations of preview.png
#    make-preview.sh capture      a screenshot-mode capture of the open panel,
#                                 and compare.png: drawn panel next to it
#    make-preview.sh bar-states   screenshots/bar-states.png (captured)
#    make-preview.sh              all of the above
#
#  preview.png is what the Omarchy plugin marketplace shows (resized to fit
#  1600 px on the detail page and 720 px for the cards) and what heads the
#  README (full size, for high-density screens). A screen capture is 2560 px
#  wide, so enlarging pieces of it would only blur them. Instead, the bar
#  strip and the three panel rows are redrawn here with the widget's own
#  font, glyphs, colours and proportions, measured from a capture, at three
#  times their size. `capture` puts the drawing next to a real capture
#  (compare.png) so it can be checked against the widget.
#
#  The marketplace cards are 175 px tall and 352 px (three columns) or about
#  518 px (two columns) wide and crop the image around the centre
#  (object-fit: cover). So the title and the four features are big, short and
#  inside the middle 60% of the height.
#
#  Data is the made-up state of tests/preview/status.json: invented servers,
#  addresses from the ranges reserved for documentation.
#
#  Every step that touches the desktop uses only screenshot mode (the
#  widget's demoStatusFile setting), `omarchy bar set`, opening and closing
#  the panel through omarchy-shell, and a switch to an empty workspace and
#  back. It never sends key presses or clicks, and restores what it changed.
#
#  Needs ImageMagick 7 (`magick`), the JetBrainsMono Nerd Font that Omarchy
#  ships, and for the card mock-ups a sans font. capture and bar-states also
#  need grim, jq, hyprctl and omarchy; their crop coordinates were measured on
#  a 2560x1440 monitor at scale 1.25 with the widget on the right, and can be
#  set in the environment for another layout.
# ============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ID=io.github.ralphk-86.omarchy-proton
WORK="${WORK:-${TMPDIR:-/tmp}/omarchy-proton-preview}"
CAPTURE="$WORK/capture.png"
OUT="${OUT:-$REPO/preview.png}"
BAR_STATES="${BAR_STATES:-$REPO/screenshots/bar-states.png}"
WORKSPACE="${WORKSPACE:-8}"

# Where the panel and the widget are in a capture (screenshot pixels).
PANEL_X="${PANEL_X:-2145}"; PANEL_Y="${PANEL_Y:-30}"; PANEL_W="${PANEL_W:-412}"
STRIP_X="${STRIP_X:-2040}"; STRIP_W="${STRIP_W:-520}"; BAR_H="${BAR_H:-30}"

# Tokyo Night, as the capture shows it: background, text, dimmed text
# (Qt.darker(text, 1.55) in the widget), accent, lines.
BG="#1a1b26"; FG="#a9b1d6"; DIM="#6d728a"; ACCENT="#7aa2f7"; LINE="#2b2d3b"; BOX="#54576d"
TITLE="#c0caf5"

need() { for c in "$@"; do command -v "$c" >/dev/null || { echo "needs $c"; exit 1; }; done; }
font_file() { fc-match -f '%{file}' "$1" 2>/dev/null || true; }
g() { printf "\\U$(printf '%08X' "$1")"; }     # a Nerd Font glyph by code point

FONT=""; BOLD=""
fonts() {
  FONT=$(font_file "JetBrainsMono Nerd Font"); BOLD=$(font_file "JetBrainsMono Nerd Font:bold")
  [ -r "$FONT" ] && [ -r "$BOLD" ] || { echo "JetBrainsMono Nerd Font not found"; exit 1; }
}

# --- the drawn widget ----------------------------------------------------------
# Coordinates and sizes are the widget's at 1x, measured from a capture, and
# are multiplied by K. t <x> <baseline> <size> <colour> <font> <text> [kerning]
draw_args=()
t() {
  draw_args+=(-font "$5" -fill "$4" -pointsize "$(awk -v k="$K" -v s="$3" 'BEGIN{print s*k}')"
              -kerning "$(awk -v k="$K" -v s="${7:-0}" 'BEGIN{print s*k}')"
              -annotate "+$(awk -v k="$K" -v v="$1" 'BEGIN{printf "%d", v*k}')+$(awk -v k="$K" -v v="$2" 'BEGIN{printf "%d", v*k}')" "$6")
}
r() {  # r <x0> <y0> <x1> <y1> <stroke colour> <fill colour> <stroke width>
  draw_args+=(-stroke "$5" -strokewidth "$(awk -v k="$K" -v s="$7" 'BEGIN{print s*k}')" -fill "$6"
              -draw "rectangle $(awk -v k="$K" -v a="$1" -v b="$2" -v c="$3" -v d="$4" 'BEGIN{printf "%d,%d %d,%d", a*k, b*k, c*k, d*k}')"
              -stroke none)
}

# The panel, shortened to three parts: the header (server, kill switch, IP),
# the torrents line, and the leak check with its saved report.
draw_panel() {  # draw_panel <scale> <out>
  K="$1"; draw_args=()
  local w=412 h=262
  r 1 1 410 260 "$ACCENT" "$BG" 3
  t 17 51 28 "$FG" "$FONT" "$(g 0xF033E)"
  t 54 36 16.2 "$FG" "$BOLD" "Switzerland 7"
  t 54 57 11 "$DIM" "$BOLD" "THROUGH THE VPN, KILL SWITCH ON" 1.75
  r 284 19 393 42 "$BOX" none 1
  t 289 36 13.5 "$FG" "$FONT" "203.0.113.47"
  t 34 104 12.5 "$FG" "$FONT" "$(g 0xF01DA)"
  t 60 88 13.8 "$FG" "$FONT" "Torrents: Netherlands 12"
  t 60 105 11.3 "$DIM" "$FONT" "198.51.100.23 · qBittorrent is running"
  t 60 120 11.3 "$DIM" "$FONT" "inside the tunnel"
  t 365 108 16 "$FG" "$FONT" "$(g 0xF018F)"
  r 19 137 394 137 "$LINE" "$LINE" 1
  t 33 175 14 "$DIM" "$FONT" "$(g 0xF0565)"
  t 60 166 13.8 "$FG" "$FONT" "Check for leaks"
  t 60 183 11.3 "$DIM" "$FONT" "31 checks passed, no leaks found"
  t 60 211 11.3 "$DIM" "$FONT" "Report saved in ~/Documents/VPN leak checks. To"
  t 60 226 11.3 "$DIM" "$FONT" "share it, use latest-redacted.txt: addresses and"
  t 60 241 11.3 "$DIM" "$FONT" "keys are masked."
  t 365 175 16 "$FG" "$FONT" "$(g 0xF024B)"
  magick -size "$(awk -v k="$K" -v v=$w 'BEGIN{printf "%d", v*k}')x$(awk -v k="$K" -v v=$h 'BEGIN{printf "%d", v*k}')" \
    xc:"$BG" "${draw_args[@]}" "$2"
}

# The widget in the bar: closed lock, regular IP, torrent IP, and the
# underline the bar draws under a widget whose panel is open.
draw_bar() {  # draw_bar <scale> <out>
  K="$1"; draw_args=()
  t 11 19 12 "$FG" "$FONT" "$(g 0xF033E)"
  t 28 19 13.8 "$FG" "$FONT" "203.0.113.47"
  t 143 19 12 "$FG" "$FONT" "$(g 0xF01DA)"
  t 160 19 13.8 "$FG" "$FONT" "198.51.100.23"
  r 62 25 213 26 "$ACCENT" "$ACCENT" 0
  magick -size "$(awk -v k="$K" 'BEGIN{printf "%d", 282*k}')x$(awk -v k="$K" 'BEGIN{printf "%d", 28*k}')" \
    xc:"$BG" "${draw_args[@]}" "$2"
}

compose() {
  need magick; fonts; mkdir -p "$WORK"
  draw_panel 3 "$WORK/panel.png"
  draw_bar 3 "$WORK/bar.png"
  local pw ph bw bh
  pw=$(magick identify -format %w "$WORK/panel.png"); ph=$(magick identify -format %h "$WORK/panel.png")
  bw=$(magick identify -format %w "$WORK/bar.png");   bh=$(magick identify -format %h "$WORK/bar.png")
  local px=$((3200 - 150 - pw)) py=$(( (1800 - ph) / 2 + 70 ))
  local bx=$((px + pw - bw - 30)) by=$((py - bh - 70))
  magick -size 3200x1800 xc:"$BG" \
    "$WORK/bar.png" -geometry "+${bx}+${by}" -composite \
    "$WORK/panel.png" -geometry "+${px}+${py}" -composite \
    -font "$FONT" -fill "$DIM" -pointsize 52 -kerning 4 -annotate +160+470 "UNOFFICIAL OMARCHY BAR WIDGET" \
    -kerning 0 -font "$BOLD" -fill "$TITLE" -pointsize 208 -annotate +150+690 "Proton VPN" \
    -font "$BOLD" -pointsize 104 \
    -fill "$ACCENT" -annotate +164+880  "$(g 0xF033E)" -fill "$TITLE" -annotate +300+880  "Kill switch" \
    -fill "$ACCENT" -annotate +164+1036 "$(g 0xF01DA)" -fill "$TITLE" -annotate +300+1036 "Torrent tunnel" \
    -fill "$ACCENT" -annotate +164+1192 "$(g 0xF0565)" -fill "$TITLE" -annotate +300+1192 "Leak checks" \
    -fill "$ACCENT" -annotate +164+1348 "$(g 0xF024B)" -fill "$TITLE" -annotate +300+1348 "Drop-in configs" \
    -font "$FONT" -fill "$DIM" -pointsize 40 -annotate +160+1610 "Unofficial. Not affiliated with Proton AG. Made-up servers and documentation IP addresses." \
    -strip -define png:compression-level=9 "$OUT"
  echo "wrote $OUT ($(magick identify -format '%wx%h' "$OUT"), $(du -h "$OUT" | cut -f1))"
  # What the marketplace serves: fit to 1600 and to 720 px.
  magick "$OUT" -filter Lanczos -resize 1600x "$WORK/served-1600.png"
  magick "$OUT" -filter Lanczos -resize 720x "$WORK/served-720.png"
  echo "served sizes: $WORK/served-1600.png $WORK/served-720.png"
}

# The marketplace card: the 720 px copy shown in a 175 px tall area 352 px
# (three columns) or 518 px (two columns) wide with object-fit: cover,
# rendered at 2x as on a high-density screen, alone and as a mock card with
# the name, author line and one-line description under it (sizes from the
# marketplace's stylesheet: name 15 px mono, author 11 px, description 13 px
# sans fading over its last 28 px, 20 px padding; all doubled).
cards() {
  need magick jq; fonts
  local sans; sans=$(font_file "sans")
  local name desc; name=$(jq -r .name "$REPO/manifest.json"); desc=$(jq -r .description "$REPO/manifest.json")
  mkdir -p "$WORK"
  magick "$OUT" -filter Lanczos -resize 720x "$WORK/served-720.png"
  local cols w W
  for cols in 3 2; do
    w=$([ "$cols" = 3 ] && echo 352 || echo 518); W=$((w * 2))
    magick "$WORK/served-720.png" -filter Lanczos -resize "${W}x350^" -gravity center -extent "${W}x350" \
      "$WORK/card-crop-${cols}col.png"
    # The name wraps like the card's heading; the description stays one line.
    magick -background "$BG" -size "$((W - 80))x" -font "$BOLD" -fill "$TITLE" -pointsize 30 \
      caption:"$name" -bordercolor "$BG" -border 40x0 "$WORK/card-name.png"
    magick -size "${W}x112" xc:"$BG" \
      -font "$FONT" -fill "$DIM" -pointsize 22 -annotate +40+36 "by @ralphk-86 · Bar widget" \
      -font "$sans" -fill "$FG" -pointsize 26 -annotate +40+86 "$desc" \
      -fill "$BG" -draw "rectangle $((W - 40)),48 $W,112" \
      \( -size 56x64 gradient:"rgba(26,27,38,0)-$BG" -rotate -90 \) -geometry "+$((W - 96))+48" -composite \
      "$WORK/card-rest.png"
    magick \( -size "${W}x26" xc:"$BG" \) "$WORK/card-name.png" "$WORK/card-rest.png" \( -size "${W}x20" xc:"$BG" \) \
      -append "$WORK/card-text-${cols}col.png"
    magick "$WORK/card-crop-${cols}col.png" \( -size "${W}x2" xc:"#2f3549" \) "$WORK/card-text-${cols}col.png" -append \
      -bordercolor "#2f3549" -border 2 -bordercolor "#16161e" -border 24 "$WORK/card-mock-${cols}col.png"
  done
  echo "card crops: $WORK/card-crop-3col.png $WORK/card-crop-2col.png"
  echo "card mock-ups: $WORK/card-mock-3col.png $WORK/card-mock-2col.png"
}

# A real capture of the open panel in screenshot mode, and the drawn panel
# and bar at 1x next to it, to check the drawing against the widget.
capture() {
  need grim jq hyprctl omarchy omarchy-shell magick; fonts; mkdir -p "$WORK"
  [ "$(hyprctl clients -j | jq --argjson w "$WORKSPACE" '[.[] | select(.workspace.id == $w)] | length')" = 0 ] \
    || { echo "workspace $WORKSPACE is not empty; set WORKSPACE to an empty one"; exit 1; }
  local prev ok=0; prev=$(hyprctl activeworkspace -j | jq .id)
  omarchy bar set "$ID" demoStatusFile "$REPO/tests/preview/status.json" >/dev/null
  hyprctl dispatch "hl.dsp.focus({ workspace = \"$WORKSPACE\" })" >/dev/null; sleep 1.2
  omarchy-shell shell summon "$ID" '{}' >/dev/null; sleep 2.5
  [ "$(hyprctl activeworkspace -j | jq .id)" = "$WORKSPACE" ] && grim "$CAPTURE" && ok=1
  omarchy-shell shell hide "$ID" >/dev/null 2>&1 || true
  hyprctl dispatch "hl.dsp.focus({ workspace = \"$prev\" })" >/dev/null
  omarchy bar set "$ID" demoStatusFile "" >/dev/null
  (( ok )) || { echo "the workspace changed during the capture; try again"; exit 1; }
  draw_panel 1 "$WORK/panel-1x.png"
  magick "$CAPTURE" -crop "${PANEL_W}x262+${PANEL_X}+${PANEL_Y}" +repage "$WORK/panel-real.png"
  magick "$WORK/panel-real.png" "$WORK/panel-1x.png" +append -scale 300% "$WORK/compare.png"
  echo "captured $CAPTURE; drawn vs real (top rows only): $WORK/compare.png"
}

# The bar alone in four states. Captured at the screen's own resolution,
# nothing scaled up.
bar_states() {
  need grim jq omarchy magick; fonts; mkdir -p "$WORK"
  local orig
  orig=$(jq -r --arg id "$ID" '[.. | objects | select(.id? == $id) | .showIps][0] // true' "$HOME/.config/omarchy/shell.json")
  shoot() {  # shoot <demo file> <showIps> <name>
    omarchy bar set "$ID" demoStatusFile "$REPO/tests/preview/$1" >/dev/null
    omarchy bar set "$ID" showIps "$2" --json >/dev/null
    sleep 6.5      # one refresh of the widget
    grim "$WORK/full-$3.png"
    magick "$WORK/full-$3.png" -crop "${STRIP_W}x${BAR_H}+${STRIP_X}+0" +repage "$WORK/strip-$3.png"
    rm -f "$WORK/full-$3.png"
  }
  shoot status.json true locked-ips
  shoot status.json false locked-noips
  shoot status-normal.json true normal-ips
  shoot status-normal.json false normal-noips
  omarchy bar set "$ID" showIps "$orig" --json >/dev/null
  omarchy bar set "$ID" demoStatusFile "" >/dev/null
  local rows=() n label
  for n in "locked-ips:Server selected, kill switch on" "locked-noips:The same, IP addresses hidden" \
           "normal-ips:Normal connection, your own IP" "normal-noips:The same, IP addresses hidden"; do
    label=${n#*:}; n=${n%%:*}
    magick \( -size "420x$BAR_H" xc:"$BG" -font "$FONT" -fill "$FG" -pointsize 17 -gravity west -annotate +18+0 "$label" \) \
      "$WORK/strip-$n.png" +append "$WORK/row-$n.png"
    rows+=("$WORK/row-$n.png")
  done
  magick "${rows[@]}" -background "$BG" -splice 0x12 -append -bordercolor "$BG" -border 14 -strip "$BAR_STATES"
  echo "wrote $BAR_STATES ($(magick identify -format '%wx%h' "$BAR_STATES"))"
}

case "${1:-all}" in
  compose) compose ;;
  cards) cards ;;
  capture) capture ;;
  bar-states) bar_states ;;
  all) compose; cards; capture; bar_states ;;
  *) echo "usage: $0 [compose|cards|capture|bar-states]"; exit 1 ;;
esac
