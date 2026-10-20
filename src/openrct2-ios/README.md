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

The existing OpenRCT2 interface and construction tools are retained. The default interface scale is 1.25 with enlarged controls enabled; use Options → Display to adjust it. Options → Display → Drawing Engine offers **Software** and **Metal**. Software uses the original CPU rasterizer with SDL Metal presentation. Metal uses a native indexed-colour GPU rasterizer for sprites, palette remapping/filtering, text and weather, with a Metal presentation pass. From build 6, Metal composes directly into a render target matching the physical content viewport (Retina pixels), rather than enlarging the logical game framebuffer. UI layout, park view scale, hit testing and touch coordinates stay in the original logical space. TrueType text is rasterized at the corresponding higher font size while retaining the core’s logical text advances and bounds. Existing installations keep their selected engine; Software remains the default and fallback. The first Metal implementation redraws the full frame and does not provide LightFX. Game coordinates and input coordinates exclude the native top strip and safe-area insets. Retina pixels are not confused with UIKit points.

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

## Metal validation

To run the legacy logical-resolution Metal compatibility comparator against the original software drawing commands:

In **Product → Scheme → Edit Scheme → Run → Arguments → Environment
Variables**, enable the existing `OPENRCT2_METAL_VALIDATE=1` entry. It is disabled
by default. Select Metal in the running game. `Documents/OpenRCT2-ios.log` records every mismatch and a zero-mismatch heartbeat every 60 frames. This mode deliberately uses the original logical canvas, software sprite clipping/zoom samples and low-density text, renders twice and waits for GPU completion; it does not validate the new native-density sprite/text path or presentation. Do not use its FPS as normal Metal performance. Disable it before the normal Release run or physical installation:

Uncheck `OPENRCT2_METAL_VALIDATE` in the scheme (do not set its value to `0`;
the renderer checks whether the variable exists).

The native implementation is compiled only for iPadOS (`OPENRCT2_METAL`); it does not replace the macOS OpenGL or software backends. Shaders are compiled with Xcode's iPhoneOS Metal toolchain and bundled as `OpenRCT2.metallib`.

The iPad Display settings show the actual output pixel dimensions in landscape. The game content render target excludes the native controls strip and safe-area margins; its size is logged as `Metal raster=... logical=... drawable=...`. Game screenshots are saved at the content render target’s pixel size. Pixel-art assets retain their original source detail; high-density rendering does not invent new texture detail. Software mode keeps its previous resolution and rendering behavior.

### Native-density optimisation verification

Enabling `OPENRCT2_METAL_COMPARE_GPU=1` in the same Xcode scheme enables a separate GPU-to-GPU check: the optimised occlusion-aware rasterizer and the retained build-6 forward rasterizer draw the **same native-density commands** into separate targets. Every pixel is compared; `Metal native comparison ... mismatches=...` logs every mismatch and a heartbeat every 60 frames. This covers native text/sprite sampling unlike the legacy software comparator. Uncheck both `OPENRCT2_METAL_COMPARE_GPU` and `OPENRCT2_METAL_VALIDATE` for performance measurements. Normal logs report GPU batch duration every 600 frames.

Performance testing must confirm **Frame rate limit = Unrestricted** in the UI (`uncap_fps=true`, `use_vsync=false`), keep the app/window in the foreground, and record multiple scenes over time. A single 60 FPS title screenshot is not evidence of sustained 60 FPS gameplay.
