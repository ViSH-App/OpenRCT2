/*****************************************************************************
 * Copyright (c) 2026 OpenRCT2 developers
 * OpenRCT2 is licensed under the GNU General Public License version 3.
 *****************************************************************************/
import SwiftUI
import UIKit

/// An isometric park (grass, paths, a lake and trees) drawn in RCT2 palette colours, one game pixel per image pixel.
enum ParkBackground {
    // NSCache is thread-safe.
    nonisolated(unsafe) private static let cache = NSCache<NSNumber, CGImage>()

    static func image(side: Int) -> CGImage? {
        if let cached = cache.object(forKey: side as NSNumber) { return cached }
        let image = render(side: side)
        if let image { cache.setObject(image, forKey: side as NSNumber) }
        return image
    }

    private static func hash(_ a: Int, _ b: Int) -> Double {
        var h = UInt32(truncatingIfNeeded: a &* 374_761_393 &+ b &* 668_265_263) ^ 0x5bd1_e995
        h = (h ^ (h >> 13)) &* 1_274_126_177
        return Double(h ^ (h >> 16)) / Double(UInt32.max)
    }

    private enum Tile { case grass, path, water }

    private static func render(side: Int) -> CGImage? {
        let grass: [UInt32] = [0x476f2b, 0x577f33, 0x638f3b, 0x739b43, 0x83ab4b]
        let path: [UInt32] = [0x5b7373, 0x6f8383, 0x839797, 0x9fafaf]
        let water: [UInt32] = [0x076b63, 0x177f77, 0x2b938f, 0x47a7a3, 0x63bbbb]
        let flowers: [UInt32] = [0xffe72f, 0xff7b73, 0xeff3f3, 0xab7fd7]
        let width = side, height = side
        var pixels = [UInt32](repeating: 0, count: width * height)

        func tile(_ u: Int, _ v: Int) -> Tile {
            let wu = Double(u - 12), wv = Double(v + 1)
            if wu * wu * 0.8 + wv * wv * 1.6 < 7 { return .water }
            if (v == 5 && u > 2 && u < 20) || (u == 7 && v > -8 && v < 6) { return .path }
            return .grass
        }
        func tileAt(_ x: Int, _ y: Int) -> (Tile, Int, Int, Double, Double) {
            let a = Double(x) / 64 + Double(y) / 32, b = Double(y) / 32 - Double(x) / 64 + 20
            let u = Int(a.rounded(.down)), vb = Int(b.rounded(.down))
            return (tile(u, vb - 20), u, vb - 20, a - Double(u), b - Double(vb))
        }

        for y in 0..<height {
            for x in 0..<width {
                let (kind, u, v, fa, fb) = tileAt(x, y)
                let r = hash(x, y)
                var colour: UInt32
                switch kind {
                case .water:
                    let ripple = (x + ((y >> 1) % 4) * 3) % 11 < 2
                    colour = water[ripple ? 4 : (r < 0.15 ? 3 : 2)]
                case .path:
                    colour = path[r < 0.25 ? 1 : (r < 0.85 ? 2 : 3)]
                    if fa < 0.035 || fb < 0.035 { colour = path[0] }
                case .grass:
                    let shade = 1 + Int(hash(u * 7, v * 13) * 2) + (r < 0.18 ? -1 : (r > 0.86 ? 1 : 0))
                    colour = grass[max(0, min(4, shade))]
                    if r > 0.9975 { colour = flowers[Int(hash(x + 1, y) * 4) % 4] }
                }
                pixels[y * width + x] = 0xFF00_0000 | colour
            }
        }

        // Conifers, back to front.
        func put(_ x: Int, _ y: Int, _ colour: UInt32) {
            guard x >= 0, y >= 0, x < width, y < height else { return }
            pixels[y * width + x] = 0xFF00_0000 | colour
        }
        let treeCount = side * side / 3200
        var trees: [(Int, Int, Int)] = []
        for i in 0..<treeCount {
            let x = Int(hash(i, 91) * Double(width)), y = Int(hash(i, 17) * Double(height))
            if tileAt(x, y).0 == .grass { trees.append((x, y, 4 + Int(hash(i, 5) * 4))) }
        }
        for (x, y, size) in trees.sorted(by: { $0.1 < $1.1 }) {
            for dx in 0..<2 { for dy in 0..<4 { put(x + dx, y - 3 + dy, 0x5b3f1f) } }
            for k in 0..<(size * 2) {
                let half = max(1, (k + 2) / 2), row = y - 3 - size * 2 + k
                for dx in (1 - half)...(half) { put(x + dx, row, k % 3 == 0 ? 0x2f633b : 0x23532b) }
                put(x + 1 - half, row, 0x3b734b)
                put(x + half, row, 0x17471f)
            }
        }

        // Pixels are 0xAARRGGBB; on little-endian that is BGRA in memory.
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

struct ParkView: View {
    @State private var image: CGImage?
    var body: some View {
        GeometryReader { proxy in
            let side = Int(max(proxy.size.width, proxy.size.height) / px) + 2
            ZStack {
                Palette.grass
                if let image {
                    Image(decorative: image, scale: 1 / px).interpolation(.none)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
            }
            .task(id: side) {
                image = await Task.detached(priority: .userInitiated) { ParkBackground.image(side: side) }.value
            }
        }
        .ignoresSafeArea()
    }
}

/// The loading-window roller coaster (ProgressWindow's g2 sprites), tiled across the given width.
struct Coaster: View {
    enum Style { case steel, wooden }
    var style: Style = .steel
    /// Position of the train from 0 to 1, or nil to keep it riding.
    var progress: Double?

    private var parts: (track: String, supports: String, vehicle: String, trackY: CGFloat, supportsY: CGFloat) {
        switch style {
        case .steel: ("steel_track", "steel_supports", "steel_vehicle", 16, 27)
        case .wooden: ("wood_track", "wood_supports", "wood_vehicle", 3, 3)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let p = parts
            ZStack(alignment: .topLeading) {
                strip(p.supports).offset(y: p.supportsY * px)
                strip(p.track).offset(y: p.trackY * px)
                if let vehicle = Sprites.image(p.vehicle) {
                    if let progress {
                        Image(uiImage: vehicle).interpolation(.none)
                            .offset(x: snap(proxy.size.width * progress - vehicle.size.width / 2))
                    } else {
                        TimelineView(.animation) { timeline in
                            let span = proxy.size.width + vehicle.size.width
                            let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 12) / 12
                            Image(uiImage: vehicle).interpolation(.none)
                                .offset(x: snap(span * t - vehicle.size.width))
                        }
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
        }
        .frame(height: 124)
        .accessibilityHidden(true)
    }

    private func snap(_ value: CGFloat) -> CGFloat { (value / px).rounded(.down) * px }

    @ViewBuilder private func strip(_ name: String) -> some View {
        if let image = Sprites.image(name) {
            Image(uiImage: image).interpolation(.none).resizable(resizingMode: .tile)
                .frame(height: image.size.height)
        }
    }
}
