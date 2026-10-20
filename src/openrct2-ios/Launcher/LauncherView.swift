/*****************************************************************************
 * Copyright (c) 2026 OpenRCT2 developers
 * OpenRCT2 is licensed under the GNU General Public License version 3.
 *****************************************************************************/
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Layout follows size classes, not device models, so split views and other iPhones fall into place.
enum LauncherLayout {
    case phonePortrait, phoneLandscape, padPortrait, padLandscape

    init(horizontal: UserInterfaceSizeClass?, vertical: UserInterfaceSizeClass?, size: CGSize) {
        if vertical == .compact {
            self = .phoneLandscape
        } else if horizontal == .compact {
            self = .phonePortrait
        } else {
            self = size.width > size.height ? .padLandscape : .padPortrait
        }
    }

    var isPhone: Bool { self == .phonePortrait || self == .phoneLandscape }
}

private enum Route: Equatable {
    case home, importing, failed(String), confirmDelete(Slot), licenses
}

struct LauncherView: View {
    let onStart: @MainActor () -> Void

    @StateObject private var store = GameDataStore()
    @StateObject private var importer = Importer()
    @State private var route: Route = .home
    @State private var pickerShown = false
    @State private var comingSoon: String?
    @State private var guide: ImportGuide?
    /// The entry of the latest import, for its expected slot and for "重新选择" after a failure.
    @State private var lastGuide: ImportGuide = .files(expected: nil)
    @AppStorage("launcher.skipReplaceGuide") private var skipReplaceGuide = false
    @State private var tab = 0
    @Environment(\.horizontalSizeClass) private var horizontal
    @Environment(\.verticalSizeClass) private var vertical
    @Environment(\.openURL) private var openURL

    var body: some View {
        GeometryReader { proxy in
            let layout = LauncherLayout(horizontal: horizontal, vertical: vertical, size: proxy.size)
            ZStack {
                ParkView()
                if !layout.isPhone {
                    VStack { Spacer(); Coaster(style: store.canPlay ? .wooden : .steel) }.ignoresSafeArea(edges: .horizontal)
                }
                home(layout)
                if layout == .padLandscape || layout == .padPortrait {
                    footer.padding(.leading, 36).padding(.bottom, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
                overlay(layout)
            }
        }
        .fileImporter(isPresented: $pickerShown, allowedContentTypes: [.folder, .zip, .data], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            runImport(urls, expecting: lastGuide.expectedSlot)
        }
        .task { await store.load() }
        .statusBarHidden()
    }

    // MARK: Home

    @ViewBuilder private func home(_ layout: LauncherLayout) -> some View {
        switch layout {
        case .padLandscape:
            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 16) { brand(layout); menu(.vertical) }.frame(width: 252)
                mainWindow(layout).frame(maxWidth: 820)
            }
            .padding(.horizontal, 36).padding(.top, 24).padding(.bottom, 148)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .padPortrait:
            VStack(spacing: 20) {
                brand(layout)
                mainWindow(layout)
                menu(.horizontal)
            }
            .frame(maxWidth: 700).padding(.horizontal, 36).padding(.top, 28).padding(.bottom, 148)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .phonePortrait:
            VStack(spacing: 12) {
                brand(layout)
                mainWindow(layout).frame(maxHeight: .infinity, alignment: .top)
                phoneBar
                footer.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
        case .phoneLandscape:
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    brand(layout)
                    menu(.vertical)
                    Spacer(minLength: 0)
                    footer
                }
                .frame(width: 208)
                mainWindow(layout).frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(12)
        }
    }

    @ViewBuilder private func brand(_ layout: LauncherLayout) -> some View {
        if layout.isPhone {
            HStack(spacing: 8) {
                Wordmark()
                Spacer()
            }
        } else {
            Sprite("logo_text")
        }
    }

    /// Bottom left: the app's and OpenRCT2's versions, and the license page, away from the menu.
    private var footer: some View {
        let info = Bundle.main.infoDictionary ?? [:]
        let app = "\(info["CFBundleShortVersionString"] as? String ?? "") (\(info["CFBundleVersion"] as? String ?? ""))"
        let version = Text("App \(app) · OpenRCT2 \(ORCTLauncherBridge.openRCT2Version)")
            .font(PixelFont.small).outlined()
        // The iPhone's landscape sidebar is too narrow for one line.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { version; LicensesLink { route = .licenses } }
            VStack(alignment: .leading, spacing: 0) { version; LicensesLink { route = .licenses } }
        }
    }

    @ViewBuilder private func mainWindow(_ layout: LauncherLayout) -> some View {
        let scrolls = layout.isPhone
        if store.loading {
            RctWindow(title: String(localized: "正在检查游戏数据"), ramp: .grey) { Coaster(progress: nil).padding(.vertical, 8) }
        } else if store.canPlay || store.installed[.rct1] != nil {
            RctWindow(title: String(localized: "游戏数据"), ramp: .darkYellow) {
                DataPanel(store: store, tab: $tab, scrolls: scrolls, onReplace: { showGuide(.replace($0)) },
                          onImport: { showGuide($0 == .rct1 ? .rct1 : .files(expected: .rct2)) }, onDelete: { route = .confirmDelete($0) })
            }
        } else {
            RctWindow(title: String(localized: "导入 RollerCoaster Tycoon 2"), ramp: .bordeauxRed) {
                ImportSources(layout: layout, scrolls: scrolls, onFiles: { showGuide(.files(expected: nil)) }, onGog: { showGuide(.gog) }, onComingSoon: { comingSoon = $0 },
                              onStore: { openURL($0) })
            }
        }
    }

    private func menu(_ axis: Axis) -> some View {
        TitleMenu(axis: axis) {
            Button(action: start) { menuLabel(Sprite("title_play"), String(localized: "开始游戏")) }
                .buttonStyle(TitleMenuButtonStyle(go: store.canPlay)).disabled(!store.canPlay)
            if store.canPlay {
                Button { showGuide(.replaceAny) } label: { menuLabel(Sprite("copy"), String(localized: "导入或替换")) }.buttonStyle(TitleMenuButtonStyle())
                Button(action: openSaves) { menuLabel(PixelIcon(kind: .folder), String(localized: "存档文件夹")) }.buttonStyle(TitleMenuButtonStyle())
            } else {
                Button { Task { await store.load() } } label: { menuLabel(Sprite("reload"), String(localized: "重新检测")) }.buttonStyle(TitleMenuButtonStyle())
                Button { openURL(Links.guide) } label: { menuLabel(Sprite("system_browser"), String(localized: "导入指南")) }.buttonStyle(TitleMenuButtonStyle())
            }
        }
    }

    private func menuLabel<Icon: View>(_ icon: Icon, _ title: String) -> some View {
        HStack(spacing: 12) {
            icon.frame(width: 40)
            Text(title)
            Spacer(minLength: 0)
        }
    }

    /// iPhone portrait: the main action sits at the bottom, in reach of the thumb.
    private var phoneBar: some View {
        VStack(spacing: 4) {
            TitleMenu(axis: .horizontal) {
                Button(action: start) { menuLabel(Sprite("title_play"), String(localized: "开始游戏")) }
                    .buttonStyle(TitleMenuButtonStyle(go: store.canPlay)).disabled(!store.canPlay)
                if store.canPlay {
                    Button { showGuide(.replaceAny) } label: { Sprite("copy").frame(width: 40) }.buttonStyle(TitleMenuButtonStyle())
                        .accessibilityLabel("导入或替换").fixedSize()
                    Button(action: openSaves) { PixelIcon(kind: .folder) }.buttonStyle(TitleMenuButtonStyle())
                        .accessibilityLabel("存档文件夹").fixedSize()
                } else {
                    Button { openURL(Links.guide) } label: { Sprite("system_browser").frame(width: 40) }.buttonStyle(TitleMenuButtonStyle())
                        .accessibilityLabel("导入指南").fixedSize()
                }
            }
            if store.canPlay { Text("开始后自动转为横屏").font(PixelFont.small).outlined() }
        }
    }

    // MARK: Overlays

    @ViewBuilder private func overlay(_ layout: LauncherLayout) -> some View {
        switch route {
        case .home:
            if let comingSoon {
                dimmed {
                    ErrorBox(title: comingSoon, message: String(localized: "这个导入方式会在后续版本加入。现在可以导入游戏文件夹或 ZIP 压缩包。")) {
                        Button("知道了") { self.comingSoon = nil }.buttonStyle(RctButtonStyle())
                    }
                }
            } else if let guide {
                dimmed {
                    sheet(layout, width: guideWidth(guide)) {
                        ImportGuideWindow(
                            guide: guide, layout: layout, current: guide.expectedSlot.flatMap { store.installed[$0] },
                            onChoose: { skip in
                                if guide == .replaceAny && skip { skipReplaceGuide = true }
                                self.guide = nil
                                pickerShown = true
                            },
                            onCancel: { self.guide = nil }, onStore: { openURL($0) })
                    }
                }
            }
        case .importing:
            dimmed {
                if let found = importer.unexpectedSlot {
                    sheet(layout, width: 600) {
                        UnexpectedSlotWindow(
                            found: found, replacing: store.installed[found] != nil, layout: layout,
                            onCancel: { importer.resolveUnexpectedSlot(install: false) },
                            onInstall: { importer.resolveUnexpectedSlot(install: true) })
                    }
                } else {
                    sheet(layout, width: 600) {
                        ImportProgressWindow(importer: importer, layout: layout)
                    }
                }
            }
        case .failed(let message):
            dimmed {
                ErrorBox(title: String(localized: "导入没有完成"), message: message) {
                    Button("重新选择") { route = .home; showGuide(lastGuide) }.buttonStyle(RctButtonStyle())
                    Button("关闭") { route = .home }.buttonStyle(RctButtonStyle())
                }
            }
        case .licenses:
            dimmed {
                sheet(layout, width: 640) {
                    LicensesWindow(layout: layout) { route = .home }
                        .frame(maxHeight: layout.isPhone ? .infinity : 640, alignment: .top)
                }
            }
        case .confirmDelete(let slot):
            dimmed {
                ErrorBox(title: slot == .rct2 ? String(localized: "删除游戏数据？") : String(localized: "删除 RCT1 数据？"), message: String(localized: "只删除 App 里导入的副本，你的存档和原始文件不受影响。之后需要重新导入才能开始游戏。")) {
                    Button("删除") { route = .home; Task { await store.remove(slot) } }.buttonStyle(RctButtonStyle())
                    Button("取消") { route = .home }.buttonStyle(RctButtonStyle())
                }
            }
        }
    }

    private func dimmed<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            Color(hex: 0x0f1313).opacity(0.55).ignoresSafeArea()
            content().padding(16)
        }
    }

    /// iPad: a centred window. iPhone: the window fills the safe area.
    @ViewBuilder private func sheet<Content: View>(_ layout: LauncherLayout, width: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        if layout.isPhone {
            content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            content().frame(width: width)
        }
    }

    private func guideWidth(_ guide: ImportGuide) -> CGFloat {
        switch guide {
        case .gog: 640
        case .files: 680
        case .rct1: 620
        case .missingSlices: 660
        case .replaceAny, .replace: 600
        }
    }

    // MARK: Actions

    /// Every import entry explains what to pick first; "导入或替换" can skip that once the user asks.
    private func showGuide(_ next: ImportGuide) {
        lastGuide = next
        if next == .replaceAny && skipReplaceGuide {
            pickerShown = true
        } else {
            guide = next
        }
    }

    private func runImport(_ urls: [URL], expecting expected: Slot?) {
        route = .importing
        Task {
            do {
                let infos = try await importer.run(urls, expecting: expected)
                store.didImport(infos)
                tab = infos.first?.slot == .rct1 && !store.canPlay ? 1 : 0
                route = .home
            } catch is CancellationError {
                route = .home
            } catch GameDataError.missingSlices(let installer, let slices, let missing) {
                route = .home
                guide = .missingSlices(installer: installer, slices: slices, missing: missing)
            } catch {
                route = .failed(error.localizedDescription)
            }
        }
    }

    private func start() {
        guard store.canPlay else { return }
        onStart()
    }

    private func openSaves() {
        let saves = GameDataLocation.documents.appendingPathComponent("OpenRCT2/save", isDirectory: true)
        try? FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
        if let url = URL(string: "shareddocuments://" + saves.path) { openURL(url) }
    }
}

enum Links {
    static let guide = URL(string: "https://docs.openrct2.io/en/latest/installing/getting-rct2.html")!
    static let steam = URL(string: "https://store.steampowered.com/app/285330/")!
    static let gog = URL(string: "https://www.gog.com/game/rollercoaster_tycoon_2")!
    static let gogRCT1 = URL(string: "https://www.gog.com/game/rollercoaster_tycoon_deluxe")!
}

struct Wordmark: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("Open").font(PixelFont.title).foregroundStyle(Palette.yellow)
                .shadow(color: Color(hex: 0x773f00), radius: 0, x: px, y: px)
            Text("RCT2").font(PixelFont.body).foregroundStyle(Palette.white)
                .shadow(color: Color(hex: 0x3f0000), radius: 0, x: px, y: px)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .bevel(Ramp([0x3f0000, 0x570000, 0x730000, 0x730000, 0x8f0000, 0xc70000, 0xff7b73, 0xff7b73]))
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("OpenRCT2")
    }
}

// MARK: - Import sources (home, nothing imported)

private struct ImportSources: View {
    let layout: LauncherLayout
    let scrolls: Bool
    let onFiles: () -> Void
    let onGog: () -> Void
    let onComingSoon: (String) -> Void
    let onStore: (URL) -> Void

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 12) {
            if layout != .phoneLandscape {
                Text("OpenRCT2 需要原版游戏的图像、音效和场景文件。本 App 不含任何原版素材，请导入你拥有的那一份。")
                    .font(PixelFont.body).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
            }
            let sources = Group {
                source(AnyView(PixelIcon(kind: .download)), String(localized: "从 Steam 导入"), String(localized: "从你的 Steam 库直接下载"), soon: true) { onComingSoon(String(localized: "从 Steam 导入")) }
                source(AnyView(Sprite("copy")), String(localized: "GOG 安装包"), String(localized: "选择 .exe 和 .bin 所在的文件夹"), soon: false, action: onGog)
                source(AnyView(PixelIcon(kind: .folder)), String(localized: "文件或文件夹"), String(localized: "游戏文件夹、ZIP 或 GOG 安装包"), soon: false, action: onFiles)
            }
            if layout == .phoneLandscape {
                HStack(alignment: .top, spacing: 8) { sources }
            } else {
                VStack(spacing: 8) { sources }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("还没有游戏？").font(PixelFont.body).foregroundStyle(Palette.ink)
                Text("Steam 和 GOG 上的 RCT2: Triple Thrill Pack 都包含 Wacky Worlds 与 Time Twister。")
                    .font(PixelFont.small).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Steam 商店") { onStore(Links.steam) }.buttonStyle(RctButtonStyle())
                    Button("GOG 商店") { onStore(Links.gog) }.buttonStyle(RctButtonStyle())
                }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .bevel(.bordeauxRed, .inset)
        }
        .padding(14)
        if scrolls { ScrollView { content }.scrollIndicators(.hidden) } else { content }
    }

    private func source(_ icon: AnyView, _ title: String, _ detail: String, soon: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            let text = VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    if soon { Text("即将支持").font(PixelFont.small).outlined(Palette.yellow) }
                }
                Text(detail).font(PixelFont.small).fixedSize(horizontal: false, vertical: true)
            }
            Group {
                if layout == .phoneLandscape {
                    VStack(alignment: .leading, spacing: 6) { icon.frame(width: 48, height: 48); text }
                } else {
                    HStack(spacing: 14) { icon.frame(width: 48, height: 48); text; Spacer(minLength: 0) }
                }
            }
            .padding(.vertical, 8).frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        }
        .buttonStyle(RctButtonStyle())
        .multilineTextAlignment(.leading)
    }
}

// MARK: - Installed data (home)

private struct DataPanel: View {
    @ObservedObject var store: GameDataStore
    @Binding var tab: Int
    let scrolls: Bool
    let onReplace: (Slot) -> Void
    let onImport: (Slot) -> Void
    let onDelete: (Slot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Tabs(titles: ["RCT2", "RCT1"], selection: $tab).padding(.top, 8)
            let slot: Slot = tab == 0 ? .rct2 : .rct1
            let body = Group {
                if let info = store.installed[slot] {
                    details(info)
                } else {
                    empty(slot)
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 14)
            if scrolls { ScrollView { body }.scrollIndicators(.hidden) } else { body }
        }
    }

    private func details(_ info: GameDataInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text([info.title, info.edition].compactMap { $0 }.joined(separator: ": ")).font(PixelFont.body)
                Text(info.sourceLine).font(PixelFont.small)
            }
            .foregroundStyle(Palette.ink)
            VStack(spacing: 0) {
                ForEach(rows(info), id: \.0) { row in
                    HStack(spacing: 10) {
                        Checkbox(state: row.2)
                        Text(row.0).font(PixelFont.body)
                        Spacer()
                        Text(row.1).font(PixelFont.small)
                    }
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 8).frame(minHeight: 40)
                }
            }
            .padding(.vertical, 4)
            .bevel(.darkYellow, .inset)
            Text("\(info.importedAt.formatted(date: .numeric, time: .omitted)) 导入 · 共 \(ByteCountFormatter.string(fromByteCount: info.bytes, countStyle: .file))")
                .font(PixelFont.small).foregroundStyle(Palette.ink)
            HStack(spacing: 8) {
                Button("重新检测") { Task { await store.redetect() } }.buttonStyle(RctButtonStyle())
                Button("替换…") { onReplace(info.slot) }.buttonStyle(RctButtonStyle())
                Button("删除") { onDelete(info.slot) }.buttonStyle(RctButtonStyle())
            }
        }
    }

    private func rows(_ info: GameDataInfo) -> [(String, String, Checkbox.State)] {
        func percent(_ share: Double?) -> (String, Checkbox.State) {
            guard let share else { return (String(localized: "未知"), .off) }
            return ("\(Int((share * 100).rounded()))%", share >= 0.99 ? .on : (share > 0 ? .warning : .off))
        }
        switch info.slot {
        case .rct1:
            return [
                (String(localized: "RCT1 图形"), info.rct1Usable == true ? String(localized: "可用") : String(localized: "需要 Loopy Landscapes 版"), info.rct1Usable == true ? .on : .warning),
                (String(localized: "场景"), String(localized: "\(info.scenarios) 个"), info.scenarios > 0 ? .on : .off),
            ]
        case .rct2 where info.isClassic:
            return [(String(localized: "基础游戏"), "Classic", .on), (String(localized: "扩展包"), String(localized: "已包含全部扩展"), .on)]
        case .rct2:
            let ww = percent(info.wackyWorlds), tt = percent(info.timeTwister)
            return [
                (String(localized: "基础游戏"), info.g1Entries.map { String(localized: "\($0.formatted()) 张图像") } ?? String(localized: "已找到"), .on),
                ("Wacky Worlds", ww.0, ww.1),
                ("Time Twister", tt.0, tt.1),
                (String(localized: "音效与音乐"), "\(info.sounds) / 46", info.sounds >= 46 ? .on : .warning),
                (String(localized: "场景"), String(localized: "\(info.scenarios) 个"), info.scenarios > 0 ? .on : .warning),
            ]
        }
    }

    private func empty(_ slot: Slot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(slot == .rct1
                 ? String(localized: "可选：导入 RollerCoaster Tycoon Deluxe 后，可以游玩 RCT1 场景，并使用 RCT1 的图形和标题音乐。")
                 : String(localized: "还没有导入 RCT2，需要先导入才能开始游戏。"))
                .font(PixelFont.body).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
            Button("导入…") { onImport(slot) }.buttonStyle(RctButtonStyle())
        }
    }
}

// MARK: - Import progress (the loading window)

private struct ImportProgressWindow: View {
    @ObservedObject var importer: Importer
    let layout: LauncherLayout

    var body: some View {
        RctWindow(title: String(localized: "正在导入 · \(Int(overall * 100))%"), ramp: .grey) {
            Coaster(progress: overall).padding(.top, px)
            VStack(alignment: .leading, spacing: 10) {
                let steps = ForEach(Importer.Step.allCases, id: \.self) { step in
                    HStack(spacing: 10) {
                        Checkbox(state: step.rawValue < importer.step.rawValue ? .on : .off)
                            .environment(\.windowRamp, Ramp([0x172323, 0x172323, 0x172323, 0x233333, 0xd3dbdb, 0xd3dbdb, 0x4b6363, 0x5b7373]))
                        Text(step.title).font(PixelFont.body)
                            .outlined(step == importer.step ? Palette.yellow : (step.rawValue < importer.step.rawValue ? Palette.white : Color(hex: 0x839797)))
                    }
                }
                if layout == .phoneLandscape {
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 8) { steps }
                } else {
                    steps
                }
                if !importer.detail.isEmpty {
                    Text(importer.detail).font(PixelFont.small).outlined().lineLimit(2)
                }
                if layout.isPhone { Spacer(minLength: 0) }
                HStack {
                    Spacer()
                    Button("取消") { importer.cancel() }.buttonStyle(RctButtonStyle())
                }
            }
            .padding(14)
        }
    }

    /// Unpacking and copying dominate the time, so they get most of the bar.
    private var overall: Double {
        switch importer.step {
        case .reading: 0.02
        case .checking: 0.05
        case .unpacking: 0.05 + importer.progress * 0.45
        case .verifying: 0.5 + importer.progress * 0.45
        case .installing: 0.97
        }
    }
}

// MARK: - Hosting

@objc(ORCTLauncher) @MainActor
public final class LauncherHost: NSObject {
    /// A window over the scene that shows the launcher; onStart runs once the scene is turned to landscape.
    @objc public static func makeWindow(scene: UIWindowScene, onStart: @escaping @MainActor () -> Void) -> UIWindow {
        PixelFont.register()
        let window = UIWindow(windowScene: scene)
        let controller = LauncherController(rootView: AnyView(EmptyView()))
        controller.rootView = AnyView(LauncherView {
            controller.lockedToLandscape = true
            controller.setNeedsUpdateOfSupportedInterfaceOrientations()
            let landscape = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .landscape)
            if scene.interfaceOrientation.isLandscape {
                onStart()
            } else {
                scene.requestGeometryUpdate(landscape) { _ in }
                // Start once the rotation has finished so the game window opens at its final size.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { onStart() }
            }
        })
        window.rootViewController = controller
        return window
    }
}

private final class LauncherController: UIHostingController<AnyView> {
    var lockedToLandscape = false
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        lockedToLandscape ? .landscape : (traitCollection.userInterfaceIdiom == .pad ? .all : .allButUpsideDown)
    }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { false }
}
