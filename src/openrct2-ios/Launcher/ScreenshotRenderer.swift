/*****************************************************************************
 * Copyright (c) 2026 OpenRCT2 developers
 * OpenRCT2 is licensed under the GNU General Public License version 3.
 *****************************************************************************/
#if targetEnvironment(simulator)
import SwiftUI
import UIKit

/// App Store screenshots of the launcher, rendered off screen at each target device's exact size, scale,
/// size classes and safe area, so they do not depend on which simulator is installed. Simulator builds only.
///
/// Launch with ORCT_SCREENSHOTS=<directory> and -AppleLanguages (<language>); the app writes
/// <directory>/<device>.png for every device below, then exits.
@available(iOS 17, *) @MainActor
enum ScreenshotRenderer {
    private struct Device {
        let name: String
        let points: CGSize
        let scale: CGFloat
        let horizontal: UserInterfaceSizeClass
        let vertical: UserInterfaceSizeClass
        let safeArea: EdgeInsets
    }

    private static let devices = [
        // iPhone 17 Pro Max, portrait: 1320 × 2868; Dynamic Island and home indicator.
        Device(name: "iphone", points: CGSize(width: 440, height: 956), scale: 3, horizontal: .compact, vertical: .regular,
               safeArea: EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)),
        // iPad Pro 13-inch, landscape: 2752 × 2064; home indicator, status bar hidden.
        Device(name: "ipad", points: CGSize(width: 1376, height: 1032), scale: 2, horizontal: .regular, vertical: .regular,
               safeArea: EdgeInsets(top: 0, leading: 0, bottom: 20, trailing: 0)),
    ]

    nonisolated static var directory: URL? {
        ProcessInfo.processInfo.environment["ORCT_SCREENSHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Shows imported RCT2 data, as after a first import, and renders every device.
    static func run(scene: UIWindowScene, into directory: URL) {
        seedGameData()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Task {
            for device in devices {
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(origin: .zero, size: device.points)
                let host = UIHostingController(rootView: AnyView(
                    LauncherView {}
                        .safeAreaPadding(device.safeArea)
                        .environment(\.horizontalSizeClass, device.horizontal)
                        .environment(\.verticalSizeClass, device.vertical)))
                host.safeAreaRegions = []
                host.view.frame = window.bounds
                window.rootViewController = host
                window.isHidden = false
                // Let the data load, then wait until the coaster train (a 12 s loop) is mid-screen.
                try? await Task.sleep(for: .seconds(1))
                let phase = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 12)
                try? await Task.sleep(for: .seconds((6.5 - phase + 12).truncatingRemainder(dividingBy: 12)))
                host.view.layoutIfNeeded()
                let format = UIGraphicsImageRendererFormat()
                format.scale = device.scale
                format.opaque = true
                // drawHierarchy goes through the render server, which keeps the sprites' nearest-neighbour
                // scaling; layer.render(in:) would smooth them.
                let image = UIGraphicsImageRenderer(size: device.points, format: format).image { _ in
                    _ = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                }
                try? image.pngData()?.write(to: directory.appendingPathComponent("\(device.name).png"))
                window.isHidden = true
            }
            exit(0)
        }
    }

    private static func seedGameData() {
        var info = GameDataInfo(
            slot: .rct2, variant: ORCTRCT2Variant.original.rawValue, source: .init(kind: .folder), sounds: 46, scenarios: 139,
            bytes: 1_253_000_000, importedAt: Date(), detector: GameDataInfo.detectorVersion)
        info.wackyWorlds = 1
        info.timeTwister = 1
        try? FileManager.default.createDirectory(at: GameDataLocation.folder(.rct2), withIntermediateDirectories: true)
        _ = GameDataStore.writeInfo(info)
    }
}
#endif
