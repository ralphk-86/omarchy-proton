#!/usr/bin/env bash
# ============================================================================
#  make-preview.sh - build the presentation images of the plugin.
#
#    make-preview.sh compose      preview.png, 3200x1800, drawn (no capture)
#    make-preview.sh cards        marketplace card simulations of preview.png
#    make-preview.sh capture      a screenshot-mode capture of the open panel,
#                                 and compare.png: drawn panel next to it
#    make-preview.sh bar-states   screenshots/bar-states.png (captured)
#    make-preview.sh opt-in       screenshots/opt-in.png, drawn (no capture):
#                                 the panel with the Firefox tunnel, Chrome
#                                 direct and SSH direct on
#    make-preview.sh              all of the above
#
#  preview.png is what the Omarchy plugin marketplace shows (resized to fit
#  1600 px on the detail page and 720 px for the cards) and what heads the
#  README (full size, for high-density screens). A screen capture is 2560 px
#  wide, so enlarging pieces of it would only blur them. Instead, the bar
#  strip and the four panel rows are redrawn here with the widget's own
#  font, glyphs, colours and proportions, measured from a capture, at three
#  times their size. `capture` puts the drawing next to a real capture
#  (compare.png) so it can be checked against the widget.
#
#  The marketplace cards are 175 px tall and 352 px (three columns) or about
#  518 px (two columns) wide and crop the image around the centre
#  (object-fit: cover). So the title and the five features are big, short and
#  inside the middle 60% of the height.
#
#  Data is the made-up state of tests/preview/status.json (opt-in.png:
#  status-direct.json): invented servers, addresses from the ranges reserved
#  for documentation. compose, cards and opt-in only draw: they never touch
#  the desktop.
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
# Captures show the desktop: everything this script writes is private to you.
umask 077

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ID=io.github.ralphk-86.omarchy-proton

# The work folder. By default a new private folder for each run (kept, so its
# images can be looked at; the path is printed). A WORK you set must be a
# directory you own, not a symlink, with no access for group or others; it
# is created (mode 700) if it does not exist. A shared or predictable folder
# would let another user read or replace the captures.
work_dir() {
  if [[ -z "${WORK:-}" ]]; then
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-proton-preview.XXXXXXXX")
    return
  fi
  [[ -e "$WORK" || -L "$WORK" ]] || mkdir -m 700 -- "$WORK"
  if [[ -L "$WORK" || ! -d "$WORK" || ! -O "$WORK" ]] \
     || (( 8#$(stat -c %a -- "$WORK") & 8#077 )); then
    echo "WORK=$WORK must be a directory you own (not a symlink) with mode 700; refusing" >&2
    exit 1
  fi
}
work_dir
CAPTURE="$WORK/capture.png"
# Raw captures never outlive the run, also when it fails half way.
trap 'rm -f -- "$CAPTURE"' EXIT
OUT="${OUT:-$REPO/preview.png}"
BAR_STATES="${BAR_STATES:-$REPO/screenshots/bar-states.png}"
OPT_IN="${OPT_IN:-$REPO/screenshots/opt-in.png}"
WORKSPACE="${WORKSPACE:-8}"

# Where the panel and the widget are in a capture (screenshot pixels).
PANEL_X="${PANEL_X:-2145}"; PANEL_Y="${PANEL_Y:-30}"; PANEL_W="${PANEL_W:-412}"
STRIP_X="${STRIP_X:-2040}"; STRIP_W="${STRIP_W:-520}"; BAR_H="${BAR_H:-30}"

# Tokyo Night, as the capture shows it: background, text, dimmed text
# (Qt.darker(text, 1.55) in the widget), accent, lines.
BG="#1a1b26"; FG="#a9b1d6"; DIM="#6d728a"; ACCENT="#7aa2f7"; LINE="#2b2d3b"; BOX="#54576d"
TITLE="#c0caf5"

need() { for c in "$@"; do command -v "$c" >/dev/null || { echo "needs $c"; exit 1; }; done; }

# grab <x> <y> <w> <h> <out>: capture only that rectangle of the focused
# monitor, given in its screenshot pixels, into <out> at exactly <w>x<h>.
# grim takes the region in layout coordinates, so the rectangle is widened
# to whole layout pixels, captured at the monitor's scale, then trimmed.
# Nothing outside it (other windows, other monitors) is ever saved.
grab() {
  local mon geo crop
  mon=$(hyprctl monitors -j | jq -c '[.[] | select(.focused)][0] // empty')
  [[ -n "$mon" ]] || { echo "no focused monitor"; exit 1; }
  read -r geo crop < <(jq -r --argjson x "$1" --argjson y "$2" --argjson w "$3" --argjson h "$4" '
    .scale as $s
    | ($x / $s | floor) as $lx | ($y / $s | floor) as $ly
    | ((($x + $w) / $s | ceil) - $lx) as $lw | ((($y + $h) / $s | ceil) - $ly) as $lh
    | "\(.x + $lx),\(.y + $ly)_\($lw)x\($lh) \($w)x\($h)+\($x - $lx * $s | round)+\($y - $ly * $s | round)"' <<<"$mon")
  grim -s "$(jq -r .scale <<<"$mon")" -g "${geo/_/ }" "$CAPTURE"
  magick "$CAPTURE" -crop "$crop" +repage "$5"
  rm -f -- "$CAPTURE"
}
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

# The parts the panels below share: the header (server, kill switch, IP),
# the torrents line, and the Firefox tunnel's line under it.
draw_top() {
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
  t 32 174 14 "$FG" "$FONT" "$(g 0xF0239)"
  t 60 158 13.8 "$FG" "$FONT" "Firefox: Sweden 21"
  t 60 175 11.3 "$DIM" "$FONT" "198.51.100.61 · Firefox is running inside"
  t 60 190 11.3 "$DIM" "$FONT" "its tunnel"
  t 365 178 16 "$FG" "$FONT" "$(g 0xF018F)"
}
# A switch row's toggle, on: track and knob. toggle <title baseline>
toggle() {
  r 331 $(( $1 + 3 )) 383 $(( $1 + 31 )) "#333646" "#333646" 0
  r 359 $(( $1 + 7 )) 379 $(( $1 + 27 )) "$FG" "$FG" 0
}
render() {  # render <w> <h> <out>: the frame, then everything drawn
  magick -size "$(awk -v k="$K" -v v="$1" 'BEGIN{printf "%d", v*k}')x$(awk -v k="$K" -v v="$2" 'BEGIN{printf "%d", v*k}')" \
    xc:"$BG" -stroke "$ACCENT" -strokewidth "$(awk -v k="$K" 'BEGIN{print 3*k}')" -fill "$BG" \
    -draw "rectangle $(awk -v k="$K" -v w="$1" -v h="$2" 'BEGIN{printf "%d,%d %d,%d", k, k, (w-2)*k, (h-2)*k}')" \
    -stroke none "${draw_args[@]}" "$3"
}

# The panel, shortened to four parts: the header, the torrents line, the
# Firefox line, and the leak check (without the note on its saved report,
# which would push the bar strip out of the two-column card's crop).
draw_panel() {  # draw_panel <scale> <out>
  K="$1"; draw_args=()
  draw_top
  r 19 207 394 207 "$LINE" "$LINE" 1
  t 33 245 14 "$DIM" "$FONT" "$(g 0xF0565)"
  t 60 236 13.8 "$FG" "$FONT" "Check for leaks"
  t 60 253 11.3 "$DIM" "$FONT" "31 checks passed, no leaks found"
  t 365 245 16 "$FG" "$FONT" "$(g 0xF024B)"
  render 412 274 "$2"
}

# The panel with every opt-in on (tests/preview/status-direct.json): the
# header, torrents and Firefox lines, the Chrome direct and SSH direct lines,
# then the panel's last three rows, their switches on.
draw_opt_in() {  # draw_opt_in <scale> <out>
  K="$1"; draw_args=()
  draw_top
  t 33 236 14 "$FG" "$FONT" "$(g 0xF059F)"
  t 60 228 13.8 "$FG" "$FONT" "Chrome: direct"
  t 60 245 11.3 "$DIM" "$FONT" "Your own IP · DNS 127.0.0.1"
  t 33 298 14 "$FG" "$FONT" "$(g 0xF059F)"
  t 60 282 13.8 "$FG" "$FONT" "SSH: direct (port 22)"
  t 60 299 11.3 "$DIM" "$FONT" "Your own IP for new SSH connections · everything"
  t 60 314 11.3 "$DIM" "$FONT" "else follows the bar"
  r 19 335 394 335 "$LINE" "$LINE" 1
  t 33 371 14 "$DIM" "$FONT" "$(g 0xF059F)"
  t 60 362 13.8 "$FG" "$FONT" "Chrome uses your own IP"
  t 60 379 11.3 "$DIM" "$FONT" "Only Chrome skips the VPN. Close Chrome"
  t 60 394 11.3 "$DIM" "$FONT" "to turn this off"
  toggle 362
  t 33 431 14 "$DIM" "$FONT" "$(g 0xF059F)"
  t 60 426 13.8 "$FG" "$FONT" "SSH uses your own IP"
  t 60 443 11.3 "$DIM" "$FONT" "New connections to port 22 skip the VPN"
  toggle 422
  t 33 480 14 "$DIM" "$FONT" "$(g 0xF0208)"
  t 60 475 13.8 "$FG" "$FONT" "Show IP addresses in the bar"
  t 60 492 11.3 "$DIM" "$FONT" "Icons and both addresses"
  toggle 471
  render 412 510 "$2"
}

opt_in() {
  need magick; fonts
  draw_opt_in 3 "$OPT_IN.tmp.png"
  magick "$OPT_IN.tmp.png" -strip -define png:compression-level=9 "$OPT_IN"
  rm -f -- "$OPT_IN.tmp.png"
  echo "wrote $OPT_IN ($(magick identify -format '%wx%h' "$OPT_IN"))"
}

# The widget in the bar: closed lock, regular IP, torrent IP, Firefox IP,
# and the underline the bar draws under a widget whose panel is open.
draw_bar() {  # draw_bar <scale> <out>
  K="$1"; draw_args=()
  t 11 19 12 "$FG" "$FONT" "$(g 0xF033E)"
  t 28 19 13.8 "$FG" "$FONT" "203.0.113.47"
  t 143 19 12 "$FG" "$FONT" "$(g 0xF01DA)"
  t 160 19 13.8 "$FG" "$FONT" "198.51.100.23"
  t 283 19 12 "$FG" "$FONT" "$(g 0xF0239)"
  t 300 19 13.8 "$FG" "$FONT" "198.51.100.61"
  r 130 25 281 26 "$ACCENT" "$ACCENT" 0
  magick -size "$(awk -v k="$K" 'BEGIN{printf "%d", 422*k}')x$(awk -v k="$K" 'BEGIN{printf "%d", 28*k}')" \
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
    -fill "$ACCENT" -annotate +164+860  "$(g 0xF033E)" -fill "$TITLE" -annotate +300+860  "Kill switch" \
    -fill "$ACCENT" -annotate +164+988  "$(g 0xF01DA)" -fill "$TITLE" -annotate +300+988  "Torrent tunnel" \
    -fill "$ACCENT" -annotate +160+1116 "$(g 0xF0239)" -fill "$TITLE" -annotate +300+1116 "Firefox tunnel" \
    -fill "$ACCENT" -annotate +164+1244 "$(g 0xF0565)" -fill "$TITLE" -annotate +300+1244 "Leak checks" \
    -fill "$ACCENT" -annotate +164+1372 "$(g 0xF024B)" -fill "$TITLE" -annotate +300+1372 "Drop-in configs" \
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
  need grim jq hyprctl omarchy omarchy-shell magick; fonts
  [ "$(hyprctl clients -j | jq --argjson w "$WORKSPACE" '[.[] | select(.workspace.id == $w)] | length')" = 0 ] \
    || { echo "workspace $WORKSPACE is not empty; set WORKSPACE to an empty one"; exit 1; }
  local prev ok=0; prev=$(hyprctl activeworkspace -j | jq .id)
  omarchy bar set "$ID" demoStatusFile "$REPO/tests/preview/status.json" >/dev/null
  hyprctl dispatch "hl.dsp.focus({ workspace = \"$WORKSPACE\" })" >/dev/null; sleep 1.2
  omarchy-shell shell summon "$ID" '{}' >/dev/null; sleep 2.5
  [ "$(hyprctl activeworkspace -j | jq .id)" = "$WORKSPACE" ] \
    && grab "$PANEL_X" "$PANEL_Y" "$PANEL_W" 274 "$WORK/panel-real.png" && ok=1
  omarchy-shell shell hide "$ID" >/dev/null 2>&1 || true
  hyprctl dispatch "hl.dsp.focus({ workspace = \"$prev\" })" >/dev/null
  omarchy bar set "$ID" demoStatusFile "" >/dev/null
  (( ok )) || { echo "the workspace changed during the capture; try again"; exit 1; }
  draw_panel 1 "$WORK/panel-1x.png"
  magick "$WORK/panel-real.png" "$WORK/panel-1x.png" +append -scale 300% "$WORK/compare.png"
  echo "captured the panel only: $WORK/panel-real.png; drawn vs real (top rows only): $WORK/compare.png"
}

# The bar alone in four states. Captured at the screen's own resolution,
# nothing scaled up.
bar_states() {
  need grim jq hyprctl omarchy magick; fonts
  local orig
  orig=$(jq -r --arg id "$ID" '[.. | objects | select(.id? == $id) | .showIps][0] // true' "$HOME/.config/omarchy/shell.json")
  shoot() {  # shoot <demo file> <showIps> <name>
    omarchy bar set "$ID" demoStatusFile "$REPO/tests/preview/$1" >/dev/null
    omarchy bar set "$ID" showIps "$2" --json >/dev/null
    sleep 6.5      # one refresh of the widget
    grab "$STRIP_X" 0 "$STRIP_W" "$BAR_H" "$WORK/strip-$3.png"
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
  opt-in) opt_in ;;
  all) compose; cards; opt_in; capture; bar_states ;;
  *) echo "usage: $0 [compose|cards|capture|bar-states|opt-in]"; exit 1 ;;
esac
