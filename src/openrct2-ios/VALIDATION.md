# iPad port validation — 2026-10-20

## Metal renderer rearchitecture — status

This is a rewrite of the Metal renderer: instanced quads, framebuffer fetch,
an atlas, dirty regions and parallel drawing. The design is described in
[README.md](README.md#metal-renderer).

**Verified:**

- The Release build passes:

  ```sh
  xcodebuild -project src/openrct2-ios/OpenRCT2.xcodeproj -scheme OpenRCT2 \
    -configuration Release -destination 'generic/platform=iOS' \
    CODE_SIGNING_ALLOWED=NO build
  ```

- A signed build for **My Mac (Designed for iPad)** also compiled.
- The shaders compile with `-std=ios-metal2.3`.
- No core drawing semantics in `src/openrct2` were changed.

**Not yet verified at runtime.** The app has not been run on My Mac or on an
iPad since the rewrite. None of the following has been established yet:

- `OPENRCT2_METAL_COMPARE_GPU` mismatch counts;
- GPU and CPU timings;
- whether two-pass or single-pass rendering is faster;
- the visual effect of the alignment changes (`hasZoomSprite`, TrueType
  hinting thresholds);
- the parallel-drawing CPU benefit.

The earlier Metal results below describe the previous compute rasterizer.

**Expected differences from the previous renderer.** These are intentional
alignment changes. They are not comparison mismatches, because both
rasterizers consume the same commands:

- At zoom > 0, `hasZoomSprite` images use the pre-minified variants.
- Retina TrueType text uses the font's hinting threshold, or 0 when hinting
  is disabled, and solid rendering without hinting.
- Outline and inset passes use threshold 0.

**To record when tested:**

- Title screen and a saved park for several hundred frames with
  `OPENRCT2_METAL_COMPARE_GPU=1`; the mismatch count must be 0.
- The 600-frame `Metal GPU frame=` lines in normal mode, compared with the
  build-7 figure of 11–35 ms on the iPad mini 6.
- The same lines with `OPENRCT2_METAL_RASTER=single` and with
  `OPENRCT2_METAL_SERIAL=1`.


## Maintained Xcode project migration

The application now builds from the checked-in
`src/openrct2-ios/OpenRCT2.xcodeproj`, shared scheme `OpenRCT2`. Xcode compiles
UIKit/platform Objective-C++ and Metal sources, links the CMake-built C++ static
libraries, copies prepared assets, and owns application signing/settings.
CMake uses Ninja Multi-Config for the libraries and no longer generates the app
project. Existing dependency/cache paths were retained.

Validation performed for this migration:

- `xcodebuild -list` reads the app target, shared scheme, Debug and Release
  configurations without generating a project.
- Dependency/asset preparation completed, including the native host graphics
  generator and static iPhoneOS FreeType/SDL/ICU dependencies.
- Full Release compilation, linking, and packaging passed with:

  ```sh
  xcodebuild -project src/openrct2-ios/OpenRCT2.xcodeproj -scheme OpenRCT2 \
    -configuration Release -destination 'generic/platform=iOS' \
    CODE_SIGNING_ALLOWED=NO build
  ```

- A subsequent incremental build passed; Ninja reported `no work to do` for
  the native libraries. The redundant Info.plist device-family declaration was
  removed; Xcode's `TARGETED_DEVICE_FAMILY=2` supplies the verified app value.
- The resulting executable is arm64, platform iOS, minimum OS 16.0. Its dynamic
  dependencies are exclusively system libraries/frameworks, with no host macOS
  or Homebrew dylib paths.
- Bundle identifier `io.openrct2.personal.ipad`, version `0.1.0`, build `7`, and
  iPad-only device family were verified in the built Info.plist.
- `OpenRCT2.metallib`, generated graphics data, and the bundled Chinese font
  are present and nonempty. No proprietary `g1.dat` is bundled.
- Project references, script syntax, include paths, and whitespace checks pass.

Evidence: `build/ios-validation/native-project-{prepare,release,incremental}.log`,
`native-project-list.json`, `native-project-settings.json`, and
`native-project-product.txt` (the latter records the normal Xcode product path).

This migration was validated without signing, installation, or launch. The
runtime/device results below predate the project migration and must not be
interpreted as runtime acceptance of the new Xcode build.

## Verified on My Mac (Designed for iPad)

Host: Apple Silicon MacBookPro18,1, macOS 27.0; Xcode 27.1 (27A9275), iPhoneOS 27.1 SDK. Release build, deployment target iOS 16.0, arm64, UIKit. No simulator or Catalyst was run. The source checkout was initially clean and contained no applicable AGENTS.md. Validation was completed before the playable-baseline commit. No push was performed.

The app was built with `xcodebuild`, installed and launched by Xcode, and operated through computer use. The final Xcode **Build and Run** succeeded after reopening the generated project. During iteration, Run Without Building also installed and ran the already-built application. Running processes were verified under the system `Wrapper/OpenRCT2-iPad.app` installation, rather than the raw build product. `codesign --verify --deep --strict` passed. The installed and built executable SHA-256 matched:

```
2175e1d11ed5ea64c711a46b55865dd19ef81e83e5361a1d9c98b0ae2579c4c6
```

| Check | Observed result |
| --- | --- |
| First launch | Native welcome and system directory picker displayed. |
| Missing resources | Selecting the repository's `data` folder showed “Missing RCT2 data”, explained `Data/g1.dat`, and allowed retrying. |
| Original-data import | Selected the user's GOG unpacked directory through the system picker. The app copied recognised subdirectories into `Documents/RCT2` (677 MiB). Source and imported `g1.dat` and Crazy Castle scenario hashes matched. |
| Resource discovery | Runtime indexed 2,517 objects, 204 track designs and 57 scenarios. Title sequence rendered and animated. |
| Restart | Imported data remained available without reimport. Final configuration fix retained FPS/scale preferences and stopped the initial changelog from reopening each time. |
| Load park | Selected Crazy Castle in the existing new-game scenario list; the park, objective, toolbars, money, date and guests appeared. |
| View navigation | Used zoom buttons and keyboard scrolling to move the live viewport. |
| Basic construction | Used the existing Footpaths tool to place asphalt on owned land; a new path tile appeared and funds changed from ¥1,000,000 to ¥998,800. A mouse drag was exercised; continuous multi-tile touch painting is not established by this test. |
| Staff management | Opened Staff, hired Handyman 1, and verified the count changed from 0 to 1 with the employee visible in the live detail view. |
| Interface scale | Changed 1.25 → 1.50 → 1.25 through Options, with visible corresponding button/text/layout changes. Renderer remained Software. |
| Save | Entered filenames through the game UI and saved `iPad Validation.park`, then `iPad Final.park`. Both files were present in the sandbox. |
| Reload | Restarted the app and loaded the saved park through the in-game load window. The built asphalt path and saved funds remained. |
| Export | Selected `iPad Final.park` and exported through the system save picker to `build/ios-validation/`. |
| Import park | Selected that external exported file through the system picker. The app copied it to `OpenRCT2/save/Imported` and loaded it. |
| Import protection | Final build displayed a replace-current-park prompt. Cancel returned to the current park. |
| Software presentation | Runtime identified the game software rasterizer and SDL Metal presentation. The completed game framebuffer, not game geometry, is sent to Metal. The small park reached 40 FPS while paused; a later active-play snapshot showed 30 FPS after the date progressed from March 8 to March 17 and guests increased from 1 to 9. Transitions and title scenes showed lower snapshots. This is a functional baseline, not a sustained performance benchmark. |
| Desktop regression | The existing macOS CLI/core and all four generated graphics archives rebuilt successfully with the modified platform conditions. Other desktop OSes were not compiled on this host. |

The saved, exported and re-imported `iPad Final.park` files were byte-identical:

```
28677797bc2778c1186fa1872363c12b987860a93c49a968c169909a2ef956de
```

## Problems found and fixed through actual running tests

- CMake's Xcode product reference used executable metadata. Added explicit application type and a bundle PathRunnable so Xcode installs it through Designed for iPad.
- libpng's default framework target was selected despite having a static library. Forced the static archive and disabled PNG_FRAMEWORK in the dependency recipe; the final executable has no external `@rpath` dependency.
- An initial hidden UIWindow was retained after onboarding and interfered with computer-use coordinate targeting. Released it before creating the SDL game window. Subsequent in-game coordinate clicks worked.
- The bundled changelog was missing and opened as an empty panel. Included the repository's changelog and verified rendered text.
- SDL keyboard layout recomputed a portrait-sized view after editing a save filename. Explicit SDL landscape orientations fixed the right-side blank area; typing and saving were repeated with the full landscape view intact.
- Configuration startup and save used different base directories. Kept iOS userConfig and userData together in Documents, matching the current core's Config::Save behavior, and verified restart persistence.

## Physical baseline follow-up

The initial software build was subsequently installed on the selected iPad mini 6 (iPad14,2, iPadOS 27.0.1). Its launch crash was traced to UIKit requiring scene lifecycle adoption, before SDL_main. A custom UIScene entry point and attaching SDL’s window to that scene fixed launch. Release build 2 displayed the live title scene; build 3 bundled the Chinese font. FreeType found all 1,272 distinct Han characters used by the Simplified Chinese catalog, and the user confirmed that the squares were fixed on their device. These fixes are included with the Metal work.

## Still requires physical iPad verification

- Direct touch, long press, two-finger navigation, pinch, gesture arbitration during construction, cancelled gestures, and touch keyboard ergonomics. Mac mouse/keyboard operation does **not** validate these.
- Safe-area geometry on real hardware, both landscape directions, keyboard overlap and device rotation.
- Frame pacing, battery/thermal behavior, large parks and long sessions on specific iPad models.
- Background autosave deadlines, system suspension/termination, restoration of the previous pause state, and audio interruption/recovery. The implementation is present; these were not established by the Mac UI tests.
- Audible playback was not independently verified by listening. FLAC/Vorbis are intentionally disabled; original PCM game audio remains supported by the existing mixer.
- The physical software baseline was installed as described above. New Metal validation is recorded separately below; Mac results do not establish direct-touch behavior.

This MVP has an English native onboarding/control strip and preserves the game's own localisation/options. Original-data import expects an extracted directory, not an installer executable or ZIP. No App Store packaging, app icon polish, multiplayer or scripting is included. iOS-on-Mac emits system UIKit/Accessibility warnings about deprecated SDL APIs; the verified gameplay and file operations above still completed.

## Evidence locations

- Generated Xcode project: `build/ipad/openrct2.xcodeproj`
- Signed app: `build/ipad/Release-iphoneos/OpenRCT2-iPad.app`
- Exported test save: `build/ios-validation/iPad Final.park`
- Final build/regression logs and runtime log snapshot: `build/ios-validation/`
- Live runtime log: the app's Files-visible `Documents/OpenRCT2-ios.log`

Paths under `build/` are local ignored artifacts. No proprietary game data or save was added to Git.

## Native Metal — Mac verification

Release was compiled with Xcode for **My Mac (Designed for iPad)** and launched by Xcode from its system Wrapper installation. Metal appears independently in the Drawing Engine dropdown (including Simplified Chinese). Tests through computer use established:

- Software → Metal → Software → Metal switching without restart, with rendered frames after each change.
- Animated title scenes including water/transparency; loading the existing `iPad Final.park`.
- Park zoom buttons, distant/near views, keyboard viewport movement and UI scale 1.25 → 1.50 → 1.25.
- Simplified Chinese settings, menu, status and save/load text, with no missing-glyph boxes.
- Correct construction-error feedback on an unsuitable slope, followed by two asphalt tiles on flat land (¥979,240 → ¥976,840).
- Save to independent `Metal Validation.park`, then reload through the game UI. The two new tiles, ¥970,320 and April 1 / 22 guests were retained in the paused saved state.
- Indexed-pixel comparison against the original software drawing commands: 315 heartbeat records, no mismatching frames, across title/park/zoom/Chinese/switching tests before the text-cache optimization. Each frame is compared; successful results are only logged every 60 frames.

After caching TTF source coverage, another 3,960 frames (66 zero-mismatch heartbeat records) passed, including cold start, the saved park and Chinese settings. The normal Release launch then confirmed `software comparison=off`; cold start retained Metal and Chinese, and the saved park ran from April 1 / 22 guests to April 5 / 24 guests, including visible rain. Screen snapshots showed 36–41 FPS under the default internal-speed frame limit. This is a short functional sample, not a sustained benchmark. The source cache was 26.1 MiB at both frames 3,000 and 3,600 in that run; no GPU command failures were logged. The macOS CLI/core regression build also passed.

Evidence: `build/ios-validation/metal-build.log`, `metal-comparison.log`, `metal-cache-build.log`, `metal-reloaded.png`. The test-only comparator is opt-in through an Xcode launch environment variable. Production Metal does not CPU-render the game framebuffer. TTF source coverage and compressed sprite assets are decoded/cached on CPU; GPU commands perform the indexed composition.

### Final Release and physical iPad mini

Final `CFBundleVersion` is **4**, iPhoneOS arm64, iPad family only. Strict code-signature verification passed. The Xcode-installed Designed-for-iPad executable matched the Release executable:

```
60c1a77e251f596356a7f7f4ebdcd12462de367043d11e4ec09bcb6c3acafea4
```

Only after Mac testing, the same Release app was installed on the selected physical **iPad mini 6**. The previous configuration was backed up locally, and only `drawing_engine` was changed from `SOFTWARE_HWD` to `METAL`; existing language, preferences, RCT2 data and saves were retained. Device app inventory confirmed bundle version 4, and the running process was verified under the new installation.

The device log reports **Apple A15 GPU, software comparison=off** and progressed through frame 4,800 without GPU command errors. Device screenshots show the animated title parks and Chinese “选项” text. The existing on-device Metal HUD displayed 60 FPS, GPU 6.39 ms in the final snapshot (another scene showed 8.36 ms), application memory about 356 MiB. These are title-scene snapshots, not evidence for all parks, sustained thermals, or touch interaction.

Computer use was available for the Mac application; it did not expose a physical-iPad touch-control surface. Physical validation here therefore covers installation, startup, native Metal rendering, screenshots and logs. Direct touch, construction gestures, file-picker behavior on device, background/suspension and audio interruptions still need hands-on iPad tests. No simulator or Catalyst was used.

Final evidence: `build/ios-validation/metal-release-build.log`, `metal-release-playing.png`, `metal-release-runtime.log`, and `build/ipad-mini-release/{install-metal-build4,launch-metal-build4,apps-metal-build4,processes-metal-build4}.json`, `metal-build4-final.png`, `metal-build4-runtime.log`. The earlier startup screenshot was captured before the final bundle-version metadata refresh; the executable code was unchanged by that refresh.

## Metal presentation sharpness — build 5

A user-reported blur was reproduced at the unchanged 1.25 UI scale. The smooth-nearest presentation shader incorrectly mapped texel interiors towards their boundaries, blending neighbouring colours across the enlarged pixels. Corrected the mapping to keep interiors at texel centres and restrict interpolation to the output-pixel footprint crossing a source-pixel boundary. This fixes presentation filtering; it does not increase the internal canvas resolution or independently rasterize fonts at Retina density.

Release build 5 compiled successfully with Xcode and ran through My Mac (Designed for iPad). Computer use loaded the same paused `Metal Validation.park` and Chinese Display settings for before/after captures; text strokes, icon outlines and terrain pixel detail are visibly sharper at the same size. UI scale 1.25 → 1.50 → 1.25 remained functional. The bundled and Xcode-installed shader-library hashes matched. The earlier indexed-frame comparator runs before this presentation pass and therefore could not detect this filtering error.

Evidence: `build/ios-validation/metal-sharp-build.log`, `metal-blur-before.png`, `metal-blur-after.png`, and their `-detail.png` crops. No simulator was used. After Mac verification, Release build 5 was installed on the physical iPad mini. Device app inventory confirmed build 5; the captured title screen rendered successfully with the corrected filtering, and the runtime log identified native Apple A15 Metal with comparison disabled. See `build/ipad-mini-release/metal-build5-final.png` and `metal-build5-runtime.log`. Existing preferences and user data were preserved. Hands-on touch validation remains outside this screenshot/log check.

## Native Retina composition — build 6

Metal now dispatches one thread per physical content pixel, retaining logical coordinates for commands, UI layout and input. Sprite sampling uses unrounded logical origins and the original sprite assets rather than pre-minified variants. Early testing exposed thin terrain seams from the old integer destination rounding; native sprite/mask coordinates now retain fractional positions until sampling. TrueType text uses separately cached high-density FreeType faces/coverage, with the core's original logical text advances and bounding boxes. The renderer holds its own FreeType reference and bounds its font-face cache. Existing software/OpenGL contexts use the original bitmap path through a default-false optional text hook.

Mac Release validation through computer use confirmed:

- Native game-content raster **2732 × 1960**, output drawable **2732 × 2048**, logical layout **1092 × 784** at 1.25 scale. This is direct composition at native density, not a final-pass upscale.
- Chinese font 12 logical points rendered at 31 raster points; at UI scale 1.50, 37 raster points. Chinese titles, settings, lists, save filename and status text visibly show finer glyph strokes while controls retain their dimensions.
- Display settings read **2732 × 2048**, replacing stale portrait logical dimensions.
- Loaded the same saved park, verified contiguous terrain, zoomed between far and near views, and moved the viewport with keyboard input.
- Placed another asphalt tile at the pointer location (¥970,320 → ¥969,120). Saved as `Retina Validation.park` and reloaded; the tile, funds, April 3 and 23 guests remained.
- UI scale 1.25 → 1.50 → 1.25 and Metal → Software → Metal worked with Chinese text intact.
- In-game screenshot produced a PNG of **2732 × 1960**.
- Title and park snapshots ran around 46–60 FPS after the frame limit was set to unrestricted; these are short functional samples, not sustained or cross-device performance measurements.
- The macOS CLI/core regression build passed. No simulator/Catalyst was used.

Evidence under `build/ios-validation/`: `retina-build.log`, `retina-host-regression.log`, `retina-runtime.log`, `retina-final-settings.png`. The optional legacy logical-resolution comparator does not prove native-density correctness; the native path is covered by actual screenshot/UI tests above.

### Retina on the physical iPad mini

After the Mac tests, Release **build 6** was installed on the same physical iPad mini 6. The device app inventory confirms bundle version 6. Startup uses Apple A15 GPU with comparison disabled. The log reports **2266 × 1360 native content pixels**, **2266 × 1488 drawable pixels**, and **906 × 544 logical layout units** at UI scale 1.25. The missing 128 physical rows are the native control strip/safe-area allocation, not downscaling. The Chinese font is rasterized at 31 points for a 12-point logical font. The first physical title-scene capture shows 60 FPS and 14.72 ms GPU time; it is a short scene sample, not a sustained large-park benchmark.

Existing data, saves, language and user preferences were retained by the update. Device screenshots and the running process were checked after launch. There is still no physical touch-control surface in computer use, so no claim is made for new hands-on gesture, lifecycle or thermal tests. Evidence: `build/ipad-mini-release/retina-build6-{first,final}.png`, `retina-build6-runtime.log`, and build-6 install/launch/apps/processes JSON files.

The final Mac Wrapper executable and signed Release product have matching SHA-256:

```
06d25648fa3c53c7ee24db80453efee771512e213bc56989333d237adf78012a
```

Strict code-signature verification and `git diff --check` passed. No commit or push was made for this work.

## Retina performance follow-up — build 7

The user reported the mini no longer maintained 60 FPS. A foreground device capture reproduced **20.05 FPS / 70.61 ms GPU** with **Unrestricted** visibly selected; a later build-6 scene showed 33.18 FPS / 41.22 ms. This supersedes any impression that the build-6 startup sample established sustained 60 FPS.

The compute rasterizer now walks commands backwards to locate the last fully opaque contribution to a pixel, skips everything hidden behind it, then replays only later destination-dependent effects in painter order. Transparent holes, source remaps, mask pixels, crosshatching, palette filters, water/glass and partially covered text retain their previous semantics. Render resolution and font density are unchanged.

An opt-in native GPU reference path compares the optimised output with the unmodified build-6 forward rasterizer, using the exact same frame commands. **6,060 native frames at 2732 × 1960, zero differing pixels** were recorded on Designed for iPad, including title parks, rain, zoom and Chinese settings. Then comparison was disabled, the app restarted, and the foreground Settings window confirmed Unrestricted. This correctness run is excluded from performance claims.

Build 7 was installed on the mini only after the Mac checks. Device config was re-read: `uncap_fps=true`, `use_vsync=false`. The initial foreground capture showed 60 FPS; GPU log samples were 15.42 and 11.58 ms. The user then opened the problematic scene and confirmed it was ready for continuous sampling. The sustained sampling and user confirmation are recorded below.

Evidence: `build/ios-validation/metal-native-comparison.log`, `metal-perf-build.log`, `metal-perf-foreground-unrestricted.png`, and `build/ipad-mini-release/retina-performance-before.png`, `before-perf-update.png`, `perf-build7-*`. No resolution reduction, simulator, commit or push was used.

### Build 7 follow-up result

After the user confirmed the problematic scene was open in the foreground with Unrestricted selected, nine device screenshots and runtime-log snapshots were collected at roughly 30-second intervals (about four minutes). Sampling ended normally. The user then explicitly confirmed that the frame-rate drops no longer occurred. No further code changes or device restarts were made after that confirmation.

Observed HUD samples (OCR from saved device captures):

| Capture | FPS | GPU |
| --- | --- | --- |
| perf-build7-sample-00.png | 60.00 | 14.89ms |
| perf-build7-sample-01.png | 43.37 | 33.32ms |
| perf-build7-sample-02.png | 49.65 | 26.82ms |
| perf-build7-sample-03.png | 60.00 | 14.65ms |
| perf-build7-sample-04.png | 60.00 | 14.89ms |
| perf-build7-sample-05.png | 60.00 | 14.74ms |
| perf-build7-sample-06.png | 60.00 | 15.08ms |
| perf-build7-sample-07.png | 58.06 | 15.07ms |
| perf-build7-sample-08.png | 52.17 | 0.00ms |

These are sampled HUD readings plus the user’s hands-on confirmation, not a claim that every frame of every park meets 16.67 ms. Runtime logs contain occasional slower GPU frames, including 22–35 ms, which remain in the evidence. Retina density is unchanged. The installed version remains Release build 7.
