/*****************************************************************************
 * Copyright (c) 2026 OpenRCT2 developers
 * OpenRCT2 is licensed under the GNU General Public License version 3.
 *****************************************************************************/
import SwiftUI

/// One bundled component, as listed by scripts/collect-licenses.py in data/licenses/index.json.
struct LicenseEntry: Decodable, Identifiable {
    let id: String
    let name: String
    let version: String
    let license: String
    let url: String
    let file: String

    private static let folder = Bundle.main.resourceURL!.appendingPathComponent("data/licenses")

    static func load() -> [LicenseEntry] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("index.json")) else { return [] }
        return (try? JSONDecoder().decode([LicenseEntry].self, from: data)) ?? []
    }

    /// The text split into paragraphs, so long licenses such as the GPL lay out lazily.
    func paragraphs() -> [String] {
        let text = (try? String(contentsOf: Self.folder.appendingPathComponent(file), encoding: .utf8)) ?? ""
        return text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.isEmpty }
    }
}

/// The open source licenses of the app and of everything it bundles: a list, then one license's text.
struct LicensesWindow: View {
    let layout: LauncherLayout
    let onClose: () -> Void
    @State private var entries = LicenseEntry.load()
    @State private var selected: LicenseEntry?
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let selected {
            RctWindow(title: selected.name, ramp: .grey, onBack: { self.selected = nil }, onClose: layout.isPhone ? nil : onClose) {
                detail(selected)
            }
        } else {
            RctWindow(title: String(localized: "开源许可"), ramp: .grey, onBack: layout.isPhone ? onClose : nil, onClose: layout.isPhone ? nil : onClose) {
                list
            }
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("OpenRCT2 是基于 GNU GPL v3 发布的开源软件。本 App 还包含以下开源组件、素材与字体。")
                    .font(PixelFont.small).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
                if entries.isEmpty {
                    Text("未找到许可证文件。").font(PixelFont.body).foregroundStyle(Palette.ink)
                }
                ForEach(entries) { entry in
                    Button { selected = entry } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                Text(entry.version.isEmpty ? entry.license : "\(entry.version) · \(entry.license)").font(PixelFont.small)
                            }
                            Spacer(minLength: 0)
                            Text("›")
                        }
                        .padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(RctButtonStyle())
                    .multilineTextAlignment(.leading)
                }
            }
            .padding(14)
        }
        .scrollIndicators(.hidden)
    }

    private func detail(_ entry: LicenseEntry) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(entry.version.isEmpty ? entry.license : "\(entry.version) · \(entry.license)")
                        .font(PixelFont.body).foregroundStyle(Palette.ink)
                    Spacer(minLength: 0)
                    if let url = URL(string: entry.url) {
                        Button("项目主页") { openURL(url) }.buttonStyle(RctButtonStyle())
                    }
                }
                ForEach(Array(entry.paragraphs().enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph).font(PixelFont.small).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            .padding(14)
            .bevel(.grey, .inset)
            .padding(10)
        }
        .scrollIndicators(.hidden)
        .id(entry.id)
    }
}

/// The launcher's small "开源许可" link, kept beside the version rather than among the menu buttons.
struct LicensesLink: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text("开源许可").font(PixelFont.small).underline().outlined()
                .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
