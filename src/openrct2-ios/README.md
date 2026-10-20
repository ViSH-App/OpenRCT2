# Personal iPad app

Open [OpenRCT2.xcodeproj](OpenRCT2.xcodeproj) directly in Xcode. The project and
shared **OpenRCT2** scheme are maintained in this directory and checked into Git;
there is no project-generation step.

This is a UIKit / iPhoneOS arm64 app for landscape iPads and Xcode's **My Mac
(Designed for iPad)** destination on Apple Silicon. It does not use Mac Catalyst
or the simulator.

## Project layout

- `OpenRCT2.xcodeproj`, `OpenRCT2.xcconfig`, `Info.plist`: Xcode application,
  build/signing settings, resources, and launch scheme.
- `IosApplication.mm`, `UiContext.iOS.mm`, `Platform.iOS.mm`: iOS application,
  UIKit integration, and platform services, compiled by Xcode.
- `drawing/metal/`: renderer and Metal shaders, compiled by Xcode. The native
  Metal build phase produces `OpenRCT2.metallib` in the application bundle.
- `CMakeLists.txt`, `cmake/options.cmake`: configuration of the shared C++ static
  libraries consumed by the app. CMake does not create the iOS application target.
- `scripts/`: dependency/asset preparation, incremental native-library build,
  and application resource copying.

The shared engine remains in `src/openrct2` and shared UI in `src/openrct2-ui`.
Their iOS conditionals call the platform implementations in this directory.
[VALIDATION.md](VALIDATION.md) separates historical runtime checks from the
maintained-Xcode-project migration.

## Build

Requirements: Xcode with the iPhoneOS SDK and Metal tools, command line tools
selected with `xcode-select`, CMake 3.24+, Ninja, pkg-config, Python 3.12+, and
internet access for pinned dependencies/assets. A development signing identity
is needed to install and run the app. Homebrew supplies host tools, not iOS
binary libraries.

1. Open `src/openrct2-ios/OpenRCT2.xcodeproj`.
2. Select the **OpenRCT2** scheme and an iPad or **My Mac (Designed for iPad)**.
3. Set your team and bundle identifier in the app target's **Signing &
   Capabilities**. These are normal Xcode project settings; CMake does not
   regenerate or overwrite them.
4. Build and Run. The shared scheme uses Release by default.

The first build prepares missing dependencies and free OpenRCT2 assets, then
builds the C++ libraries with Ninja Multi-Config. Later builds incrementally
rebuild the libraries. The build scripts use Homebrew tools from
`/opt/homebrew/bin` or `/usr/local/bin` as well as Xcode's environment.

Optional preparation before opening Xcode:

```sh
src/openrct2-ios/scripts/prepare.sh
open src/openrct2-ios/OpenRCT2.xcodeproj
```

Preparation builds a native macOS CLI solely to generate repository-matched
graphics, static arm64 iPhoneOS dependencies, and free OpenRCT2 assets. It does
not generate an Xcode project. Proprietary RCT2 resources are never bundled.

Dependency downloads and caches retain their existing locations:
`build/ios-deps`, `build/ipad-host`, `build/ios-font-download`, and `build/ios-data`.
Native libraries use `build/ipad/Debug` or `build/ipad/Release`. When upgrading
from the old CMake-generated application, the native build script refreshes
only `build/ipad`'s CMake generator configuration to use Ninja Multi-Config;
it preserves downloaded dependencies and assets. Use the checked-in project,
not any old generated `.xcodeproj` left in `build/ipad`.
Xcode manages its normal app products and DerivedData location.

Command-line build (does not launch):

```sh
xcodebuild -project src/openrct2-ios/OpenRCT2.xcodeproj -scheme OpenRCT2 \
  -configuration Release -destination 'generic/platform=iOS' \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID PRODUCT_BUNDLE_IDENTIFIER=your.personal.openrct2 \
  -allowProvisioningUpdates build
```

For compile/link/package validation without installation or signing, use
`CODE_SIGNING_ALLOWED=NO` instead of the signing overrides. This does not verify
installation or runtime behavior.

### Install on iPad

Connect and trust the iPad, enable Developer Mode if requested, select your
team and physical iPad in Xcode, then Run. Personal Team installations may need
periodic renewal. The deployment target remains iOS 16.0 and iPad only.

## Import original game data

On first launch, choose **Import RCT2 folder**. In the system file picker, select the installed or unpacked RCT2 directory containing `Data/g1.dat`, `ObjData`, and `Scenarios`. Copy this directory to a location available in Files first if it currently exists only on your Mac. An installer `.exe` cannot be imported directly.

The importer uses security-scoped access and file coordination. It copies the recognised game subdirectories to staging and only then moves the complete import to `Documents/RCT2`. Cancelling or failing an import leaves the original files unchanged. Missing `Data/g1.dat` produces a clear error and allows retrying. Original saves in `Saved Games` are also copied.

## Playing and saving

The existing OpenRCT2 interface and construction tools are retained. The default interface scale is 1.5 with enlarged controls enabled; use Options → Display to adjust it. Interface scales step by 0.5 (1.0, 1.5, 2.0, …) so that every logical pixel is a whole number of physical pixels (2, 3, 4, … on the iPad's 2× display); other values in an older configuration are rounded to the nearest such scale. The logical size is the content viewport divided by that number, and physical pixels left over below one logical pixel stay black at the right and bottom edges. The game is drawn by a native indexed-colour Metal renderer for sprites, palette remapping/filtering, text and weather (see **Metal renderer** below); the iPad build has no other drawing engine, and a `drawing_engine` setting from an older configuration is ignored. It draws the game at its logical resolution, one canvas pixel per logical pixel as in the original software renderer, and shows it scaled by that whole number with nearest-neighbour sampling. UI layout, park view scale, hit testing and touch coordinates use the same logical space.  With the day-night cycle and lighting effects enabled, Metal darkens and lights the park on the GPU (see **Lighting** below); the interface keeps its daylight colours. Game coordinates and input coordinates exclude the native top strip and safe-area insets. Retina pixels are not confused with UIKit points.

- Tap menus and buttons once.
- With a placement tool active, move one finger to position the existing construction preview. Release to inspect it,
  then double-tap near the desired position to place (within 390 ms).
- Hold one finger for 350 ms, then drag to use footpath, land, water, or clear-scenery tools. These use the existing
  tool behavior: ordinary paths are built while painting; area paths are committed on release.
- Drag a window caption or scroll-bar thumb with one finger using the existing UI behavior. Moving one finger over
  the park does not pan it.
- Two-finger drag: pan the park at half sensitivity. Pinch: zoom. Twist during scenery, ride construction, or track-design
  placement: rotate, starting at 15 degrees.
- Two-finger tap on a removable object while the active tool permits removal: secondary action. With the footpath tool
  active, hold two fingers for 350 ms over a removable path, then drag to remove paths continuously.
- Long press for 500 ms outside paint tools: the existing right-click action, which can remove objects in construction
  contexts; it is not a universal cancel command.
- Mouse / trackpad: existing OpenRCT2 controls, including right click. Viewport wheel zoom accumulates four wheel units
  per zoom step; scrolling other controls retains its normal behavior.

These gestures are ported from [OpenRCT2Touch at `5478594`](https://github.com/chrissotraidis/OpenRCT2Touch/tree/5478594ebace99f220fe4c93fe6162bdeea4c69b),
under GPL-3.0. The implementation retains that project's preview/double-tap and hold-to-paint behavior, rather than adding
a separate confirmation panel. SDL finger events are handled in the shared UI; the former UIKit mouse-emulation
recognizers have been removed. Coordinate conversion accounts for this port's native top strip, safe area and interface
scale. Starting a second finger during a tool drag releases the existing drag, including any tool-specific release action.
The source project's device acceptance does not establish physical-touch acceptance for this port.

Use the game's normal save and load windows. Saves are stored under `Documents/OpenRCT2/save`. **Files & controls → Import park** copies an external `.park`, `.sv6`, `.sc6`, `.sv4`, or `.sc4` into the sandbox and loads it. **Export saved park** lets you choose a saved `.park` and export a copy via the system picker. All Documents contents are also visible through Files / Finder file sharing. No access to the original external location is needed after importing.

Configuration is kept alongside user data in `Documents/OpenRCT2`, and survives application restarts.

For testing and measurement, the launch environment variable
`OPENRCT2_IOS_OPEN_PARK` opens a park at startup. It accepts an absolute path, a
path relative to `Documents`, or a file name in `Documents/OpenRCT2/save` (the
`.park` extension may be omitted). Example:
`xcrun devicectl device process launch --device <udid> --environment-variables
'{"OPENRCT2_IOS_OPEN_PARK":"Six Flags Belgium"}' com.xu1s.openrct2`.
Without the variable, startup is unchanged.

The application pauses the park and audio when entering the background, attempts an autosave for a running park, and restores the previous pause state on foregrounding. Audio interruptions stop playback and resume according to the sound preference. These mechanisms still require validation on physical iPad hardware; force termination does not guarantee a background callback.

## Scope and platform separation

`OPENRCT2_IOS` is defined in the iOS Xcode configuration and the CMake iOS library build. UIKit implementations are in `Platform.iOS.mm` and `UiContext.iOS.mm`; Cocoa, CoreServices/FSEvents and subprocess execution are excluded from this build. Existing macOS, Windows, Linux and Android branches retain their own behavior. Networking, HTTP/version checks, Discord, JavaScript plugins, FLAC and Vorbis are disabled in this MVP. There is no OpenGL in the iPad build: the OpenGL drawing engine is compiled out (`DISABLE_OPENGL`), SDL is built with `SDL_OPENGLES=OFF` (Metal video and renderer only), and the app does not link `OpenGLES.framework`. `build-native.sh` rebuilds just SDL if an older preparation still contains OpenGL ES. Existing PCM game sounds remain supported. The initial UI language is English; other language selection remains in the game. Languages the sprite font cannot draw use bundled 12px pixel fonts (licenses included under data/fonts), so they do not depend on downloadable system fonts: Simplified and Traditional Chinese use [WenQuanYi Bitmap Song](http://wenq.org/wqy2/index.cgi?BitmapSong) ([TTF conversion](https://github.com/AmusementClub/WenQuanYi-Bitmap-Song-TTF), GPL v2 with font embedding exception); Japanese uses [Shinonome](http://openlab.ring.gr.jp/efont/shinonome/) 12 dot Mincho (public domain), converted from BDF by `scripts/bdf-to-ttf.py` with a pinned fontTools in a private virtual environment; Korean and Vietnamese use [Galmuri11](https://github.com/quiple/galmuri) (SIL OFL 1.1). Arabic is not offered, because it needs a right-to-left pixel font with joining forms. `scripts/collect-licenses.py` gathers the licenses of everything the app ships into data/licenses for the launcher's 开源许可 page. Being pixel fonts, they are rasterised as monochrome bitmaps without anti-aliasing, and every glyph pixel is shown as an even square of physical pixels. A UIKit scene delegate starts SDL and forwards lifecycle notifications, including on iPadOS 27.

Runtime stdout/stderr is appended to `Documents/OpenRCT2-ios.log`, accessible through Files. Build logs used during development are described in `VALIDATION.md`.

Implementation references: [SDL2 iOS notes](https://wiki.libsdl.org/SDL2/README-ios), [UIKit document picker](https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller).

## Metal renderer

Sources are in `drawing/metal/`:

- `MetalShaderTypes.h`: the draw-command layout, flags and buffer/texture
  bindings, shared by the Objective-C++ code and `MetalShaders.metal`.
- `MetalDrawingContext.*`: records `IDrawingContext` calls as commands in
  logical pixels. The pixel rules follow `X8DrawingContext`: each canvas pixel
  samples a command's source at its top-left corner, and minified sprites start
  on the same whole logical pixel as in `GfxDrawSpritePaletteSetSoftware`.
- `MetalTextureCache.*`: an R16Uint 2D-array atlas for sprites and TrueType
  coverage, plus the palette-row texture and the TrueType blend table.
- `MetalWeatherDrawer.*`: rain and snow.
- `MetalDrawingEngine.mm`: frames, dirty regions, canvas copies,
  presentation and the GPU comparison.
- `MetalDebugOptions.h`: the developer switches listed below.

### How a frame is drawn

1. The canvas is an R8Uint texture of palette indices at the logical size, the
   same image as X8's buffer. It is kept between frames.
2. `Invalidate` feeds an `InvalidationGrid` with 128-pixel logical blocks, as
   X8 does. Smaller blocks redraw much less, but they no longer match a full
   redraw exactly. `OPENRCT2_METAL_VERIFY_DIRTY` showed differences in most
   checked park frames with 16-pixel blocks; see VALIDATION.md.
   `PaintWindows` redraws only the dirty blocks, and `GetFlags` reports
   `dirtyOptimisations`. The whole screen is redrawn when:
   - weather is visible (as in the OpenGL engine);
   - `gPaintForceRedraw` is set;
   - the window has been resized;
   - a GPU frame has failed (for example in the background).
3. `CopyRect` (viewport scrolling) blits the canvas.
4. Each command is one instance of a quad, drawn into the canvas in a single
   render pass per copy segment:
   - **Opaque commands** (plain fills, and the fully opaque interior bands that
     follow each sprite) are drawn first, with a pipeline that has no discard
     path, so the GPU's hidden-surface removal skips everything they hide.
     Discarding shaders defeat hidden-surface removal; profiling showed this
     dominated full-frame cost. An interior band is the sprite's own texels,
     shrunk to whole logical pixels so every covered pixel samples inside
     it. It therefore never changes the image.
   - **Other destination-independent commands** (fills, sprites, glyphs, unhinted
     text) are drawn latest-first. Their depth is the command index (LESS
     test, depth writes on), so earlier commands that are hidden behind them
     are never shaded.
   - **Destination-dependent commands** (palette filters, glass/water blends,
     hinted text) are then drawn in submission order. They use a read-only
     depth test and read the current pixel with framebuffer fetch
     (`[[color(0)]]`). Apple GPUs execute overlapping fragments in primitive
     order, so the result is exactly the painter's algorithm, with no depth
     peeling.
5. One presentation pass looks up the palette for each canvas index and writes
   straight into the drawable, each logical pixel as a square of `scale` ×
   `scale` drawable pixels. There is no intermediate RGBA texture. With the CRT
   effect, the canvas is first decoded into a linear-light texture of the same
   size, the scanline signal.

### Lighting

The day-night cycle and LightFX lights are applied at presentation, to the world only:

- Every command records the world height of the pixels it writes, from the paint struct being
  drawn (`gPaintDrawBounds`: its bounding box's height range and the screen y of its centre at
  height 0). The raster pass writes it to an R32Float texture next to the canvas, kept and moved
  with it. The interface writes a marker instead, and so do other viewports and world pixels
  without a paint struct (darkened, not lit). Glass, water and filters leave the height behind
  them. `RenderTarget::viewport` tells world drawing from the interface.
- The game palette keeps its daylight colours (`LightFx::SetEngineLighting`). The natural light
  of `LightFx::ApplyPaletteFilter` (night colour, fog, light pollution) is computed once per frame
  (`LightFx::ComputeAmbientLight`) and applied per pixel in `shadePixel`; without lighting effects,
  the day-night cycle alone uses the same SoftLight darkening as the palette did.
- Lights are collected while painting (`LightFx::TakeLights`), with a colour by what they belong
  to: path lamps, ride and park entrances, shops and kiosks, vehicles. Each is a quad in a light
  pass that adds LightFx's lantern or spot profile into an RGBA16Float texture, by the distance in
  the world between the light and the pixel (from its height), so light does not spill onto things
  far above or below. Frames with lights repaint the whole screen, since lights are only collected
  where the game paints.
- Lamp light is mixed in as `MixLight` does. With the CRT effect, the shaded colours are the signal.

`OPENRCT2_METAL_SHADED_SHOT=n` saves the shaded canvas every `n` frames (game screenshots are
indexed colour, before shading).

Per-frame command data uses ring buffers, one per frame in flight (three).
Uploads to the atlas and palette textures are staged and encoded as blits at
the start of the frame, so they run after earlier frames have read the
textures.

### Caches

- **Atlas slots.** A slot freed by `InvalidateImage` is reused only after the
  frame has been submitted.
- **Eviction.** Images, TrueType bitmaps and palette rows are evicted
  least-recently-used against fixed budgets:
  - atlas: soft limit 12 layers, hard limit 32 layers (8 MiB each);
  - TrueType bitmaps: 4,096;
  - dynamic palette rows: 1,536.
- **Atlas rebuild.** If the hard limit is reached, the atlas is rebuilt at the
  next frame.

### Alignment with the desktop renderers

- **Zoomed-out sprites.** At zoom > 0, sprites that have pre-minified
  variants (`hasZoomSprite`) use those variants, as in
  `GfxDrawSpritePaletteSetSoftware`. Other sprites take every 2^zoom-th
  texel from the same starting pixel as the software renderer (BMP sprites
  round their left edge up; RLE sprites are moved by 2^zoom − 1 world pixels
  first). `noZoomDraw` is unchanged.
- **TrueType text** uses the core's logical surfaces, with the pass structure
  and hinting thresholds of `X8DrawingContext::DrawTTFBitmap`.
- **Comparison with Software.** Before the software engine was removed from
  the iPad build, game screenshots of both engines, taken at the same tick of
  the same park at zoom 0 to 3, were identical pixel for pixel apart from
  animation frames.

### Parallel drawing

Thread-safe parallel recording is implemented but **off by default**:

- Each paint thread records into its own list, and every command takes a
  ticket from one atomic counter.
- At the end of the frame the lists are merged in ticket order.
- Concurrent commands come from disjoint viewport columns, so their relative
  order does not matter.
- Cache access is serialised while parallel drawing is in use.

On the iPad mini, contention on the ticket counter and the cache lock
roughly doubled CPU paint time in heavy frames, and caused twice as many
dropped frames as serial drawing. `OPENRCT2_METAL_PARALLEL=1` turns it on
when multithreading is enabled.

### Developer switches

Set these in **Product → Scheme → Edit Scheme → Run → Arguments →
Environment Variables**. All are disabled by default. They are read once at
startup, and the renderer only checks whether each one is set. Uncheck a
switch to turn it off; do not set its value to `0`.

| Variable | Effect |
| --- | --- |
| `OPENRCT2_METAL_COMPARE_GPU=1` | Correctness check (see below). Waits for the GPU each frame, so it is not for performance measurements. |
| `OPENRCT2_METAL_RASTER=single` | Draw every command in order through the framebuffer-fetch pipeline (for comparing against the two-pass default). |
| `OPENRCT2_METAL_FULL_REDRAW=1` | Ignore dirty regions; redraw every frame. |
| `OPENRCT2_METAL_PARALLEL=1` | Offer parallel viewport drawing (off by default; see above). |
| `OPENRCT2_METAL_DIRTY_BLOCK=n` | Dirty-region block size in logical pixels (16–256; default 128). |
| `OPENRCT2_METAL_DIRTY_PAD=n` | Expand every invalidated rectangle by `n` logical pixels (default 0). |
| `OPENRCT2_METAL_VERIFY_DIRTY=1` | Every 30th frame, redraw the whole screen into a second canvas within the same frame and compare it with the dirty-region canvas. Logs `Metal dirty verification ... mismatches=`. |
| `OPENRCT2_METAL_INTERIOR=n` | Opaque interior bands per sprite (default 12; 0 disables). |
| `OPENRCT2_METAL_FULL_AREA=f`, `OPENRCT2_METAL_MAX_RECTS=n` | Redraw the whole screen when dirty regions cover at least fraction `f`, or need more than `n` rectangles (off by default; this made pacing worse). |
| `OPENRCT2_METAL_COARSEN=n` | Re-merge dirty regions on a 64-pixel grid above `n` rectangles (off by default; this made pacing worse). |
| `OPENRCT2_METAL_SHADED_SHOT=n` | Every `n` drawn frames, save the shaded canvas (day-night and lights, without CRT) to `Documents/metal-shaded-<frame>.png`. |
| `OPENRCT2_METAL_PROFILE=n` | Fragment-shader profiling variants: 1 skips palette remaps, 3 never discards (deliberately draws a broken image). |

With `OPENRCT2_METAL_COMPARE_GPU=1`, every frame is also drawn by a simple
reference compute rasterizer:

- It uses the same commands and textures, applied in submission order per
  16-pixel tile.
- It writes to its own persistent reference canvas, which receives the same
  canvas copies.
- Every pixel is then compared with the canvas. `Metal native comparison ...
  mismatches=` is logged for each differing frame, and every 60 frames
  otherwise.

The previous logical-resolution software comparator
(`OPENRCT2_METAL_VALIDATE`) has been removed, together with its copy of the
software sprite clipping code.

Every 600 frames, the normal log line `Metal GPU frame=... duration=...`
reports:

- the average and maximum GPU time;
- CPU time per frame, and the encoding time within it;
- the number of commands;
- how many frames were full redraws;
- atlas usage.

`Metal frame timing` gives the GPU-time distribution (mean and
percentiles), frame intervals, hitches over 25 ms and fps, for the last 600
frames and for the whole run. `Metal hitch` lines describe each late frame:
paint, waits, commands, uploads, redraw area and rectangles. The title
sequence changes scenes on wall-clock timers, so compare renderers over whole
title cycles (≥ 5 minutes), not individual frames or screenshots.

A second line, `Metal redraw per frame`, reports the area redrawn per frame (in
screens) by dirty blocks and by full redraws. It also
reports the pixels covered by each pass's quads, which is the fragment
work before depth rejection. The drawable wait (`drawable_wait`) is part of the
encode time, so CPU work per frame is `cpu − drawable_wait`.

For performance testing:

- Set **Frame rate limit = Unrestricted** (`uncap_fps=true`, `use_vsync=false`).
- Keep the app in the foreground.
- Record several scenes over time.

The renderer is compiled only for iPadOS (`OPENRCT2_METAL`). Shaders are
compiled with Xcode's iPhoneOS Metal toolchain into `OpenRCT2.metallib`.
Game screenshots are saved at the logical size, as with the desktop software engine.
