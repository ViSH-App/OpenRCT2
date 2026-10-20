# Personal iPad build

This is a UIKit / iPhoneOS arm64 port of the existing OpenRCT2 C++ application. It supports landscape iPads and Xcode's **My Mac (Designed for iPad)** destination on Apple Silicon. It is not Mac Catalyst. The simulator is not supported or used by this workflow.

## Build

Requirements: Xcode with the iPhoneOS SDK, command line tools selected with `xcode-select`, CMake 3.24+, Ninja, pkg-config, Python 3.12+ (tarfile's safe extraction filter), an Apple Development signing identity, and internet access for the pinned source and asset downloads. Homebrew supplies the host tools, not iOS binary libraries.

From the repository root:

```sh
IOS_DEVELOPMENT_TEAM=YOUR_TEAM_ID scripts/ios/prepare.sh
open build/ipad/openrct2.xcodeproj
```

The script builds a **native macOS CLI solely to generate repository-matched graphics**, builds static arm64 iPhoneOS dependencies from checksum-verified sources, prepares the free OpenRCT2 assets, and generates the Xcode project. Proprietary RCT2 resources are never packaged in the application. Downloaded archives, dependencies and generated products are under the ignored `build/` directory. The existing pinned host dependency package under `lib/macos` also supplies architecture-independent JSON / fmt / RapidJSON headers.

Select scheme **openrct2**, configuration **Release**, and **My Mac (Designed for iPad)**. Use Xcode Run. If Xcode retained a failed build-service session during CMake regeneration, close and reopen this project; alternatively build in Terminal and use Product → Perform Action → Run Without Building. The scheme points at the application bundle so Xcode performs the Designed-for-iPad installation. Do not try to launch the raw iPhoneOS Mach-O executable from Terminal or a standalone debugger.

Command-line build (does not launch):

```sh
xcodebuild -project build/ipad/openrct2.xcodeproj -scheme openrct2 \
  -configuration Release -destination 'platform=macOS,variant=Designed for iPad' \
  -allowProvisioningUpdates build
```

To use a different team or bundle identifier without rebuilding dependencies:

```sh
cmake -S . -B build/ipad -DIOS_DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  -DIOS_BUNDLE_IDENTIFIER=your.personal.openrct2
```

### Install on iPad

Connect and trust the iPad, enable Developer Mode if Xcode requests it, then select the physical iPad as the run destination. In Signing & Capabilities, use your development team and a unique bundle identifier. Use Xcode Run. Personal Team installations may need periodic renewal. There is no App Store distribution step.

If signing is not configured, complete Xcode → Settings → Accounts and select your Apple ID/team. Do not disable signature checks. The iOS deployment target is 16.0 and the device family is iPad only.

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

`OPENRCT2_IOS` is defined only for `CMAKE_SYSTEM_NAME=iOS`. UIKit implementations are in `Platform.iOS.mm` and `UiContext.iOS.mm`; Cocoa, CoreServices/FSEvents and subprocess execution are excluded from this build. Existing macOS, Windows, Linux and Android branches retain their own behavior. Networking, HTTP/version checks, Discord, JavaScript plugins, OpenGL, FLAC and Vorbis are disabled in this MVP. Existing PCM game sounds remain supported. The initial UI language is English; other language selection remains in the game. Simplified Chinese uses bundled Noto Sans CJK SC Regular (OFL license included under data/fonts), so it does not depend on downloadable system fonts. A UIKit scene delegate starts SDL and forwards lifecycle notifications, including on iPadOS 27.

Runtime stdout/stderr is appended to `Documents/OpenRCT2-ios.log`, accessible through Files. Build logs used during development are described in `VALIDATION.md`.

Implementation references: [SDL2 iOS notes](https://wiki.libsdl.org/SDL2/README-ios), [UIKit document picker](https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller), [CMake Xcode product file type](https://cmake.org/cmake/help/latest/prop_tgt/XCODE_EXPLICIT_FILE_TYPE.html).

## Metal validation

To run the legacy logical-resolution Metal compatibility comparator against the original software drawing commands:

```sh
cmake -S . -B build/ipad -DIOS_METAL_VALIDATE=ON
```

This adds `OPENRCT2_METAL_VALIDATE=1` to the Xcode launch scheme. Select Metal in the running game. `Documents/OpenRCT2-ios.log` records every mismatch and a zero-mismatch heartbeat every 60 frames. This mode deliberately uses the original logical canvas, software sprite clipping/zoom samples and low-density text, renders twice and waits for GPU completion; it does not validate the new native-density sprite/text path or presentation. Do not use its FPS as normal Metal performance. Disable it before the normal Release run or physical installation:

```sh
cmake -S . -B build/ipad -DIOS_METAL_VALIDATE=OFF
```

The native implementation is compiled only for iPadOS (`OPENRCT2_METAL`); it does not replace the macOS OpenGL or software backends. Shaders are compiled with Xcode's iPhoneOS Metal toolchain and bundled as `OpenRCT2.metallib`.

The iPad Display settings show the actual output pixel dimensions in landscape. The game content render target excludes the native controls strip and safe-area margins; its size is logged as `Metal raster=... logical=... drawable=...`. Game screenshots are saved at the content render target’s pixel size. Pixel-art assets retain their original source detail; high-density rendering does not invent new texture detail. Software mode keeps its previous resolution and rendering behavior.

### Native-density optimisation verification

`cmake -S . -B build/ipad -DIOS_METAL_COMPARE_GPU=ON` enables a separate GPU-to-GPU check: the optimised occlusion-aware rasterizer and the retained build-6 forward rasterizer draw the **same native-density commands** into separate targets. Every pixel is compared; `Metal native comparison ... mismatches=...` logs every mismatch and a heartbeat every 60 frames. This covers native text/sprite sampling unlike the legacy software comparator. Disable both `IOS_METAL_COMPARE_GPU` and `IOS_METAL_VALIDATE` for performance measurements. Normal logs report GPU batch duration every 600 frames.

Performance testing must confirm **Frame rate limit = Unrestricted** in the UI (`uncap_fps=true`, `use_vsync=false`), keep the app/window in the foreground, and record multiple scenes over time. A single 60 FPS title screenshot is not evidence of sustained 60 FPS gameplay.
