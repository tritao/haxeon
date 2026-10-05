#!/usr/bin/env bash
set -euo pipefail

module_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
materia_dir=$(dirname "$module_dir")
nativekit_dir=${NATIVEKIT_DIR:-"$materia_dir/nativekit"}
haxeon_dir=${HAXEON_DIR:-"$materia_dir/haxeon"}
build_dir=${NATIVEKIT_BUILD_DIR:-"$nativekit_dir/build-ui"}

for dependency in xvfb-run xdotool import python3; do
    command -v "$dependency" >/dev/null || { echo "Missing $dependency" >&2; exit 1; }
done
python3 -c 'import PIL' || { echo "Missing Python Pillow" >&2; exit 1; }

"$module_dir/tools/showcase.sh" --build-only >/dev/null
capture=$(mktemp --suffix=.png)
trap 'rm -f "$capture"' EXIT

export NKUI_TEST_FONT_PATH=${NKUI_TEST_FONT_PATH:-"$module_dir/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf"}
export NKUI_COLOR_FONT_PATH=${NKUI_COLOR_FONT_PATH:-"$module_dir/vendor/skribidi/example/data/NotoColorEmoji-Regular.ttf"}
export NKUI_SHOWCASE_IMAGE_PATH=${NKUI_SHOWCASE_IMAGE_PATH:-"$nativekit_dir/vendor/sokol/assets/logo_s_large.png"}
export LD_LIBRARY_PATH="$build_dir:$build_dir/nativekit/modules/gpu:$build_dir/nativekit:$haxeon_dir/out:$haxeon_dir/.tools/hashlink:${LD_LIBRARY_PATH:-}"
export INSPECTOR_CAPTURE="$capture"
export INSPECTOR_ARTIFACT="$build_dir/nativekit_ui_showcase.hl"
export INSPECTOR_HAXEON_DIR="$haxeon_dir"

xvfb-run -a bash -c '
    cd "$INSPECTOR_HAXEON_DIR/out"
    "$INSPECTOR_HAXEON_DIR/.tools/hashlink/hl" "$INSPECTOR_ARTIFACT" \
        --ui-visual-case=34 --ui-visual-frames=1000 >/dev/null 2>&1 &
    app_pid=$!
    trap '\''kill "$app_pid" 2>/dev/null || true; wait "$app_pid" 2>/dev/null || true'\'' EXIT
    for attempt in {1..50}; do
        window_id=$(xdotool search --name "Haxeon UI Explorer" | head -n 1 || true)
        [[ -z "$window_id" ]] || break
        sleep 0.1
    done
    [[ -n "$window_id" ]] || { echo "Showcase window did not open" >&2; exit 1; }
    sleep 1
    import -display "$DISPLAY" -window "$window_id" "$INSPECTOR_CAPTURE"
'

python3 - "$capture" <<'PY'
import sys
from PIL import Image

image = Image.open(sys.argv[1]).convert("RGB")
if image.size != (1280, 900):
    raise SystemExit(f"Unexpected showcase size: {image.size}")

def luminance(pixel):
    channels = [value / 255 for value in pixel]
    linear = [value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4 for value in channels]
    return sum(weight * value for weight, value in zip((0.2126, 0.7152, 0.0722), linear))

background = luminance(image.getpixel((450, 267)))
if background < 0.9:
    raise SystemExit("Property input background is not a light surface")

for label, y in (("1.5", 267), ("Blue box", 309), ("#458AFF", 351), ("disabled 0.1", 423)):
    pixels = [image.getpixel((x, row)) for row in range(y - 10, y + 10) for x in range(265, 355)]
    dark = [pixel for pixel in pixels if luminance(pixel) < 0.25]
    if len(dark) < (10 if label.startswith("disabled") else 20):
        raise SystemExit(f"{label} has too few visible text pixels: {len(dark)}")
    darkest = min(map(luminance, pixels))
    contrast = (background + 0.05) / (darkest + 0.05)
    if contrast < 4.5:
        raise SystemExit(f"{label} contrast is only {contrast:.2f}:1")

print("PASS: enabled and disabled Inspector values are readable in the light theme")
PY
