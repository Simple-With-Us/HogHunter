# Hog Hunter Brand

Vector sources for the boar head emblem the owner supplied.

These files are the **standalone emblem**:  the artwork the owner uses for their own `.ico` and `.icns`.  They are **not** the app icon lockup.  The Finder / About / notification icon in `Assets.xcassets/AppIcon.appiconset` is the square Hog Hunter lockup (boar, wordmark, and the line "Monitor. Detect. Reclaim."), and it stays sourced from its own uncropped artwork, as the "App icon" section of [`docs/DESIGN.md`](../docs/DESIGN.md) requires.

## Files

| File | What it is |
|---|---|
| `HogHunter-Logo.svg` | The emblem, upright, on a 1024 square cream field. |
| `HogHunter-Logo-Rotated.svg` | The same emblem rotated 9.5 degrees counter-clockwise. |
| `HogHunter-Icon-Rotated.svg` | The emblem on a pre-cropped rounded tile (240 px corner radius at 1024, transparent corners), rotated, scaled and shifted to match the owner's `.icns`.  Display only. |

`HogHunter-Icon-Rotated.svg` already carries the rounded tile, so macOS would apply its system mask a second time if that file were installed as the app icon:  the artwork would sit smaller than the mask expects, with corner artifacts inside the squircle.  Use it for a standalone `.icns` or `.ico`, where the tile is wanted.  Do not install it as `Assets.xcassets/AppIcon.appiconset`.

## Provenance

Traced from the owner's own raster artwork with potrace 1.16 (`-u 10 -a 1.0 -O 0.2 -t 4`), not redrawn.  The cream cut-outs inside the head are real vector holes (`fill-rule="evenodd"`), so the file holds up from 16 px to 1024 px.

Fidelity, measured against the owner's own files:  the upright vector scores a brown-pixel IoU of 0.996 against the master PNG, and the icon vector scores 0.990 against the owner's `.icns` at 1024.

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

## Rebuilding a standalone .icns or .ico

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

Render the SVG with a rasterizer that keeps transparency.  Note that `qlmanage -t` renders SVG but flattens transparency onto white, so it is fine for checking the emblem and not for the icon tile.
