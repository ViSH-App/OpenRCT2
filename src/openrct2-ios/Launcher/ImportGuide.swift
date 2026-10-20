/*****************************************************************************
 * Copyright (c) 2026 OpenRCT2 developers
 * OpenRCT2 is licensed under the GNU General Public License version 3.
 *****************************************************************************/
import SwiftUI

/// What the user is about to import, by the entry they came from; each explains what to pick next.
enum ImportGuide: Equatable {
    case gog
    case files(expected: Slot?)
    case replaceAny
    case replace(Slot)
    case rct1
    /// A GOG installer whose slices were not found; `slices` lists all of them.
    case missingSlices(installer: String, slices: [String], missing: [String])

    /// The slot the entry was for, so finding only the other one can be confirmed before it is replaced.
    var expectedSlot: Slot? {
        switch self {
        case .files(let slot): slot
        case .replace(let slot): slot
        case .rct1: .rct1
        default: nil
        }
    }
}

extension Slot {
    var gameName: String {
        switch self {
        case .rct2: "RollerCoaster Tycoon 2"
        case .rct1: "RollerCoaster Tycoon Deluxe"
        }
    }
    var shortName: String { self == .rct2 ? "RCT2" : "RCT1" }
}

// MARK: - Guide window

struct ImportGuideWindow: View {
    let guide: ImportGuide
    let layout: LauncherLayout
    /// The data a replace entry would overwrite.
    let current: GameDataInfo?
    let onChoose: (_ skipNextTime: Bool) -> Void
    let onCancel: () -> Void
    let onStore: (URL) -> Void
    @State private var skipNextTime = false

    var body: some View {
        GuideWindow(title: title, ramp: ramp, layout: layout, onCancel: onCancel) {
            content
        } option: {
            if guide == .replaceAny {
                Button { skipNextTime.toggle() } label: {
                    HStack(spacing: 10) {
                        Checkbox(state: skipNextTime ? .on : .off)
                        Text("不再提示").font(PixelFont.body).foregroundStyle(Palette.ink)
                    }
                    .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } actions: { stretch in
            if guide == .rct1 {
                GuideButton(title: String(localized: "GOG 商店"), stretch: stretch) { onStore(Links.gogRCT1) }
            }
            if case .missingSlices = guide {
                GuideButton(title: String(localized: "关闭"), stretch: stretch, action: onCancel)
                GuideButton(title: String(localized: "重新选择"), primary: true, stretch: stretch) { onChoose(false) }
            } else {
                GuideButton(title: String(localized: "取消"), stretch: stretch, action: onCancel)
                GuideButton(title: guide == .gog ? String(localized: "选择文件夹") : String(localized: "选择"), primary: true, stretch: stretch) { onChoose(skipNextTime) }
            }
        }
    }

    private var title: String {
        switch guide {
        case .gog: String(localized: "导入 GOG 安装包")
        case .files: String(localized: "导入游戏文件")
        case .replaceAny: String(localized: "导入或替换")
        case .replace(let slot): String(localized: "替换 \(slot.shortName) 数据")
        case .rct1: String(localized: "导入 RCT1（可选）")
        case .missingSlices: String(localized: "缺少数据文件")
        }
    }

    // Every launcher popup shares the grey window colour.
    private var ramp: Ramp { .grey }

    @ViewBuilder private var content: some View {
        switch guide {
        case .gog:
            VStack(alignment: .leading, spacing: 10) {
                GuideStep(number: 1, icon: AnyView(Sprite("copy")), title: String(localized: "准备安装包文件"), details: [String(localized: "setup_….exe 与 setup_…-1.bin，共约 600 MB")], layout: layout)
                GuideStep(number: 2, icon: AnyView(PixelIcon(kind: .share)), title: String(localized: "存入同一文件夹"), details: [String(localized: "可通过隔空投送、iCloud 云盘或电脑传输至「文件」App")], layout: layout)
                GuideStep(number: 3, icon: AnyView(PixelIcon(kind: .folder)), title: String(localized: "选择该文件夹"), details: [String(localized: "在下一步中选中该文件夹并点击「打开」，App 将自动识别两个文件")], layout: layout)
            }
            GuideText("也可进入该文件夹，点击「选择」后同时选中两个文件。", secondary: true)
        case .files:
            GuideText("请选择完整的游戏文件夹，无需单独选择 Data 文件夹。App 将自动识别 RCT2 或 RCT1。")
            let first = VStack(alignment: .leading, spacing: 10) {
                GuideStep(icon: AnyView(PixelIcon(kind: .folder)), title: String(localized: "已安装的游戏文件夹"), details: [
                    String(localized: "GOG 默认位置：C:\\GOG Games\\RollerCoaster Tycoon 2"), String(localized: "Steam 默认位置：steamapps\\common\\Rollercoaster Tycoon 2"),
                ], layout: layout)
                GuideStep(icon: AnyView(PixelIcon(kind: .zip)), title: String(localized: "游戏文件夹的 ZIP 压缩包"), details: [], layout: layout)
            }
            let second = VStack(alignment: .leading, spacing: 10) {
                GuideStep(icon: AnyView(PixelIcon(kind: .app)), title: String(localized: "RCT Classic（Mac 版 App）"), details: [], layout: layout)
                GuideStep(icon: AnyView(Sprite("copy")), title: String(localized: "GOG 安装包"), details: [String(localized: "选择 .exe 与 .bin 所在的文件夹")], layout: layout)
            }
            if layout == .phoneLandscape {
                HStack(alignment: .top, spacing: 12) { first.frame(maxWidth: .infinity, alignment: .leading); second.frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                VStack(alignment: .leading, spacing: 10) { first; second }
            }
            GuideText("文件需先存入「文件」App，可通过隔空投送或 iCloud 云盘传输。", secondary: true)
        case .replaceAny:
            GuideText("选择新的游戏数据后，App 将识别其为 RCT2 或 RCT1，并替换对应数据。存档不受影响。")
            GuideInset {
                Text("支持格式")
                Text("游戏文件夹、ZIP 压缩包、GOG 安装包所在文件夹")
            }
        case .replace(let slot):
            if let current {
                GuideInset {
                    Text([current.title, current.edition].compactMap { $0 }.joined(separator: ": "))
                    Text("\(current.sourceLine) · \(current.importedAt.formatted(date: .numeric, time: .omitted)) 导入").foregroundStyle(ramp.shades[0])
                }
            }
            GuideText(slot == .rct1 ? String(localized: "新导入的数据将替换上述数据。使用 RCT1 图形需要包含 Loopy Landscapes 的 RCT Deluxe。") : String(localized: "新导入的数据将替换上述数据。存档不受影响。"))
            GuideText(slot == .rct1 ? String(localized: "支持 RCT Deluxe 游戏文件夹、ZIP 压缩包及 GOG 安装包所在文件夹。") : String(localized: "支持游戏文件夹、ZIP 压缩包及 GOG 安装包所在文件夹。"), secondary: true)
        case .rct1:
            GuideText("导入 RollerCoaster Tycoon Deluxe 后可使用：")
            GuideInset(spacing: 4) {
                ForEach([String(localized: "RCT1 场景"), String(localized: "RCT1 图形"), String(localized: "RCT1 标题音乐")], id: \.self) { item in
                    HStack(spacing: 10) { Checkbox(state: .on); Text(item) }
                }
            }
            GuideText("需要包含 Loopy Landscapes 的版本，可在 Steam 或 GOG 购买。支持游戏文件夹、ZIP 压缩包及 GOG 安装包所在文件夹。")
        case .missingSlices(let installer, let slices, let missing):
            GuideText(slices.count == 1 && missing.count == 1
                      ? String(localized: "GOG 安装包由以下两个文件组成，当前缺少第二个文件：")
                      : String(localized: "GOG 安装包由以下 \(slices.count + 1) 个文件组成，标有「!」的文件尚未找到："))
            VStack(spacing: 0) {
                FileRow(name: installer, found: true)
                ForEach(slices, id: \.self) { slice in
                    Separator()
                    FileRow(name: slice, found: !missing.contains(slice))
                }
            }
            .bevel(ramp, .inset, fill: ramp.lighter)
            GuideText("请将 .bin 文件存入 .exe 所在文件夹，然后重新选择该文件夹。")
        }
    }
}

/// Asked mid-import when the data found is for the other game than the page the import started from.
struct UnexpectedSlotWindow: View {
    let found: Slot
    let replacing: Bool
    let layout: LauncherLayout
    let onCancel: () -> Void
    let onInstall: () -> Void

    var body: some View {
        let page: Slot = found == .rct2 ? .rct1 : .rct2
        GuideWindow(title: String(localized: "所选数据为 \(found.shortName)"), ramp: .grey, layout: layout, onCancel: nil) {
            GuideText("当前位于 \(page.shortName) 页面，但所选数据为：")
            GuideInset { Text(found.gameName) }
            GuideText(replacing
                      ? String(localized: "是否替换现有的 \(found.shortName) 数据？\(page.shortName) 数据不受影响。")
                      : String(localized: "是否将其导入为 \(found.shortName) 数据？\(page.shortName) 数据不受影响。"))
        } option: {
            EmptyView()
        } actions: { stretch in
            GuideButton(title: String(localized: "取消导入"), stretch: stretch, action: onCancel)
            GuideButton(title: replacing ? String(localized: "替换 \(found.shortName)") : String(localized: "导入 \(found.shortName)"), primary: true, stretch: stretch, action: onInstall)
        }
    }
}

// MARK: - Parts

/// An RCT2 window whose body scrolls when it does not fit, above a fixed row of actions.
/// iPad: sized to its content (×). iPhone: fills the safe area (‹ 返回); none when a choice is required.
private struct GuideWindow<Content: View, Option: View, Actions: View>: View {
    let title: String
    let ramp: Ramp
    let layout: LauncherLayout
    let onCancel: (() -> Void)?
    @ViewBuilder let content: Content
    @ViewBuilder let option: Option
    @ViewBuilder let actions: (_ stretch: Bool) -> Actions

    var body: some View {
        RctWindow(title: title, ramp: ramp, onBack: layout.isPhone ? onCancel : nil, onClose: layout.isPhone ? nil : onCancel) {
            VStack(spacing: 0) {
                let body = VStack(alignment: .leading, spacing: 12) { content }
                    .font(PixelFont.body).foregroundStyle(Palette.ink)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ViewThatFits(in: .vertical) {
                    body
                    ScrollView { body }.scrollIndicators(.hidden)
                }
                .frame(maxHeight: layout.isPhone ? .infinity : nil, alignment: .top)
                Separator()
                Group {
                    if layout == .phonePortrait {
                        VStack(alignment: .leading, spacing: 8) {
                            option
                            HStack(spacing: 8) { actions(true) }
                        }
                    } else {
                        HStack(spacing: 8) {
                            option
                            Spacer(minLength: 0)
                            actions(false)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 12)
            }
        }
    }
}

private struct GuideButton: View {
    let title: String
    var primary = false
    let stretch: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) { Text(title).lineLimit(1).frame(maxWidth: stretch ? .infinity : nil) }
            .buttonStyle(RctButtonStyle(primary: primary))
    }
}

private struct GuideText: View {
    let text: String
    var secondary = false
    @Environment(\.windowRamp) private var ramp
    init(_ text: String, secondary: Bool = false) {
        self.text = text
        self.secondary = secondary
    }
    var body: some View {
        Text(text).foregroundStyle(secondary ? ramp.shades[0] : Palette.ink).fixedSize(horizontal: false, vertical: true)
    }
}

private struct GuideInset<Content: View>: View {
    var spacing: CGFloat = 2
    @ViewBuilder let content: Content
    @Environment(\.windowRamp) private var ramp
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .bevel(ramp, .inset, fill: ramp.lighter)
    }
}

/// A numbered step (or, without a number, one kind of thing to pick). iPhone portrait drops step icons for width.
private struct GuideStep: View {
    var number: Int?
    let icon: AnyView
    let title: String
    let details: [String]
    let layout: LauncherLayout
    @Environment(\.windowRamp) private var ramp

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let number {
                Text("\(number)").outlined().frame(width: 36, height: 36)
                    .background(ramp.dark)
                    .overlay(alignment: .top) { ramp.midLight.frame(height: px) }
                    .overlay(alignment: .leading) { ramp.midLight.frame(width: px) }
                    .overlay(alignment: .bottom) { ramp.shades[0].frame(height: px) }
                    .overlay(alignment: .trailing) { ramp.shades[0].frame(width: px) }
                    .padding(.top, 6)
            }
            if number == nil || layout != .phonePortrait {
                icon.frame(width: layout == .phonePortrait ? 40 : 48, height: layout == .phonePortrait ? 40 : 48)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                ForEach(details, id: \.self) { Text($0).foregroundStyle(ramp.shades[0]) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 9)
        }
    }
}

private struct FileRow: View {
    let name: String
    let found: Bool
    @Environment(\.windowRamp) private var ramp
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Checkbox(state: found ? .on : .warning).padding(.top, 5)
            Text(name).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(found ? Palette.ink : Palette.white)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(found ? Color.clear : ramp.dark)
    }
}
