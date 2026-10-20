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

The existing OpenRCT2 interface and construction tools are retained. The default interface scale is 1.25 with enlarged controls enabled; use Options → Display to adjust it. Options → Display → Drawing Engine offers **Software** and **Metal**. Software uses the original CPU rasterizer with SDL Metal presentation. Metal uses a native indexed-colour GPU renderer for sprites, palette remapping/filtering, text and weather (see **Metal renderer** below). It composes directly into a canvas matching the physical content viewport (Retina pixels), rather than enlarging the logical game framebuffer. UI layout, park view scale, hit testing and touch coordinates stay in the original logical space. TrueType text is rasterized at the corresponding higher font size while retaining the core’s logical text advances and bounds. Existing installations keep their selected engine; Software remains the default and fallback. Like the desktop OpenGL engine, Metal does not provide LightFX. Game coordinates and input coordinates exclude the native top strip and safe-area insets. Retina pixels are not confused with UIKit points.

- Tap: left click.
- One-finger drag: use the selected tool or drag a game window.
- Two-finger drag: pan the park.
- Pinch: zoom the park view.
- Hold and release: right click / cancel a tool.
- Hold and drag: pan the park.
- Mouse / trackpad: normal OpenRCT2 controls, including right click.

Use the game's normal save and load windows. Saves are stored under `Documents/OpenRCT2/save`. **Files & controls → Import park** copies an external `.park`, `.sv6`, `.sc6`, `.sv4`, or `.sc4` into the sandbox and loads it. **Export saved park** lets you choose a saved `.park` and export a copy via the system picker. All Documents contents are also visible through Files / Finder file sharing. No access to the original external location is needed after importing.

Configuration is kept alongside user data in `Documents/OpenRCT2`, and survives application restarts.

The application pauses the park and audio when entering the background, attempts an autosave for a running park, and restores the previous pause state on foregrounding. Audio interruptions stop playback and resume according to the sound preference. These mechanisms still require validation on physical iPad hardware; force termination does not guarantee a background callback.

## Scope and platform separation

`OPENRCT2_IOS` is defined in the iOS Xcode configuration and the CMake iOS library build. UIKit implementations are in `Platform.iOS.mm` and `UiContext.iOS.mm`; Cocoa, CoreServices/FSEvents and subprocess execution are excluded from this build. Existing macOS, Windows, Linux and Android branches retain their own behavior. Networking, HTTP/version checks, Discord, JavaScript plugins, OpenGL, FLAC and Vorbis are disabled in this MVP. Existing PCM game sounds remain supported. The initial UI language is English; other language selection remains in the game. Simplified Chinese uses bundled Noto Sans CJK SC Regular (OFL license included under data/fonts), so it does not depend on downloadable system fonts. A UIKit scene delegate starts SDL and forwards lifecycle notifications, including on iPadOS 27.

Runtime stdout/stderr is appended to `Documents/OpenRCT2-ios.log`, accessible through Files. Build logs used during development are described in `VALIDATION.md`.

Implementation references: [SDL2 iOS notes](https://wiki.libsdl.org/SDL2/README-ios), [UIKit document picker](https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller).

## Metal renderer

Sources are in `drawing/metal/`:

- `MetalShaderTypes.h`: the draw-command layout, flags and buffer/texture
  bindings, shared by the Objective-C++ code and `MetalShaders.metal`.
- `MetalDrawingContext.*`: records `IDrawingContext` calls as commands in
  logical pixels. The pixel rules follow `X8DrawingContext`. Sprite and text
  positions keep their fractional logical position so they can be sampled at
  Retina density.
- `MetalTextureCache.*`: an R16Uint 2D-array atlas for sprites and TrueType
  coverage, plus the palette-row texture and the TrueType blend table.
- `MetalWeatherDrawer.*`: rain and snow.
- `MetalDrawingEngine.mm`: frames, dirty regions, canvas copies,
  presentation and the GPU comparison.
- `MetalDebugOptions.h`: the developer switches listed below.

### How a frame is drawn

1. The canvas is an R8Uint texture of palette indices at the content viewport's
   physical size. It is kept between frames.
2. `Invalidate` feeds an `InvalidationGrid` with 128-pixel logical blocks.
   `PaintWindows` redraws only the dirty blocks, and `GetFlags` reports
   `dirtyOptimisations`. The whole screen is redrawn when:
   - weather is visible (as in the OpenGL engine);
   - `gPaintForceRedraw` is set;
   - the window has been resized;
   - a GPU frame has failed (for example in the background).
3. `CopyRect` (viewport scrolling):
   - When the raster size is an exact integer multiple of the logical size,
     it blits the canvas.
   - Otherwise a logical shift is not a whole number of raster pixels, so the
     moved area is redrawn. This is the case at the default 1.25 UI scale.
4. Each command is one instance of a quad, drawn into the canvas in a single
   render pass per copy segment:
   - **Destination-independent commands** (fills, sprites, glyphs, unhinted
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
   straight into the drawable. There is no intermediate RGBA texture.

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
  `GfxDrawSpritePaletteSetSoftware`. Sprites without a variant are still
  sampled from the original at native density. `noZoomDraw` is unchanged.
- **Retina TrueType text.** It now follows the same settings as the core's
  logical surfaces:
  - `fonts.enableHinting` and the font's `hinting_threshold` choose light
    hinting with shaded rendering, and set the fill threshold;
  - outline and inset passes use threshold 0, as in
    `X8DrawingContext::DrawTTFBitmap`.

  Previously the threshold was fixed at 64 for every pass.

### Parallel drawing

When multithreading is enabled, the engine reports `parallelDrawing`:

- Each paint thread records into its own list, and every command takes a
  ticket from one atomic counter.
- At the end of the frame the lists are merged in ticket order.
- Concurrent commands come from disjoint viewport columns, so their relative
  order does not matter.
- Cache access is serialised while parallel drawing is in use.

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
| `OPENRCT2_METAL_SERIAL=1` | Do not offer parallel viewport drawing. |

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

For performance testing:

- Set **Frame rate limit = Unrestricted** (`uncap_fps=true`, `use_vsync=false`).
- Keep the app in the foreground.
- Record several scenes over time.

The renderer is compiled only for iPadOS (`OPENRCT2_METAL`). Shaders are
compiled with Xcode's iPhoneOS Metal toolchain into `OpenRCT2.metallib`.
Game screenshots are saved at the canvas's pixel size. Pixel-art assets
keep their original source detail.
