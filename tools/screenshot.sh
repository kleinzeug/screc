#!/bin/bash
#
# Captures an App-Store-sized screenshot.
#
#   tools/screenshot.sh <name> [delay] [anchor] [display] [size]
#
#   name     output stem, written to docs/appstore-screenshots/
#   delay    seconds before the shot fires (default 6) — time to open a menu,
#            start a recording, or whatever the shot needs
#   anchor   topright (default) · topleft · top · center
#   display  screencapture display index (default 1 = main)
#   size     2880x1800 · 2560x1600 · 1440x900 · 1280x800 · auto (default)
#
# Why crop rather than capture the whole screen: every accepted App Store size
# is 16:10 while most Macs are 16:9, so a full-screen grab is the wrong shape
# and would need letterboxing. Cropping keeps native pixels — no scaling, no
# bars. The menu-bar item lives top right, hence that default anchor.
#
# "auto" picks the largest accepted size the display can supply. KEEP ONE SIZE
# FOR THE WHOLE SET: App Store Connect wants a consistent size per screenshot
# set, so note what the first shot reports and pass it explicitly thereafter.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="${1:-shot}"
DELAY="${2:-6}"
ANCHOR="${3:-topright}"
DISPLAY_INDEX="${4:-1}"
SIZE="${5:-auto}"
OUT_DIR="docs/appstore-screenshots"
OUT="$OUT_DIR/$NAME.png"
mkdir -p "$OUT_DIR"

FULL=$(mktemp -t screc-shot).png
trap 'rm -f "$FULL"' EXIT

printf 'Arrange the screen now — menus stay open while the timer runs.\n'
printf 'Capturing display %s in %s s …\n' "$DISPLAY_INDEX" "$DELAY"
/usr/sbin/screencapture -x -T "$DELAY" -D "$DISPLAY_INDEX" "$FULL"

[[ -s "$FULL" ]] || {
  echo "capture produced nothing — grant Screen Recording to your terminal" >&2
  exit 1
}

W=$(/usr/bin/sips -g pixelWidth "$FULL" | awk '/pixelWidth/{print $2}')
H=$(/usr/bin/sips -g pixelHeight "$FULL" | awk '/pixelHeight/{print $2}')
echo "  captured ${W}x${H}"

pick_size() {
  # Largest accepted size that fits within the captured pixels.
  for s in 2880x1800 2560x1600 1440x900 1280x800; do
    local tw=${s%x*} th=${s#*x}
    if (( W >= tw && H >= th )); then echo "$s"; return; fi
  done
  echo ""
}

if [[ "$SIZE" == "auto" ]]; then
  SIZE=$(pick_size)
  [[ -n "$SIZE" ]] || {
    echo "  display is smaller than every accepted App Store size (${W}x${H})." >&2
    echo "  Use a larger/Retina display." >&2
    exit 1
  }
fi

TARGET_W=${SIZE%x*}
TARGET_H=${SIZE#*x}
case "$SIZE" in
  2880x1800|2560x1600|1440x900|1280x800) ;;
  *) echo "  $SIZE is not an accepted App Store size" >&2; exit 1 ;;
esac
if (( W < TARGET_W || H < TARGET_H )); then
  echo "  display supplies only ${W}x${H} — too small for ${SIZE}" >&2
  exit 1
fi

# Crop offsets are measured from the top-left of the image.
case "$ANCHOR" in
  topright) OX=$(( W - TARGET_W )); OY=0 ;;
  topleft)  OX=0;                   OY=0 ;;
  top)      OX=$(( (W - TARGET_W) / 2 )); OY=0 ;;
  center)   OX=$(( (W - TARGET_W) / 2 )); OY=$(( (H - TARGET_H) / 2 )) ;;
  *) echo "unknown anchor: $ANCHOR (topright | topleft | top | center)" >&2; exit 1 ;;
esac

/usr/bin/sips -c "$TARGET_H" "$TARGET_W" --cropOffset "$OY" "$OX" "$FULL" --out "$OUT" >/dev/null

PX=$(/usr/bin/sips -g pixelWidth "$OUT" | awk '/pixelWidth/{print $2}')
PH=$(/usr/bin/sips -g pixelHeight "$OUT" | awk '/pixelHeight/{print $2}')
[[ "$PX" == "$TARGET_W" && "$PH" == "$TARGET_H" ]] || {
  echo "  x got ${PX}x${PH}, expected ${SIZE}" >&2; exit 1; }
echo "  OK ${PX}x${PH} — accepted size. USE ${SIZE} FOR EVERY SHOT IN THIS SET."

# App Store artwork should be opaque; flatten if the capture carries alpha.
if [[ "$(/usr/bin/sips -g hasAlpha "$OUT" | awk '/hasAlpha/{print $2}')" == "yes" ]]; then
  TMP="${OUT%.png}.flat.jpg"
  /usr/bin/sips -s format jpeg -s formatOptions 100 "$OUT" --out "$TMP" >/dev/null
  /usr/bin/sips -s format png "$TMP" --out "$OUT" >/dev/null
  rm -f "$TMP"
  echo "  flattened alpha channel"
fi

echo "  $(du -h "$OUT" | cut -f1)  $OUT"
