#!/bin/bash
#
# Lifts a still frame out of a recording, cropped to an App Store size.
#
#   tools/frame.sh <movie> [seconds] [anchor] [size]
#
#   movie    an .mp4 produced by screc
#   seconds  timestamp to grab (default 2)
#   anchor   topright · topleft · top · center (default center)
#   size     2880x1800 · 2560x1600 · 1440x900 · 1280x800 · auto (default)
#
# Needed because the input visualizations — cursor magnification, click rings,
# scroll wheel, keyboard HUD — are composited INTO the video and deliberately
# never appear on screen. No screenshot of the desktop can show them, so that
# shot has to come from a recorded frame.
set -euo pipefail
cd "$(dirname "$0")/.."

MOVIE="${1:?usage: tools/frame.sh <movie> [seconds] [anchor] [size]}"
AT="${2:-2}"
ANCHOR="${3:-center}"
SIZE="${4:-auto}"
OUT_DIR="docs/appstore-screenshots"
OUT="$OUT_DIR/$(basename "${MOVIE%.*}")-frame.png"
mkdir -p "$OUT_DIR"

[[ -f "$MOVIE" ]] || { echo "no such movie: $MOVIE" >&2; exit 1; }

WORK=$(mktemp -d -t screc-frame)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/extract.swift" <<'SWIFT'
import AVFoundation
import AppKit

let movie = URL(fileURLWithPath: CommandLine.arguments[1])
let seconds = Double(CommandLine.arguments[2]) ?? 2
let output = URL(fileURLWithPath: CommandLine.arguments[3])

let asset = AVURLAsset(url: movie)
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

let semaphore = DispatchSemaphore(value: 0)
var failure: String?
generator.generateCGImageAsynchronously(
    for: CMTime(seconds: seconds, preferredTimescale: 600)
) { image, _, error in
    defer { semaphore.signal() }
    guard let image else {
        failure = error?.localizedDescription ?? "no frame at \(seconds)s"
        return
    }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        failure = "could not encode PNG"; return
    }
    do { try data.write(to: output) } catch { failure = error.localizedDescription }
    print("extracted \(image.width)x\(image.height) at \(seconds)s")
}
semaphore.wait()
if let failure { FileHandle.standardError.write(Data((failure + "\n").utf8)); exit(1) }
SWIFT

echo "Compiling the extractor …"
xcrun swiftc -O "$WORK/extract.swift" -o "$WORK/extract" 2>&1 | grep -E "error" && exit 1 || true
"$WORK/extract" "$MOVIE" "$AT" "$WORK/frame.png"

W=$(/usr/bin/sips -g pixelWidth "$WORK/frame.png" | awk '/pixelWidth/{print $2}')
H=$(/usr/bin/sips -g pixelHeight "$WORK/frame.png" | awk '/pixelHeight/{print $2}')

if [[ "$SIZE" == "auto" ]]; then
  SIZE=""
  for s in 2880x1800 2560x1600 1440x900 1280x800; do
    tw=${s%x*}; th=${s#*x}
    if (( W >= tw && H >= th )); then SIZE=$s; break; fi
  done
  [[ -n "$SIZE" ]] || {
    echo "  frame is ${W}x${H} — smaller than every accepted size." >&2
    echo "  Re-record at a native-resolution preset (Master HEVC)." >&2
    exit 1
  }
fi

TARGET_W=${SIZE%x*}; TARGET_H=${SIZE#*x}
case "$ANCHOR" in
  topright) OX=$(( W - TARGET_W )); OY=0 ;;
  topleft)  OX=0;                   OY=0 ;;
  top)      OX=$(( (W - TARGET_W) / 2 )); OY=0 ;;
  center)   OX=$(( (W - TARGET_W) / 2 )); OY=$(( (H - TARGET_H) / 2 )) ;;
  *) echo "unknown anchor: $ANCHOR" >&2; exit 1 ;;
esac

/usr/bin/sips -c "$TARGET_H" "$TARGET_W" --cropOffset "$OY" "$OX" \
  "$WORK/frame.png" --out "$OUT" >/dev/null

if [[ "$(/usr/bin/sips -g hasAlpha "$OUT" | awk '/hasAlpha/{print $2}')" == "yes" ]]; then
  /usr/bin/sips -s format jpeg -s formatOptions 100 "$OUT" --out "$WORK/flat.jpg" >/dev/null
  /usr/bin/sips -s format png "$WORK/flat.jpg" --out "$OUT" >/dev/null
fi

echo "  OK ${TARGET_W}x${TARGET_H}  $OUT"
