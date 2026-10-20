/*****************************************************************************
 * Copyright (c) 2026 OpenRCT2 developers
 * OpenRCT2 is licensed under the GNU General Public License version 3.
 *****************************************************************************/
import CoreText
import SwiftUI
import UIKit

// The launcher runs before g1.dat exists, so it cannot use the engine's sprites. It draws RCT2's
// window style itself: one game pixel is 2 pt, colours are the g1 remap ramps, text is WenQuanYi Bitmap Song.
let px: CGFloat = 2

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

/// One RCT2 window colour, darkest to lightest (the g1 remap table's shades 245…252).
struct Ramp {
    let shades: [Color]
    init(_ hex: [UInt32]) { shades = hex.map(Color.init(hex:)) }
    var darker: Color { shades[1] }
    var dark: Color { shades[2] }
    var midDark: Color { shades[3] }
    var midLight: Color { shades[4] }
    var light: Color { shades[5] }
    var lighter: Color { shades[6] }
    var lightest: Color { shades[7] }

    static let grey = Ramp([0x2f4343, 0x3f5353, 0x4b6363, 0x5b7373, 0x6f8383, 0x839797, 0x9fafaf, 0xb7c3c3])
    static let black = Ramp([0x172323, 0x172323, 0x172323, 0x233333, 0x2f4343, 0x3f5353, 0x4b6363, 0x5b7373])
    static let lightBlue = Ramp([0x0733a7, 0x0f43bb, 0x1b53cb, 0x2b67df, 0x4387e3, 0x5ba3e7, 0x77bbef, 0x8fd3f3])
    static let darkGreen = Ramp([0x17471f, 0x23532b, 0x2f633b, 0x3b734b, 0x4f875f, 0x639b77, 0x7baf8b, 0x93c7a7])
    static let darkYellow = Ramp([0x471b00, 0x5f2b00, 0x5f2b00, 0x773f00, 0x8f5307, 0xa76f07, 0xbf8b0f, 0xd7a713])
    static let bordeauxRed = Ramp([0x5f0707, 0x6f0f0f, 0x7f1b1b, 0x8f2727, 0xa33b3b, 0xb34f4f, 0xc76767, 0xd77f7f])
    static let lightPurple = Ramp([0x333767, 0x3f4377, 0x53538b, 0x63639b, 0x7777af, 0x8b8bbf, 0x9f9fcf, 0xb7b7df])
    static let brightGreen = Ramp([0x176700, 0x1f7b00, 0x278f07, 0x379f17, 0x47af27, 0x5bbf3f, 0x6fcf57, 0x8bdf73])
}

enum Palette {
    static let ink = Color(hex: 0x101414)
    static let white = Color(hex: 0xeff3f3)
    static let shadow = Color(hex: 0x172323)
    static let yellow = Color(hex: 0xfff35f)
    static let grass = Color(hex: 0x638f3b)
}

// MARK: - Fonts

enum PixelFont {
    /// One of the pixel faces the engine bundles under data/fonts; em is its em size in font pixels.
    private struct Face {
        let file: String
        let em: CGFloat
    }

    /// The face for the launcher's language, as for the game: WenQuanYi for Chinese, Shinonome for Japanese,
    /// and Galmuri11, which also covers Latin, Cyrillic and Vietnamese letters, for every other language.
    private static let face: Face = {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        if language.hasPrefix("zh") { return Face(file: "WenQuanYi.Bitmap.Song.12px.ttf", em: 15) }
        if language.hasPrefix("ja") { return Face(file: "Shinonome.Mincho.12.ttf", em: 15) }
        return Face(file: "Galmuri11.ttf", em: 12)
    }()

    // Filled once on the main thread before the first view is built.
    nonisolated(unsafe) private static var name: String?

    static func register() {
        let url = Bundle.main.resourceURL!.appendingPathComponent("data/fonts").appendingPathComponent(face.file)
        guard name == nil,
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
            let found = descriptors.first.flatMap({ CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String })
        else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        name = found
    }

    /// Whole multiples of the face's em, so every font pixel covers whole screen pixels. Body text: 1.5× (3
    /// device pixels per font pixel at 2× screen scale). Small: 1×. Title: 2×.
    static let body = font(1.5)
    static let small = font(1)
    static let title = font(2)

    private static func font(_ scale: CGFloat) -> Font {
        register()
        let size = face.em * scale
        guard let name else { return .system(size: size * 0.8, weight: .bold, design: .monospaced) }
        return .custom(name, fixedSize: size)
    }
}

extension View {
    /// RCT2's light text: white with a one-pixel dark drop shadow.
    func outlined(_ colour: Color = Palette.white) -> some View {
        foregroundStyle(colour).shadow(color: Palette.shadow, radius: 0, x: px, y: px)
    }
}

// MARK: - Bevels (Rectangle::fillInset)

enum BevelStyle { case outset, inset, pressed }

struct Bevel: ViewModifier {
    let ramp: Ramp
    var style: BevelStyle = .outset
    var fill: Color?

    func body(content: Content) -> some View {
        let (topLeft, bottomRight, base): (Color, Color, Color) =
            switch style {
            case .outset: (ramp.lighter, ramp.midDark, ramp.light)
            case .inset: (ramp.midDark, ramp.lighter, ramp.midLight)
            case .pressed: (ramp.midDark, ramp.lighter, ramp.lighter)
            }
        content
            .background(fill ?? base)
            .overlay(alignment: .bottom) { bottomRight.frame(height: px) }
            .overlay(alignment: .trailing) { bottomRight.frame(width: px) }
            .overlay(alignment: .top) { topLeft.frame(height: px) }
            .overlay(alignment: .leading) { topLeft.frame(width: px) }
    }
}

extension View {
    func bevel(_ ramp: Ramp, _ style: BevelStyle = .outset, fill: Color? = nil) -> some View {
        modifier(Bevel(ramp: ramp, style: style, fill: fill))
    }
}

// MARK: - Window

struct RctWindow<Content: View>: View {
    let title: String
    let ramp: Ramp
    var caption: Ramp = .grey
    var onBack: (() -> Void)?
    var onClose: (() -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title).font(PixelFont.body).outlined().lineLimit(1).padding(.horizontal, onBack == nil ? 44 : 100)
                HStack {
                    if let onBack {
                        Button(action: onBack) { Text("‹ 返回").font(PixelFont.body).outlined().padding(.horizontal, 10) }
                            .buttonStyle(CaptionButtonStyle(ramp: caption))
                    }
                    Spacer()
                    if let onClose {
                        Button(action: onClose) { Text("×").font(PixelFont.body).outlined().frame(width: 36) }
                            .buttonStyle(CaptionButtonStyle(ramp: caption))
                            .accessibilityLabel("关闭")
                    }
                }
                .padding(px)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .bevel(caption, .inset, fill: caption.darker)
            content
        }
        .padding(px)
        .bevel(ramp)
        .environment(\.windowRamp, ramp)
    }
}

private struct CaptionButtonStyle: ButtonStyle {
    let ramp: Ramp
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(height: 36).bevel(ramp, configuration.isPressed ? .pressed : .outset, fill: ramp.darker)
    }
}

private struct WindowRampKey: EnvironmentKey { static let defaultValue = Ramp.grey }
extension EnvironmentValues {
    var windowRamp: Ramp {
        get { self[WindowRampKey.self] }
        set { self[WindowRampKey.self] = newValue }
    }
}

// MARK: - Buttons

struct RctButtonStyle: ButtonStyle {
    @Environment(\.windowRamp) private var ramp
    @Environment(\.isEnabled) private var enabled
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        let r = primary ? Ramp.brightGreen : ramp
        configuration.label
            .font(PixelFont.body)
            .foregroundStyle(primary ? Palette.white : (enabled ? Palette.ink : r.midDark))
            .shadow(color: primary ? Palette.shadow : (enabled ? .clear : r.lighter), radius: 0, x: px, y: px)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .bevel(r, configuration.isPressed ? .pressed : .outset, fill: primary ? r.dark : nil)
            .opacity(primary && !enabled ? 0.55 : 1)
            .contentShape(Rectangle())
    }
}

/// Translucent dark-green title menu (WC_TITLE_MENU).
struct TitleMenuButtonStyle: ButtonStyle {
    var go = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let fill: Color =
            go
            ? Ramp.brightGreen.darker.opacity(configuration.isPressed ? 1 : 0.9)
            : Ramp.darkGreen.dark.opacity(configuration.isPressed ? 0.85 : 0.55)
        configuration.label
            .font(go ? PixelFont.title : PixelFont.body)
            .foregroundStyle(enabled ? Palette.white : Palette.white.opacity(0.45))
            .shadow(color: enabled ? Palette.shadow : .clear, radius: 0, x: px, y: px)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minHeight: 52)
            .background(fill)
            .overlay(alignment: .top) { (go ? Ramp.brightGreen.lightest : Ramp.darkGreen.lightest.opacity(0.45)).frame(height: px) }
            .overlay(alignment: .leading) { (go ? Ramp.brightGreen.lightest : Ramp.darkGreen.lightest.opacity(0.45)).frame(width: px) }
            .overlay(alignment: .bottom) { Palette.shadow.opacity(0.7).frame(height: px) }
            .overlay(alignment: .trailing) { Palette.shadow.opacity(0.7).frame(width: px) }
            .contentShape(Rectangle())
    }
}

struct TitleMenu<Content: View>: View {
    var axis: Axis = .vertical
    @ViewBuilder let content: Content
    var body: some View {
        Group {
            if axis == .vertical { VStack(spacing: 6) { content } } else { HStack(spacing: 6) { content } }
        }
        .padding(6)
        .background(Ramp.darkGreen.shades[0].opacity(0.72))
        .overlay(alignment: .top) { Ramp.darkGreen.lightest.opacity(0.55).frame(height: px) }
        .overlay(alignment: .leading) { Ramp.darkGreen.lightest.opacity(0.55).frame(width: px) }
        .overlay(alignment: .bottom) { Palette.shadow.opacity(0.8).frame(height: px) }
        .overlay(alignment: .trailing) { Palette.shadow.opacity(0.8).frame(width: px) }
    }
}

// MARK: - Small parts

struct Checkbox: View {
    enum State { case on, off, warning }
    let state: State
    @Environment(\.windowRamp) private var ramp
    var body: some View {
        ZStack {
            switch state {
            case .on:
                Canvas { context, _ in
                    for (x, y) in [(0, 3), (1, 4), (2, 5), (3, 4), (4, 3), (5, 2), (6, 1)] {
                        context.fill(Path(CGRect(x: CGFloat(x) * px, y: CGFloat(y) * px, width: px, height: px)), with: .color(Palette.ink))
                    }
                }
                .frame(width: 14, height: 14)
            case .warning: Text("!").font(PixelFont.small).foregroundStyle(Color(hex: 0xab0000))
            case .off: EmptyView()
            }
        }
        .frame(width: 20, height: 20)
        .bevel(ramp, .inset)
    }
}

struct Separator: View {
    @Environment(\.windowRamp) private var ramp
    var body: some View {
        VStack(spacing: 0) {
            ramp.midDark.frame(height: px)
            ramp.lighter.frame(height: px)
        }
    }
}

struct Tabs: View {
    let titles: [String]
    @Binding var selection: Int
    @Environment(\.windowRamp) private var ramp
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: px) {
                ForEach(titles.indices, id: \.self) { index in
                    let active = index == selection
                    Button { selection = index } label: {
                        Text(titles[index]).font(PixelFont.body).foregroundStyle(Palette.ink)
                            .padding(.horizontal, 16).frame(minHeight: active ? 46 : 42)
                            .background(active ? ramp.light : ramp.midLight)
                            .overlay(alignment: .top) { ramp.lighter.frame(height: px) }
                            .overlay(alignment: .leading) { ramp.lighter.frame(width: px) }
                            .overlay(alignment: .trailing) { ramp.midDark.frame(width: px) }
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            ramp.lighter.frame(height: px)
        }
    }
}

/// Error and prompt box (WC_ERROR: translucent bordeaux red).
struct ErrorBox<Actions: View>: View {
    let title: String
    let message: String
    @ViewBuilder let actions: Actions
    var body: some View {
        VStack(spacing: 10) {
            Text(title).font(PixelFont.body).outlined()
            Text(message).font(PixelFont.small).outlined().multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) { actions }.environment(\.windowRamp, .bordeauxRed)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: 520)
        .background(Ramp.bordeauxRed.dark.opacity(0.92))
        .overlay(alignment: .top) { Ramp.bordeauxRed.lightest.frame(height: px) }
        .overlay(alignment: .leading) { Ramp.bordeauxRed.lightest.frame(width: px) }
        .overlay(alignment: .bottom) { Ramp.bordeauxRed.shades[0].frame(height: px) }
        .overlay(alignment: .trailing) { Ramp.bordeauxRed.shades[0].frame(width: px) }
    }
}

// MARK: - Sprites

enum Sprites {
    private static let folder = Bundle.main.resourceURL!.appendingPathComponent("launcher")

    /// g2 sprites from OpenRCT2's own resources, loaded so one sprite pixel is one game pixel (2 pt).
    static func image(_ name: String) -> UIImage? {
        guard let source = UIImage(contentsOfFile: folder.appendingPathComponent("\(name).png").path)?.cgImage else { return nil }
        return UIImage(cgImage: source, scale: 1 / px, orientation: .up)
    }
}

struct Sprite: View {
    let name: String
    init(_ name: String) { self.name = name }
    var body: some View {
        if let image = Sprites.image(name) {
            Image(uiImage: image).interpolation(.none)
        }
    }
}

/// Pixel icons drawn from rectangles in game pixels.
struct PixelIcon: View {
    enum Kind { case download, folder, zip, app, share }
    let kind: Kind
    var body: some View {
        Canvas { context, _ in
            func fill(_ rects: [(Int, Int, Int, Int)], _ colour: UInt32) {
                for (x, y, w, h) in rects {
                    context.fill(Path(CGRect(x: CGFloat(x) * px, y: CGFloat(y) * px, width: CGFloat(w) * px, height: CGFloat(h) * px)),
                                 with: .color(Color(hex: colour)))
                }
            }
            switch kind {
            case .download:
                let arrow = [(9, 1, 2, 9), (6, 9, 8, 1), (7, 10, 6, 1), (8, 11, 4, 1), (9, 12, 2, 1), (2, 12, 2, 4), (16, 12, 2, 4), (2, 16, 16, 2)]
                fill(arrow.map { ($0.0 + 1, $0.1 + 1, $0.2, $0.3) }, 0x172323)
                fill(arrow, 0xeff3f3)
            case .folder:
                fill([(1, 2, 7, 2), (1, 4, 18, 13)], 0xd7a713)
                fill([(1, 6, 18, 11)], 0xf3cb1b)
                fill([(2, 7, 16, 1)], 0xfff35f)
            case .zip:
                let page = [(3, 1, 10, 18), (13, 5, 4, 14)]
                fill(page.map { ($0.0 + 1, $0.1 + 1, $0.2, $0.3) }, 0x172323)
                fill(page, 0xeff3f3)
                fill([(13, 1, 1, 4), (14, 2, 1, 3), (15, 3, 1, 2), (16, 4, 1, 1)], 0x9fafaf)
                fill([(9, 2, 2, 1), (8, 3, 2, 1), (9, 4, 2, 1), (8, 5, 2, 1), (9, 6, 2, 1), (8, 7, 3, 4)], 0x3f5353)
                fill([(9, 9, 1, 1)], 0xeff3f3)
            case .app:
                fill([(4, 3, 14, 16)], 0x172323)
                fill([(3, 2, 14, 16)], 0x4387e3)
                fill([(4, 3, 12, 1)], 0x8fd3f3)
                fill([(6, 7, 8, 2), (8, 11, 4, 4)], 0xfff35f)
            case .share:
                let arrow = [(9, 2, 2, 10), (7, 4, 6, 1), (6, 5, 2, 1), (12, 5, 2, 1), (3, 8, 2, 11), (5, 8, 2, 2), (15, 8, 2, 11), (13, 8, 2, 2), (5, 17, 10, 2)]
                fill(arrow.map { ($0.0 + 1, $0.1 + 1, $0.2, $0.3) }, 0x172323)
                fill(arrow, 0xeff3f3)
            }
        }
        .frame(width: 40, height: 40)
    }
}
