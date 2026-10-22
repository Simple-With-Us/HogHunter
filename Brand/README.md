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
| `HogHunter-Favicon-16.svg` | The reduced contour, cropped tight, on a 1024 cream field.  For a 16 px favicon. |
| `HogHunter-Favicon-32.svg` | The **full traced artwork**, cropped to the owner's own window and turned to the owner's own angle.  For 32 px and up. |
| `HogHunter-Favicon-Tile.svg` | The same full artwork and the same crop on the owner's rounded tile, for a tab that needs a silhouette. |
| `favicon.svg` | The same full artwork, scalable, for browsers that accept a vector favicon. |
| `favicon-16.png`, `favicon-32.png`, `favicon-48.png`, `favicon-64.png` | Renders of the favicon at true device pixels.  16 px is the reduced contour; 32, 48 and 64 px are the full artwork. |
| `favicon-tile-32.png`, `favicon-tile-64.png` | The same full artwork on the rounded tile, with transparent corners. |
| `favicon.ico` | A Windows `.ico` carrying the 16, 32, 48 and 64 px entries. |
| `preview-favicons.png` | The favicons at true size, with the evidence for the one size that cannot carry the full artwork. |

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

A favicon is not a small app icon, and the size it is drawn at decides what it can be.  At 16 device pixels the traced artwork has about 250 of them, and the mane, the brow, the eye and the tusk all land inside the same one or two pixels, so the mark stops being a boar and becomes a brown smudge.

The owner ruled on 2026-10-21 that the favicon should be the master's own artwork.  So the set is split by what each size can actually carry.

| Size | What it carries |
|---|---|
| 16 px | The **reduced contour**: the traced artwork simplified, cropped tight, turned -6 degrees. |
| 32, 48, 64 px and the SVG | The **full artwork**: the master's own path data, untouched, cropped to the owner's own window, at the owner's own 9.5 degree turn. |

### The full artwork, and how it is cropped

The crop is the window the owner's own render was cut to, measured off the rotated master: the snout stops short of the left edge, the ear is cut flat at the top and the mane is cut at the right and at the bottom, so the head fills the frame and the eye, the tusk and the teeth all survive at 32 px.  In the rotated master's canvas that window runs from `(62.2, 123.9)` to `(773.2, 832.9)`, which is 711 by 709 units of the 1024 canvas, about 82 per cent of the artwork's width.  The artwork itself reaches from `(85, 89)` to `(949, 913)` there, so the window misses 176 units of mane on the right, 35 units off the top of the ear and 80 off the lower mane.

There is no padding.  The mark is the owner's own image at 1:1, which is the thing he approved, and the 711 unit wide window is rendered into a 711 unit square.  The window is 711 by 709, so it fills the frame from side to side with nothing at the sides, and sits one unit short of the top and the bottom, which is one unit of background above and below it and under a tenth of a pixel at 32 px.  `HogHunter-Favicon-32.svg` therefore carries a `viewBox` of `0 0 711 711`.

Three things make that work, and all three are easy to get wrong.  The window is **centred** in the frame rather than starting at its corner, so the translate that places it is `(side - w) / 2 - bx0` in x and `(side - h) / 2 - by0` in y, which is `-62.2` and `-122.9` here.  The generator used to compute the offset as the window's centre against the frame's centre and then subtract the window's corner a second time to get the translate, which gave `0` and `-1` instead: the window's left edge landed 62.2 units to the right of where it belongs and its top edge 121.9 units too low, which is 2.8 px across and 5.5 px down at the 32 px render.  The symptom of that mistake is a mark that sits low in its frame: the ear stood whole inside the frame with 88 units of blank canvas above it, about 4 px at the 32 px render, instead of being cut flat at the top, and the lower mane ran off the bottom of the frame.  And the window **cuts** the artwork, so the artwork group carries a `clipPath` whose rect is the window itself.  That clip is what cuts the ear flat, because the correct translate puts the ear's tip 35 units above the window's top edge, which is where the crop says the ear ends.

That clip rect is in the rotated master's canvas space, which is the user space of the `<g>` that carries `clip-path`, and that space is the one the window was measured in and the one the outer translate is applied in.  The same four numbers would mean something else in the root frame, where the window lands at `(0, 1)` to `(711, 710)`.  The viewport cuts at the frame edge, one unit outside the window on the top and the bottom, so the `clipPath` is what makes the visible artwork the window rather than the frame.

No extra rotation is applied on top of the owner's turn, so the artwork keeps the same 9.5 degrees counter-clockwise it has in `HogHunter-Logo-Rotated.svg`, and the mark is the same crop the owner approved.

`HogHunter-Favicon-32.svg` and `favicon.svg` therefore carry the master's own path data: 17 subpaths and 26 cubic curves, the same as `HogHunter-Logo.svg`, with no simplification at all.  The tile variant carries the same artwork and the same crop plus the owner's rounded tile as a separate path, so it holds 18 subpaths and four arc segments.

### Why 16 px is the one size that cannot carry it

At 16 device pixels the eye, the tusk and the teeth of the full artwork each fall below one pixel.  Zooming in does not fix it: a crop tight enough to give those features a pixel each throws the ear and the mane away, so the mark stops being an animal and becomes a brown wedge with a hole in it.  Every crop and every rotation was tried at true 16 px and none of them produced a readable boar, which is why the 16 px frame keeps the reduced contour and the 32 px frame and up do not.

The reduced contour is the same traced artwork with its contour simplified, cropped to the head and rotated.  Three settings do the work.

| Setting | Value |
|---|---|
| Ramer-Douglas-Peucker epsilon, head contour | 45 logo units |
| Spike filter on the head contour | 30 logo units |
| Rotation | -6 degrees |

The path data in `HogHunter-Favicon-16.svg` is the `HogHunter-Logo.svg` trace flattened to polygons, simplified by the RDP epsilon and the spike filter listed above, and expressed in one tenth of the master's units.  The logo holds 17 subpaths and 26 cubic curves; the reduced artwork holds 7 subpaths and no curve commands at all, only straight lines.  It also carries the same vertical flip as every other Brand vector: the master paths live in a y-up space and the logo renders them through `translate(0,1024) scale(0.1,-0.1)`, so a file that drops that step draws the boar upside down, with the muzzle sitting high and the mane spikes pointing down.  `HogHunter-Favicon-16.svg` therefore wraps its drawing in `translate(0,1024) scale(1,-1)` and keeps a `viewBox` that starts at `0 0`.

The features kept are the head outline, the ear, the eye, the tusk, and the snout with both nostrils.  The cream crescent along the snout is dropped: at 16 px it is a pale wedge that eats the muzzle instead of describing it.

Two alternatives were tried and lost.  **Rotating the unchanged artwork** does not help at any angle, because the smudge rotates with the artwork.  **Cropping into the head** (the face, the front of the muzzle, the muzzle and tusk) puts the crop window inside the head, so the head fills the frame edge to edge and the silhouette disappears; a crop only works when it lands on a part of the drawing that is bounded on both sides.

The RDP epsilon and the spike filter work together.  RDP alone at 45 units keeps the mane as a fringe of separate spikes, and at 16 px that fringe is a row of loose pixels.  The spike filter removes any convex vertex whose height is under 30 units - 0.54 px at the 16 px crop and about 1 px at the 32 px crop - and the outline closes up into one solid mass.

The 16 px mark uses 2 per cent crop padding, so the head fills the pixels it has.  The full artwork uses no padding at all, because the owner's own render has none and the frame it is drawn in is square already.  The tile variant puts the same artwork and the same crop on the owner's rounded tile, scaled into the tile's inset square so the cut edges land on the flat of the tile and the rounded corners stay clear.

`favicon.ico` is a real ICO container with four 32-bit DIB entries, at 16, 32, 48 and 64 px, and each entry carries exactly the pixels of the matching PNG.  DIB is the right choice here: a PNG-compressed ICO entry is only read by Windows at the 256x256 size, so PNG payloads below that size would be dropped or shown broken in Explorer.  The same reasoning is spelled out in the `.ico` section below.

The 16 px entry is the reduced contour and the 32, 48 and 64 px entries are the full artwork, so a browser that asks for 48 gets the artwork the owner approved.  `favicon-64.png` is the full artwork at 64 px, for a browser that asks for a larger source.

### Rebuilding them

Render the favicon SVGs at the exact size each file is for, and pack the ICO.  The shipped PNGs were rendered by headless Chrome at a device scale factor of 1, so the output is true device pixels rather than a resize of a large render.

The mark has to be laid out at its true size in the page.  An SVG carries its own `width="1024" height="1024"`, so unless that is rewritten to the target size the browser draws it at 1024 CSS pixels and the screenshot shows the top left corner of it instead of the whole mark.

```bash
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# browser_running() says whether the browser is still running.  A browser
# that has exited but has not been reaped yet is a zombie, and a zombie
# still answers kill -0, so the liveness probe asks for the process state
# as well: a render that finished in two seconds must never look like a
# deadline timeout, because that wastes a second deadline on the retry and
# can fail every size of a rebuild that was working.
browser_running() {  # $1 pid
  kill -0 "$1" 2>/dev/null || return 1
  ps -o stat= -p "$1" 2>/dev/null | grep -qv '^Z'
}

render() {  # $1 svg  $2 px  $3 out  [$4 transparent background]
  tmp="$(mktemp -d)" || tmp=""
  if [ -z "$tmp" ] || [ ! -d "$tmp" ]; then
    echo "render failed: no temporary directory for $1 at $2 px" >&2
    return 1
  fi
  sed "s/width=\"1024\" height=\"1024\"/width=\"$2\" height=\"$2\"/" "$1" > "$tmp/mark.svg"
  printf '<!doctype html><html><head><style>html,body{margin:0;padding:0;background:transparent}svg{display:block}</style></head><body>%s</body></html>' \
    "$(cat "$tmp/mark.svg")" > "$tmp/r.html"
  # --headless=new sometimes hangs and never writes the file, so every render
  # runs under a 90 second deadline and gets one retry.  Each attempt gets its
  # own profile directory, because a killed Chrome leaves a stale singleton
  # lock behind and a retry that reuses that profile can hang the same way.
  # Chrome writes into the temporary directory and the render is published onto
  # its target only after it has been verified, so a failed attempt can
  # neither delete the file already sitting on the target nor leave a
  # truncated one behind.  The publish is staged inside the target's own
  # directory and then renamed onto it, because a move across filesystems is
  # a copy and a unlink, and an interrupted copy truncates the file it is
  # writing over.  Chrome's own output goes to a file as well, and a Chrome
  # killed at the deadline has its helper processes killed with it: those
  # helpers hold the pipe open, which hangs a caller that is reading the
  # output of the block, and they keep burning CPU for the rest of the run,
  # which makes the next render likelier to hang as well.
  status=1
  for attempt in 1 2; do
    out="$tmp/out.png"
    rm -f "$out"
    "$CHROME" --headless=new --disable-gpu --no-sandbox --force-device-scale-factor=1 \
      ${4:+--default-background-color=00000000} \
      --virtual-time-budget=1500 --screenshot="$out" --window-size="$2,$2" \
      --user-data-dir="$tmp/profile-$attempt" "file://$tmp/r.html" \
      > "$tmp/chrome.log" 2>&1 &
    pid=$!
    # date-based deadline: works under any POSIX sh, not only bash (SECONDS
    # is bash-only and silently unset under dash)
    deadline=$(( $(date +%s) + 90 ))
    while browser_running "$pid" && [ "$(date +%s)" -lt "$deadline" ]; do sleep 1; done
    # a browser that is still running here has reached the deadline, so the
    # attempt is a failure whatever it goes on to write, and its helper
    # processes go with it: they hold the pipe open and they keep burning
    # CPU for the rest of the run.  The descendants are killed while the
    # browser is still alive, because a browser that is killed first hands
    # them to init and they are no longer its children.
    timed_out=0
    if browser_running "$pid"; then
      timed_out=1
      pkill -9 -P "$pid" 2>/dev/null
    fi
    kill -9 "$pid" 2>/dev/null
    # any process that still holds the profile goes with it, whether or not
    # it is a child of the browser; the pattern names the profile path
    # rather than the switch, so a helper that carries the profile in some
    # other argument is caught as well
    pkill -9 -f "$tmp/profile-$attempt" 2>/dev/null
    if wait "$pid"; then status=0; else status=$?; fi
    # a browser that was still running at the deadline never finished, so the
    # attempt fails even if it goes on to exit zero after its helpers die
    [ "$timed_out" -eq 1 ] && status=1
    if [ "$status" -eq 0 ] && [ -s "$out" ]; then
      # publish atomically: stage the file inside the target's own directory
      # and rename it onto the target, so an interrupted copy can never
      # truncate the file that is already there
      staged="$(dirname "$3")/.$(basename "$3").render.$$"
      if cp "$out" "$staged" && mv -f "$staged" "$3"; then
        rm -rf "$tmp"
        return 0
      fi
      rm -f "$staged"
      echo "render failed: cannot publish $out onto $3" >&2
      # the log says why the publish failed, and the verified render is kept
      # at a path of its own, because the temporary directory holds a Chrome
      # profile and is not left behind.  The name comes from mktemp, so it
      # is unique and it is created exclusively: a symlink planted under a
      # predictable name in a shared temporary directory is never written
      # through.
      if [ -s "$tmp/chrome.log" ]; then cat "$tmp/chrome.log" >&2; fi
      keep="$(mktemp "${TMPDIR:-/tmp}/hoghunter-favicon-failed-$(basename "$3").XXXXXX" 2>/dev/null)" || keep=""
      if [ -n "$keep" ] && cp "$out" "$keep" 2>/dev/null; then
        echo "render failed: the verified render is kept at $keep" >&2
      else
        echo "render failed: the verified render could NOT be kept" >&2
      fi
      rm -rf "$tmp"
      return 1
    fi
    # a killed attempt can leave a truncated file behind, so clear it before
    # the retry
    rm -f "$out"
  done
  # the log says why the render failed, so it is printed before the temporary
  # directory goes away
  if [ -s "$tmp/chrome.log" ]; then cat "$tmp/chrome.log" >&2; fi
  rm -rf "$tmp"
  echo "render failed: $1 at $2 px" >&2
  return 1
}

rebuild_favicons() {
  # return, not exit: this block is meant to be pasted into an interactive
  # shell, and a failed render must not kill that shell and its session
  # Every size is rendered into a staging directory next to the tracked PNGs,
  # and the tracked PNGs are published only once all six renders have
  # succeeded, so a rebuild that fails halfway leaves the tracked set exactly
  # as it was instead of a mixture of old and new files.
  stage="Brand/.favicon-stage.$$"
  rm -rf "$stage"
  mkdir -p "$stage" || { echo "render failed: cannot create the staging directory $stage" >&2; return 1; }
  render Brand/HogHunter-Favicon-16.svg 16 "$stage/favicon-16.png" || { rm -rf "$stage"; return 1; }
  render Brand/HogHunter-Favicon-32.svg 32 "$stage/favicon-32.png" || { rm -rf "$stage"; return 1; }
  render Brand/HogHunter-Favicon-32.svg 48 "$stage/favicon-48.png" || { rm -rf "$stage"; return 1; }
  render Brand/HogHunter-Favicon-32.svg 64 "$stage/favicon-64.png" || { rm -rf "$stage"; return 1; }
  render Brand/HogHunter-Favicon-Tile.svg 32 "$stage/favicon-tile-32.png" transparent || { rm -rf "$stage"; return 1; }
  render Brand/HogHunter-Favicon-Tile.svg 64 "$stage/favicon-tile-64.png" transparent || { rm -rf "$stage"; return 1; }
  # every render succeeded, so the set can be published; each publish is a
  # rename inside Brand, which is atomic
  for name in favicon-16.png favicon-32.png favicon-48.png favicon-64.png favicon-tile-32.png favicon-tile-64.png; do
    if ! mv -f "$stage/$name" "Brand/$name"; then
      echo "render failed: cannot publish $stage/$name onto Brand/$name" >&2
      rm -rf "$stage"
      return 1
    fi
  done
  rm -rf "$stage"
  return 0
}
rebuild_favicons
```

Eleven details are load bearing.  Chrome composites a headless screenshot onto white by default, so the tile renders need `--default-background-color=00000000` or their transparent corners come out white.  Every render needs its own `--user-data-dir`, and so does every attempt inside one render: sharing one profile across renders makes Chrome hang on a stale singleton lock, and a Chrome killed at the deadline leaves that same stale lock behind, so a retry that reuses that profile can hang exactly the way the first attempt did.  A headless render is not always reliable: `--headless=new` sometimes hangs and never writes the file, so the recipe above gives each attempt a 90 second deadline and one retry on a clean profile, and it returns non-zero when both attempts fail or when the PNG is missing.  The deadline comes from `date +%s` and not from bash's `SECONDS`, so the block runs under a POSIX `sh` as well as under bash: with `SECONDS` the poll loop fails its first comparison in a POSIX shell, kills Chrome straight away, and the recipe can never produce a PNG.  Chrome writes into a temporary directory and the render is published onto its target only after it has been verified, so a failed attempt can neither delete the file already sitting on the target nor leave a truncated one behind, and a file left by an earlier run can never satisfy the size check, because the check is made against the temporary file and never against the target.  The publish is staged inside the target's own directory and then renamed onto it, because `mv` across filesystems is a copy and a unlink: an interrupted copy truncates the file it is writing over, which is the very thing the temporary file was there to prevent.  Every size is rendered into a staging directory next to the tracked PNGs, and the tracked PNGs are published only once all six renders have succeeded, so a rebuild that fails halfway leaves the tracked set exactly as it was rather than a mixture of old and new files, and the `.ico` still carries the pixels of the PNGs it was packed from.  Every `cp` and every `mv` has its status checked, so a publish that fails is reported and stops the rebuild instead of leaving the run green with stale assets, and the verified render is kept at a path of its own, at a name `mktemp` makes unique and exclusive, so a symlink planted under a predictable name in a shared temporary directory is never written through, while the temporary directory, which holds a Chrome profile, is not left behind.  Chrome's own output goes to a file in the temporary directory rather than to the caller's stdout, a Chrome killed at the deadline has its helper processes killed with it, and that log is printed to stderr before the temporary directory is removed, so a failed render says why it failed instead of only that it failed.  The temporary directory is checked before any path is derived from it, because an empty one would turn the render's output into a path at the root of the filesystem.  The renders sit inside a function that returns rather than exiting, so a failed render stops the rebuild and names itself on stderr without closing the shell the block was pasted into, while a script running the block still exits non-zero.  The deadline is 90 seconds and not 30 because a healthy render is not quick and the spread is wide: a single attempt has measured between 2 and 33 seconds on this machine, and a run that completed all six renders has measured between about 17 and 129 seconds end to end, so a 30 second deadline was cutting healthy attempts short and the recipe failed at the 64 px render with no PNG to show for it.  The deadline has a job of its own too: across five timed runs one attempt hung for the full 90 seconds and was killed, the retry failed as well, and the recipe exited 1.  The deadline bounds a hung render rather than a slow one: on a heavily loaded machine a healthy render can take longer than ninety seconds, and the recipe then stops with the tracked set untouched.  An attempt that is still running when the deadline arrives is a failure whatever it goes on to write, and its helper processes are killed with it while it is still alive, because a browser that is killed first hands them to init and they are no longer its children.  The liveness probe asks for the process state as well, because a browser that has exited but has not been reaped yet is a zombie and a zombie still answers `kill -0`, so a render that finished in two seconds is never mistaken for a timeout and never spends a second deadline on the retry.  The old `--headless=old` mode will not screenshot a 16 by 16 window at all, it hangs and never writes the file either.

The pixels do not depend on which of those routes you take.  Every one of the six shipped PNGs has been reproduced by the recipe above, pixel for pixel.  The shipped files themselves were rendered by laying the mark out at its true size inside a 256 by 256 window and cropping the corner back, because that is the window size old headless will accept.

The `.ico` is packed from the PNGs above, with every entry written as a 32-bit DIB so Windows reads real pixels:

```bash
magick -type TrueColorAlpha \
  Brand/favicon-16.png Brand/favicon-32.png Brand/favicon-48.png \
  Brand/favicon-64.png \
  Brand/favicon.ico
```

Pack the `.ico` only after a rebuild that exited zero: a rebuild that failed leaves the tracked PNGs exactly as they were, and packing those would ship an `.ico` older than the artwork.

ImageMagick is also a shorter way to render the marks, and it is what the older entries in this file were built with.  It writes to `im-*.png` on purpose: these are an alternative to the Chrome renders above, not a replacement for them, and a different output path is what keeps them from overwriting the shipped files and desyncing the `.ico`:

```bash
magick Brand/HogHunter-Favicon-16.svg -resize 16x16 Brand/im-favicon-16.png
magick Brand/HogHunter-Favicon-32.svg -resize 32x32 Brand/im-favicon-32.png
magick Brand/HogHunter-Favicon-32.svg -resize 48x48 Brand/im-favicon-48.png
magick Brand/HogHunter-Favicon-32.svg -resize 64x64 Brand/im-favicon-64.png
magick -background none Brand/HogHunter-Favicon-Tile.svg -resize 32x32 Brand/im-favicon-tile-32.png
magick -background none Brand/HogHunter-Favicon-Tile.svg -resize 64x64 Brand/im-favicon-tile-64.png
```

If you want these to become the shipped files, copy them over `favicon-16.png` and the rest and pack the `.ico` again, because the shipped `.ico` carries the exact pixels of the shipped PNGs and not the ones this block produces.

Unlike the `.ico` section below, do not put `-background none` on the first four: `HogHunter-Favicon-16.svg` and `-32.svg` each paint an opaque cream `<rect>` across the whole viewBox, so the flag is a no-op and `favicon-16/32/48/64.png` and every `.ico` entry are opaque cream squares, not a boar silhouette.  The tile variant `HogHunter-Favicon-Tile.svg` is the one that keeps transparent corners; render it with `-background none` to get a transparent PNG.

ImageMagick's `-resize` is a resize of a large render rather than a true-size render, so its pixels differ from the Chrome ones in the antialiasing along the edges.  The shipped PNGs are the Chrome ones.

ImageMagick writes DIB payloads for every entry below 256 px, which is what the file ships.

### Using them

Declare every size a browser may ask for by name, the ICO as the multi-size fallback, and the SVG for the browsers that take a vector:

```html
<link rel="icon" href="/favicon.ico" sizes="16x16 32x32 48x48 64x64">
<link rel="icon" type="image/png" sizes="16x16" href="/favicon-16.png">
<link rel="icon" type="image/png" sizes="32x32" href="/favicon-32.png">
<link rel="icon" type="image/png" sizes="48x48" href="/favicon-48.png">
<link rel="icon" type="image/png" sizes="64x64" href="/favicon-64.png">
<link rel="icon" href="/favicon.svg" type="image/svg+xml" sizes="32x32 48x48 64x64 128x128 256x256">
```

The `sizes` attribute is the hint a browser uses to pick the most appropriate icon, so every size has to be declared.  That is why the 16 px PNG is in the block even though the ICO already carries a 16 px entry: without a `sizes="16x16"` candidate a browser is free to render the full artwork down to a 16 px tab, which is the brown smudge the reduced contour exists to avoid.  The SVG starts at 32 px, which is the smallest size it was drawn for, and it runs up to 256 px because a vector is sharp at any size.

`favicon.ico` carries 16, 32, 48 and 64 px, and it is declared with those four sizes rather than with `sizes="any"`.  `any` tells the browser the resource is good at any size, and the largest bitmap here is 64, so a browser that took it at 128 px would upscale a 64 px image.  Listing the four sizes keeps the choice honest and leaves the large sizes to the vector, which is sharp at them.  The ICO is also the one a crawler gets when it falls back to the root of the host, so its largest entry is 64 rather than 48.

Google Search takes **one** favicon per hostname, and its guidance is a square icon of **at least** 8x8 and **larger than 48x48**, so 64 is the size that meets it.  That is why the ICO's largest entry and the largest PNG are both 64.  Google does not read SVG at all, so the search surface is carried by the PNG and the ICO, and the SVG is for browsers only.

`favicon-tile-32.png` and `favicon-tile-64.png` are the rounded tile with transparent corners, for a surface that wants one silhouette instead of a square.  They are an alternative to the square marks, not an extra size of them, so declare one set or the other rather than both.

`preview-favicons.png` shows the shipped set at true size, the evidence for the 16 px frame, and the same marks in a browser tab.

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
