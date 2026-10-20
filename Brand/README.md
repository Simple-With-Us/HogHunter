# Hog Hunter Brand

Vector sources for the boar head emblem the owner supplied.

These files are the **standalone emblem**: the artwork the owner uses for their own `.ico` and `.icns`.  They are **not** the app icon lockup.  The Finder / About / notification icon in `Assets.xcassets/AppIcon.appiconset` is the square Hog Hunter lockup (boar, wordmark, and the line "Monitor. Detect. Reclaim."), and it stays sourced from its own uncropped artwork, as the "App icon" section of [`docs/DESIGN.md`](../docs/DESIGN.md) requires.

## Files

| File | What it is |
|---|---|
| `HogHunter-Logo.svg` | The emblem, upright, on a 1024 square cream field. |
| `HogHunter-Logo-Rotated.svg` | The same emblem rotated 9.5 degrees counter-clockwise. |
| `HogHunter-Icon-Rotated.svg` | The emblem on a pre-cropped rounded tile (240 px corner radius at 1024, transparent corners), rotated, scaled and shifted to match the owner's `.icns`.  Display only. |
| `HogHunter-Logo-Small-16.svg` | The emblem zoomed to the snout, upright, for a 16 px mark. |
| `HogHunter-Logo-Small-32.svg` | The emblem zoomed to the face, upright, for a 32 px mark. |
| `HogHunter-Icon-Small-16.svg` | The same 16 px snout crop, with the owner's rotation, scale and shift applied, on the owner's rounded tile. |
| `HogHunter-Icon-Small-32.svg` | The same 32 px face crop, with the owner's rotation, scale and shift applied, on the owner's rounded tile. |
| `preview-small-icons.png` | The small variants at their true pixel size, against the owner's shipped 16 px and 32 px icons. |

`HogHunter-Icon-Rotated.svg` already carries the rounded tile, so macOS would apply its system mask a second time if that file were installed as the app icon: the artwork would sit smaller than the mask expects, with corner artifacts inside the squircle.  Use it for a standalone `.icns` or `.ico`, where the tile is wanted.  Do not install it as `Assets.xcassets/AppIcon.appiconset`.

## Provenance

Traced from the owner's own raster artwork with potrace 1.16 (`-u 10 -a 1.0 -O 0.2 -t 4`), not redrawn.  The cream cut-outs inside the head are real vector holes (`fill-rule="evenodd"`), so the file holds up from 16 px to 1024 px.

Fidelity, measured against the owner's own files: the upright vector scores a brown-pixel IoU of 0.996 against the master PNG, and the icon vector scores 0.990 against the owner's `.icns` at 1024.

## Palette

| Role | Hex |
|---|---|
| Cream field | `#FAF2E7` |
| Ink | `#6F390B` |
| Snout shade | `#583110` |

## The rotation

The owner rotated the artwork slightly for the `.ico` and the `.icns`.  That rotation was measured, not guessed.  A scale- and translation-invariant radial-signature match between the master PNG and the owner's `.icns` peaks at **9.5 degrees counter-clockwise**, with a correlation of 0.9994 against 0.599 at zero degrees.

The owner's `.icns` additionally scales the artwork 1.0463x, shifts it by (-11.8, +14.4) px at 1024, and sits it on a rounded-rectangle tile with a 240 px corner radius.  `HogHunter-Icon-Rotated.svg` reproduces all three.

In SVG, a positive `rotate()` is clockwise, so the counter-clockwise rotation is written `rotate(-9.5 512 512)`.

## Small sizes

At 16 px and 32 px the whole head does not survive.  Scaled down, the snout, the tusks and the eye all collapse into one brown mass, and the mark stops reading as a boar.  The small variants zoom into the part of the head that still reads.

| File | Crop | What survives |
|---|---|---|
| `HogHunter-Logo-Small-16.svg` | the snout | the oval snout, both nostrils, and the cream crescent along its right edge |
| `HogHunter-Logo-Small-32.svg` | the face | the snout, the tusks, the eye and the brow |
| `HogHunter-Icon-Small-16.svg` | the snout, rotated | the same, with the owner's rotation, scale and shift applied, on the rounded tile |
| `HogHunter-Icon-Small-32.svg` | the face, rotated | the same, with the owner's rotation, scale and shift applied, on the rounded tile |

`preview-small-icons.png` shows the owner's shipped 16 px and 32 px icons next to the new variants at their true pixel size, and the same files at full size below.

These are **crop windows over the unchanged artwork**, not new drawings.  Every small file carries the same traced paths as `HogHunter-Logo.svg`; the crop is a `translate()` on a wrapper group, so nothing is re-traced and the files still hold up if they are scaled up again.

The crop windows in the owner's 1024 space:

| Variant | Window |
|---|---|
| Logo small 16 | `10, 470, 230, 230` |
| Logo small 32 | `55, 350, 460, 460` |
| Icon small 16 | `-1.559, 553.563, 230, 230` (tile space) |
| Icon small 32 | `47.69, 405.773, 460, 460` (tile space) |

The Icon windows are in **tile space**, the space the owner's `.icns` uses, so the emblem keeps its rotation and its scale inside the crop.  Every small file has a `viewBox` that starts at `0 0` and expresses the crop as a `translate()`, so no file has an offset viewBox.

The Icon variants also carry the owner's rounded tile, clipped to the crop, so a set built from them has one silhouette at every size.  The owner's own iconset entries have transparent rounded corners from 16 px upward, and a square crop would break that; the Logo variants stay flat on cream, like `HogHunter-Logo.svg`.

### Verifying a small size

Render at the true pixel size and inspect the real device pixels.  Do not zoom the vector and judge that instead: a zoomed render is a fresh rasterization, and it hides exactly the detail being judged.

```bash
# 1. A page that shows the file at exactly 16 device pixels.
#    The src is an absolute file:// URL, so the page can live anywhere.
tmpdir="$(mktemp -d)"
BRAND="$(pwd)/Brand"
CHROME_BIN="${CHROME_BIN:?Set CHROME_BIN to the Google Chrome executable}"
cat > "$tmpdir/icon16.html" <<HTML
<html><head><style>html,body{margin:0;padding:0;background:#fff;overflow:hidden}
img{position:absolute;top:0;left:0;width:16px;height:16px}</style></head>
<body><img src="file://$BRAND/HogHunter-Logo-Small-16.svg"></body></html>
HTML
# 2. Screenshot it at 16x16 with no device scaling.
#    --headless=new is the current unified headless mode.
"$CHROME_BIN" --headless=new \
  --disable-gpu --no-sandbox --force-device-scale-factor=1 --virtual-time-budget=4000 \
  --screenshot="$tmpdir/icon16.png" --window-size=16,16 \
  --user-data-dir="$tmpdir/chrome-profile" "file://$tmpdir/icon16.html"
```

Scale that 16x16 PNG up with nearest-neighbour to see what the pixels actually are.  A wide crop of the tusks or the eye reads cleanly at 16 px as well, and the same method is how the snout and the face were chosen.

## Rebuilding a standalone .icns

Render `HogHunter-Icon-Rotated.svg` into a folder with the exact names and pixel sizes `iconutil` requires, then pack it:

```bash
# 1. Render Brand/HogHunter-Icon-Rotated.svg into ./iconset/ with these names:
#      icon_16x16.png (16)    icon_16x16@2x.png (32)
#      icon_32x32.png (32)    icon_32x32@2x.png (64)
#      icon_128x128.png (128) icon_128x128@2x.png (256)
#      icon_256x256.png (256) icon_256x256@2x.png (512)
#      icon_512x512.png (512) icon_512x512@2x.png (1024)
# 2. Pack that folder into an iconset, then into an .icns:
iconutil -c iconset iconset
iconutil -c icns iconset.iconset -o HogHunter.icns
```

`iconutil -c iconset` reads the rendered PNG folder and writes `iconset.iconset`, and `iconutil -c icns` then packs that folder.

For the two smallest entries, render `HogHunter-Icon-Small-16.svg` as `icon_16x16.png` and `HogHunter-Icon-Small-32.svg` as `icon_32x32.png` instead of scaling the full emblem down.  The same applies to `icon_16x16@2x.png` at 32 px.  Both files carry the rounded tile, so the set keeps one silhouette.

## Rebuilding a Windows .ico

A Windows `.ico` is a different container, and `iconutil` cannot write one.  It carries its own size set (16, 24, 32, 48, 64, 128, 256) and none of the `iconutil` naming convention, so build it in one step with a tool that writes ICO.

On macOS use ImageMagick 7's `magick`, never a bare `convert`: `/usr/bin/convert` is the legacy HFS filesystem converter, so a bare `convert` resolves by PATH order and can silently run the wrong tool.  Check which binary is in front first.

```bash
# 1. Confirm which binary is ImageMagick:
command -v magick
# 2. Write the ICO, keeping the alpha on the rounded tile:
magick -background none -type TrueColorAlpha \
  -define icon:auto-resize=16,24,32,48,64,128,256 \
  Brand/HogHunter-Icon-Rotated.svg HogHunter.ico
# 3. Check each entry's payload type and alpha depth:
magick identify -verbose HogHunter.ico
```

`-background none` and `-type TrueColorAlpha` are load bearing.  Without them the ICO coder writes every entry below 256 px as a BMP/DIB whose transparency is only a 1-bit AND mask, which discards the antialiased edge of the rounded tile and leaves hard corners.  Add `-compress zip` if the target reader accepts PNG-backed entries.

`icotool -c` does the same from a set of rendered PNGs, and it needs the output path and every input, or it writes ICO bytes to stdout.

```bash
icotool -c -o HogHunter.ico icon16.png icon24.png icon32.png icon48.png icon64.png icon128.png icon256.png
```

The Windows `.ico` needs the same treatment as the `.icns`.  The single-source `magick` command above always produces the scaled-down full emblem, which is the exact defect the small variants exist to fix, so build the small entries from the zoomed files instead:

```bash
# 16 px straight from the 16 px variant; 24 px and 32 px from the 32 px variant:
magick -background none Brand/HogHunter-Icon-Small-16.svg -resize 16x16 icon16.png
magick -background none Brand/HogHunter-Icon-Small-32.svg -resize 24x24 icon24.png
magick -background none Brand/HogHunter-Icon-Small-32.svg -resize 32x32 icon32.png
icotool -c -o HogHunter.ico icon16.png icon24.png icon32.png icon48.png icon64.png icon128.png icon256.png
```

Keep `-background none` on those renders, or the rounded corners of the tile come out white instead of transparent.

Neither ImageMagick nor `icotool` is installed on the fleet Mac, so install one before rebuilding.

Render the SVG with a rasterizer that keeps transparency.  Note that `qlmanage -t` renders SVG but flattens transparency onto white, so it is fine for checking the emblem and not for the icon tile.

QuickLook sizes an SVG thumbnail from the content bounding box, and it mis-renders a file whose `viewBox` has an offset: the artwork lands in the top-left corner of the canvas at the wrong size.  Every file here keeps `viewBox` at `0 0` and expresses the crop as a `translate()`, so QuickLook renders them correctly.  Chrome, Safari and every other standards-compliant renderer handle an offset viewBox correctly too.
