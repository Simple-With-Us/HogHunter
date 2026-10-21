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
| `HogHunter-Logo-Small-32.svg` | The emblem zoomed to the snout and the tusk, upright, for a 32 px mark. |
| `HogHunter-Icon-Small-16.svg` | The same 16 px snout crop, with the owner's rotation, scale and shift applied, on the owner's rounded tile. |
| `HogHunter-Icon-Small-32.svg` | The same 32 px snout-and-tusk crop, with the owner's rotation, scale and shift applied, on the owner's rounded tile. |
| `preview-small-icons.png` | The small variants at their true pixel size, against the owner's shipped 16 px and 32 px icons. |
| `HogHunter-Favicon-16.svg` | The simplified head, cropped tight, on a 1024 cream field.  For a 16 px favicon. |
| `HogHunter-Favicon-32.svg` | The same drawing with the 32 px crop.  For a 32 px favicon. |
| `HogHunter-Favicon-Tile.svg` | The same drawing on the owner's rounded tile, for a tab that needs a silhouette. |
| `favicon-16.png`, `favicon-32.png`, `favicon-48.png`, `favicon-64.png` | Renders of the favicon at true device pixels. |
| `favicon.ico` | A Windows `.ico` carrying the 16, 32 and 48 px entries. |
| `preview-favicons.png` | The new favicons at true size, against the artwork they replace. |

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

At 16 px and 32 px the whole head does not survive.  Scaled down, the snout, the tusks and the eye all collapse into one brown mass, and the mark stops reading as a boar.  The small variants zoom into the part of the head that still reads.  At 16 px only the snout survives, and at 32 px the snout plus the big tusk does: the tusk is the cue that says boar rather than pig, and it needs the extra pixels that only 32 px and up can spend.

| File | Crop | What survives |
|---|---|---|
| `HogHunter-Logo-Small-16.svg` | the snout | the oval snout, both nostrils, and the cream crescent along its right edge |
| `HogHunter-Logo-Small-32.svg` | the snout and the tusk | the oval snout, both nostrils, the cream crescent, and the big tusk beside it |
| `HogHunter-Icon-Small-16.svg` | the snout, rotated | the same, with the owner's rotation, scale and shift applied, on the rounded tile |
| `HogHunter-Icon-Small-32.svg` | the snout and the tusk, rotated | the same, with the owner's rotation, scale and shift applied, on the rounded tile |

`preview-small-icons.png` shows the owner's shipped 16 px and 32 px icons next to the new variants at their true pixel size, and the same files at full size below.  The 32 px row also shows the earlier face crop, so the change is visible side by side rather than only in the words.

These are **crop windows over the unchanged artwork**, not new drawings.  Every small file carries the same traced paths as `HogHunter-Logo.svg`; the crop is a `translate()` on a wrapper group, so nothing is re-traced and the files still hold up if they are scaled up again.

The crop windows in the owner's 1024 space:

| Variant | Window |
|---|---|
| Logo small 16 | `10, 470, 230, 230` |
| Logo small 32 | `60, 480, 315, 315` |
| Icon small 16 | `-1.559, 553.563, 230, 230` (tile space) |
| Icon small 32 | `60.463, 549.267, 315, 315` (tile space) |

The Icon windows are in **tile space**, the space the owner's `.icns` uses, so the emblem keeps its rotation and its scale inside the crop.  Every small file has a `viewBox` that starts at `0 0` and expresses the crop as a `translate()`, so no file has an offset viewBox.

The Icon variants also carry the owner's rounded tile, clipped to the crop, so a set built from them has one silhouette at every size.  The owner's own iconset entries have transparent rounded corners from 16 px upward, and a square crop would break that; the Logo variants stay flat on cream, like `HogHunter-Logo.svg`.

Each crop is designed for the size it is used at.  The snout crop is a 230 unit window, so at 16 px it still holds its nostril slits and its cream crescent, and it holds at 24 px too, because more pixels fall on each feature.  The 32 px crop is a 315 unit window that adds the big tusk beside the snout, and the tusk is the one cue that says boar rather than pig, but it costs the window a third of the snout's size, so it does not fit below 32 px.  Choose the crop by rendering it at the size it will be used at and looking at those pixels, not by which crop looks best large.

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

Scale that 16x16 PNG up with nearest-neighbour to see what the pixels actually are.  A wide crop of a tusk also reads cleanly at 16 px, as a distinct cream curve, but it reads as a shape rather than as the animal, and a tight crop of the eye comes out as a plain slash.  The snout is the candidate that still reads as a hog, and the same method is how the snout and the snout-and-tusk crops were chosen.

## Favicons

A favicon is not a small app icon.  At 16 device pixels the traced artwork has about 250 of them, and the mane, the brow, the eye and the tusk all land inside the same one or two pixels, so the mark stops being a boar and becomes a brown smudge.  The small variants above solve that by cropping.  The favicon solves it by **simplifying**.

The favicon is the same traced artwork with its contour simplified, cropped to the head and rotated.  Three settings do the work.

| Setting | Value |
|---|---|
| Ramer-Douglas-Peucker epsilon, head contour | 45 logo units |
| Spike filter on the head contour | 30 logo units |
| Rotation | -6 degrees |

The path data in the three favicon SVGs is the `HogHunter-Logo.svg` trace flattened to polygons, simplified by the RDP epsilon and the spike filter listed above, and expressed in one tenth of the master's units.  The logo holds 17 subpaths and 26 cubic curves; each favicon holds 7 subpaths and no curve commands at all, only straight lines.  The favicons also carry the same vertical flip as every other Brand vector.  The master paths live in a y-down space and the logo renders them through `translate(0,1024) scale(0.1,-0.1)`, so a favicon that drops that step draws the boar upside down, with the muzzle sitting high and the mane spikes pointing down.  Each favicon file therefore wraps its drawing in `translate(0,1024) scale(1,-1)` and keeps a `viewBox` that starts at `0 0`.  `HogHunter-Favicon-16.svg` and `HogHunter-Favicon-32.svg` apply the crop as a `translate()` on the group; `HogHunter-Favicon-Tile.svg` additionally scales the drawing by 1.0349 on that group, which is what puts it at 86 per cent of the tile.

The features kept are the head outline, the ear, the eye, the tusk, and the snout with both nostrils.  The cream crescent along the snout is dropped: at 16 px it is a pale wedge that eats the muzzle instead of describing it.

Two alternatives were tried and lost.  **Rotating the unchanged artwork** does not help at any angle, because the smudge rotates with the artwork.  **Cropping into the head** (the face, the front of the muzzle, the muzzle and tusk) puts the crop window inside the head, so the head fills the frame edge to edge and the silhouette disappears; a crop only works when it lands on a part of the drawing that is bounded on both sides.

The RDP epsilon and the spike filter work together.  RDP alone at 45 units keeps the mane as a fringe of separate spikes, and at 16 px that fringe is a row of loose pixels.  The spike filter removes any convex vertex whose height is under 30 units - 0.54 px at the 16 px crop and about 1 px at the 32 px crop - and the outline closes up into one solid mass.

The 16 px and 32 px marks are the same drawing with a different crop padding: 2 per cent for the 16 px mark, so the head fills the pixels it has, and 6 per cent for the 32 px mark, where the extra air stops the tusk from touching the edge.  The tile variant is the same drawing at 86 per cent of the tile, so it keeps the owner's rounded silhouette.

`favicon.ico` is a real ICO container with three 32-bit DIB entries, at 16, 32 and 48 px, and each entry carries exactly the pixels of the matching PNG.  DIB is the right choice here: a PNG-compressed ICO entry is only read by Windows at the 256x256 size, so PNG payloads below that size would be dropped or shown broken in Explorer.  The same reasoning is spelled out in the `.ico` section below.

Rebuild it from the favicon SVGs.  The 16 px entry renders the 16 px mark at 16 px, the 32 px entry renders the 32 px mark at 32 px, and the 48 px entry renders the 16 px mark at 48 px, so each entry keeps the crop it was designed with.  `favicon-64.png` is the 16 px mark at 64 px, for browsers that ask for a larger source.

```bash
magick Brand/HogHunter-Favicon-16.svg -resize 16x16 Brand/favicon-16.png
magick Brand/HogHunter-Favicon-32.svg -resize 32x32 Brand/favicon-32.png
magick Brand/HogHunter-Favicon-16.svg -resize 48x48 Brand/favicon-48.png
magick Brand/HogHunter-Favicon-16.svg -resize 64x64 Brand/favicon-64.png
magick -type TrueColorAlpha \
  Brand/favicon-16.png Brand/favicon-32.png Brand/favicon-48.png \
  Brand/favicon.ico
```

Unlike the `.ico` section below, do not put `-background none` on these renders: `HogHunter-Favicon-16.svg` and `-32.svg` each paint an opaque cream `<rect>` across the whole viewBox, so the flag is a no-op and `favicon-16/32/48/64.png` and every `.ico` entry are opaque cream squares, not a boar silhouette.  The tile variant `HogHunter-Favicon-Tile.svg` is the one that keeps transparent corners; render it with `-background none` to get a transparent PNG.

ImageMagick writes DIB payloads for every entry below 256 px, which is what the file ships.

`preview-favicons.png` shows the new marks at true size, the artwork they replace at the same size, and the same marks in a browser tab on both a light and a dark tab bar.

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

For the two smallest entries, render `HogHunter-Icon-Small-16.svg` as `icon_16x16.png` and `HogHunter-Icon-Small-32.svg` as `icon_32x32.png` instead of scaling the full emblem down.  `icon_16x16@2x.png` is a 32 px entry, so it takes the 32 px variant as well.  Both files carry the rounded tile, so the set keeps one silhouette.

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

`-background none` and `-type TrueColorAlpha` are load bearing.  The first keeps the rounded corners transparent instead of baking a backdrop into the render, and the second keeps the frame direct-class with an alpha channel, which is the form the coder writes as a 32-bit DIB.

In `coders/icon.c` a direct-class frame is written as 32-bit BGRA, and the fourth byte of every pixel is that pixel's alpha, so the antialiased edge of the rounded tile survives in the alpha channel.  The coder also writes the 1-bit AND matte mask, and it sets a bit only where the alpha is exactly transparent, so the mask carries the shape and the alpha channel carries the soft edge.

That coder only switches to a PNG-compressed entry, the `BI_PNG` form, when the image is larger than 256x256, or when the `icon:png-compression-size` option asks for it.  Every entry at or below 256 px is therefore a DIB, which every Windows version reads, and `-compress zip` does not change that for the small entries.

`icotool -c` does the same from a set of rendered PNGs, and it needs the output path and every input, or it writes ICO bytes to stdout.

```bash
icotool -c -o HogHunter.ico icon16.png icon24.png icon32.png icon48.png icon64.png icon128.png icon256.png
```

The Windows `.ico` needs the same treatment as the `.icns`.  The single-source `magick` command above always produces the scaled-down full emblem, which is the exact defect the small variants exist to fix, so build the small entries from the zoomed files instead:

```bash
# 16 px and 24 px from the 16 px snout crop; 32 px from the 32 px snout-and-tusk crop.
# 24 px is below the 32 px crop's design size, and there the snout crop wins:
# rendered at true 24 px the snout keeps its nostril slits and its cream
# crescent, while the wider crop loses the snout's detail to the tusk.
# The larger entries come from the full emblem:
magick -background none Brand/HogHunter-Icon-Small-16.svg -resize 16x16 icon16.png
magick -background none Brand/HogHunter-Icon-Small-16.svg -resize 24x24 icon24.png
magick -background none Brand/HogHunter-Icon-Small-32.svg -resize 32x32 icon32.png
magick -background none Brand/HogHunter-Icon-Rotated.svg -resize 48x48 icon48.png
magick -background none Brand/HogHunter-Icon-Rotated.svg -resize 64x64 icon64.png
magick -background none Brand/HogHunter-Icon-Rotated.svg -resize 128x128 icon128.png
magick -background none Brand/HogHunter-Icon-Rotated.svg -resize 256x256 icon256.png
icotool -c -o HogHunter.ico icon16.png icon24.png icon32.png icon48.png icon64.png icon128.png icon256.png
```

Keep `-background none` on those renders, or the rounded corners of the tile come out white instead of transparent.

`icotool -c` keeps variable transparency in the alpha channel.  When a source PNG carries more than two distinct alpha values, which these renders do because the rounded tile is antialiased, it writes the entry as a 32-bit DIB and the soft edge of the tile survives in that alpha channel.  The 1-bit AND mask only carries transparency for an image whose alpha is binary, so it is not the reason the tile edge would be lost here.

That is why the plain command above is the one to use: every entry is a DIB, and every Windows version reads a DIB.

Passing `-r, --raw=FILENAME` embeds that file's PNG payload verbatim instead.  It is a size and compatibility choice, not a transparency fix, and it has two limits.  Windows decodes a PNG-compressed ICO entry only at 256x256, so a PNG-backed entry below 256 px is ignored or shows as a broken image in Explorer, and the 16, 24 and 32 px entries would be lost.  And `icotool` parses options before positional arguments, so a `--raw` entry lands first in the icon directory and the 256 px entry comes ahead of the smaller ones.

`icotool` itself accepts a raw PNG of any size; the 256x256 limit is on the Windows side of the format, not in the tool.  So the raw form is only worth reaching for on the 256 px entry, and only when that reader is known to want it:

```bash
icotool -c -o HogHunter.ico --raw=icon256.png icon16.png icon24.png icon32.png icon48.png icon64.png icon128.png
```

Neither ImageMagick nor `icotool` is installed on the fleet Mac, so install one before rebuilding.

Render the SVG with a rasterizer that keeps transparency.  Note that `qlmanage -t` renders SVG but flattens transparency onto white, so it is fine for checking the emblem and not for the icon tile.

QuickLook sizes an SVG thumbnail from the content bounding box, and it mis-renders a file whose `viewBox` has an offset: the artwork lands in the top-left corner of the canvas at the wrong size.  Every file here keeps `viewBox` at `0 0` and expresses the crop as a `translate()`, so QuickLook renders them correctly.  Chrome, Safari and every other standards-compliant renderer handle an offset viewBox correctly too.
