# Hog Hunter Brand

Vector sources for the Hog Hunter boar head artwork.

## Files

| File | What it is |
|---|---|
| `HogHunter-Logo.svg` | The artwork, upright, on a 1024 square cream field. |
| `HogHunter-Logo-Rotated.svg` | The same artwork rotated 9.5 degrees counter-clockwise. |
| `HogHunter-Icon-Rotated.svg` | The icon shape: a rounded tile, the artwork rotated 9.5 degrees counter-clockwise, scaled and positioned to match the owner's `.icns`. |

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

## Rebuilding the icon set

Render the SVG at each size with any rasterizer that keeps transparency, then pack the set with `iconutil`:

```bash
iconutil -c iconset iconset.iconset
iconutil -c icns iconset.iconset -o HogHunter.icns
```

Note that `qlmanage -t` renders SVG but flattens transparency onto white, so it is fine for the square logo and not for the icon tile.
