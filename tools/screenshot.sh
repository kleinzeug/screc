#!/bin/bash
#
# Captures an App-Store-sized screenshot: exactly 2880 × 1800 pixels.
#
#   tools/screenshot.sh <name> [delay-seconds] [anchor] [display]
#
#   name     output stem, written to docs/appstore-screenshots/
#   delay    seconds before the shot fires (default 6) — time to open the menu,
#            start a recording, or whatever the shot needs
#   anchor   topright (default) · topleft · top · center
#   display  screencapture display index (default 1 = main)
#
# Why crop rather than capture the whole screen: every accepted App Store size
# is 16:10 (1280×800, 1440×900, 2560×1600, 2880×1800) while most Macs are 16:9,
# so a full-screen grab is the wrong shape and would have to be letterboxed.
# Cropping 2880×1800 out of a Retina capture keeps native pixels — no scaling,
# no bars. The menu-bar item lives top right, hence that default anchor.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="${1:-shot}"
DELAY="${2:-6}"
ANCHOR="${3:-topright}"
DISPLAY_INDEX="${4:-1}"
OUT_DIR="docs/appstore-screenshots"
OUT="$OUT_DIR/$NAME.png"
TARGET_W=2880
TARGET_H=1800
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
echo "  captured ${W}×${H}"

if (( W < TARGET_W || H < TARGET_H )); then
  echo "  display is smaller than ${TARGET_W}×${TARGET_H}; scaling up would look soft." >&2
  echo "  Use a Retina display, or pick a smaller accepted size (1440×900)." >&2
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
if [[ "$PX" == "$TARGET_W" && "$PH" == "$TARGET_H" ]]; then
  echo "  ✓ ${PX}×${PH} — an accepted App Store size"
else
  echo "  ✗ got ${PX}×${PH}, expected ${TARGET_W}×${TARGET_H}" >&2
  exit 1
fi

# App Store artwork should be opaque; flatten if the capture carries alpha.
if [[ "$(/usr/bin/sips -g hasAlpha "$OUT" | awk '/hasAlpha/{print $2}')" == "yes" ]]; then
  TMP="${OUT%.png}.flat.jpg"
  /usr/bin/sips -s format jpeg -s formatOptions 100 "$OUT" --out "$TMP" >/dev/null
  /usr/bin/sips -s format png "$TMP" --out "$OUT" >/dev/null
  rm -f "$TMP"
  echo "  flattened alpha channel"
fi

echo "  $(du -h "$OUT" | cut -f1)  $OUT"
