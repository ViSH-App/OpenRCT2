# iPad port validation — 2026-10-20

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

## Still requires physical iPad verification

- Direct touch, long press, two-finger navigation, pinch, gesture arbitration during construction, cancelled gestures, and touch keyboard ergonomics. Mac mouse/keyboard operation does **not** validate these.
- Safe-area geometry on real hardware, both landscape directions, keyboard overlap and device rotation.
- Frame pacing, battery/thermal behavior, large parks and long sessions on specific iPad models.
- Background autosave deadlines, system suspension/termination, restoration of the previous pause state, and audio interruption/recovery. The implementation is present; these were not established by the Mac UI tests.
- Audible playback was not independently verified by listening. FLAC/Vorbis are intentionally disabled; original PCM game audio remains supported by the existing mixer.
- Physical installation was not performed in this session. Two paired iPads were detected; the app was built as a signed iPhoneOS arm64 product. Follow README.md to install on the intended device.

This MVP has an English native onboarding/control strip and preserves the game's own localisation/options. Original-data import expects an extracted directory, not an installer executable or ZIP. No App Store packaging, app icon polish, multiplayer or scripting is included. iOS-on-Mac emits system UIKit/Accessibility warnings about deprecated SDL APIs; the verified gameplay and file operations above still completed.

## Evidence locations

- Generated Xcode project: `build/ipad/openrct2.xcodeproj`
- Signed app: `build/ipad/Release-iphoneos/OpenRCT2-iPad.app`
- Exported test save: `build/ios-validation/iPad Final.park`
- Final build/regression logs and runtime log snapshot: `build/ios-validation/`
- Live runtime log: the app's Files-visible `Documents/OpenRCT2-ios.log`

Paths under `build/` are local ignored artifacts. No proprietary game data or save was added to Git.
