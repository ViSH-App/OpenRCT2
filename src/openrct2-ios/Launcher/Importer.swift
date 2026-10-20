/*****************************************************************************
 * Copyright (c) 2026 OpenRCT2 developers
 * OpenRCT2 is licensed under the GNU General Public License version 3.
 *****************************************************************************/
import Foundation

/// Every source only places files in a workspace; finding, copying, checking and installing is shared.
@MainActor
final class Importer: ObservableObject {
    enum Step: Int, CaseIterable {
        case reading, checking, unpacking, verifying, installing
        var title: String {
            switch self {
            case .reading: "读取文件"
            case .checking: "查找游戏数据"
            case .unpacking: "解压"
            case .verifying: "复制并校验"
            case .installing: "安装到游戏目录"
            }
        }
    }

    @Published private(set) var step: Step = .reading
    @Published private(set) var progress: Double = 0
    @Published private(set) var detail = ""

    private let cancelFlag = CancelFlag()
    func cancel() { cancelFlag.set() }

    /// Imports the picked files or folders and returns what was installed.
    func run(_ urls: [URL]) async throws -> [GameDataInfo] {
        let flag = cancelFlag
        let report: @Sendable (Step, Double, String) -> Void = { step, progress, detail in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.step = step
                self.progress = progress
                if !detail.isEmpty { self.detail = detail }
            }
        }
        return try await Task.detached(priority: .userInitiated) {
            try Self.perform(urls, cancel: flag, report: report)
        }.value
    }

    private struct Candidate {
        let slot: Slot
        let folder: URL
        let source: GameDataInfo.Source
        let score: Int
    }

    private nonisolated static func perform(_ urls: [URL], cancel: CancelFlag, report: @escaping @Sendable (Step, Double, String) -> Void) throws -> [GameDataInfo] {
        let files = FileManager.default
        let workspace = GameDataLocation.workspaces.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: workspace) }

        // Hold access to everything picked until the copy is done: folders are read in place.
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }

        report(.reading, 0, urls.map(\.lastPathComponent).joined(separator: "、"))
        var roots: [(URL, GameDataInfo.Source)] = []
        for (index, url) in urls.enumerated() {
            try coordinatedRead(url)
            if files.isDirectory(url) {
                roots.append((url, .init(kind: .folder, file: url.lastPathComponent)))
                continue
            }
            switch try format(of: url) {
            case .zip:
                let target = workspace.appendingPathComponent("zip-\(index)", isDirectory: true)
                try files.createDirectory(at: target, withIntermediateDirectories: true)
                report(.unpacking, 0, url.lastPathComponent)
                do {
                    try ORCTLauncherBridge.extractZip(
                        atPath: url.path, toDirectory: target.path,
                        progress: { report(.unpacking, $0, "") }, cancelled: { cancel.isSet })
                } catch {
                    if cancel.isSet { throw CancellationError() }
                    throw error
                }
                roots.append((target, .init(kind: .zip, file: url.lastPathComponent)))
            case .gogInstaller:
                throw GameDataError.message("GOG 安装包（.exe 和 .bin）将在后续版本支持。现在可以先在电脑上解包，再导入解包后的文件夹或 ZIP。")
            case .otherArchive(let name):
                throw GameDataError.message("暂不支持 \(name) 格式，后续版本会加入。现在请改用 ZIP，或直接选择游戏文件夹。")
            case .unknown:
                throw GameDataError.message("「\(url.lastPathComponent)」不是游戏文件夹，也不是 ZIP 压缩包。")
            }
        }
        if cancel.isSet { throw CancellationError() }

        report(.checking, 0, "")
        var candidates: [Candidate] = []
        for (root, source) in roots { scan(root, depth: 0, source: source, into: &candidates) }
        var chosen: [Slot: Candidate] = [:]
        for candidate in candidates where (chosen[candidate.slot]?.score ?? -1) < candidate.score {
            chosen[candidate.slot] = candidate
        }
        guard !chosen.isEmpty else {
            throw GameDataError.message("没有找到游戏数据。RCT2 的文件夹里应当有 Data/g1.dat；Classic 应当有 Assets/g1.dat。")
        }

        // Copy only what the engine reads into a staging folder per slot, then verify it.
        let plans = chosen.values.sorted { $0.slot.rawValue > $1.slot.rawValue }.map { ($0, wantedItems($0)) }
        let total = max(1, plans.reduce(Int64(0)) { sum, plan in sum + plan.1.reduce(0) { $0 + files.allocatedSize(of: $1) + 1 } })
        var copied: Int64 = 0
        var staged: [(Candidate, URL)] = []
        for (candidate, items) in plans {
            let staging = GameDataLocation.root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
            try files.createDirectory(at: staging, withIntermediateDirectories: true)
            for item in items {
                if cancel.isSet { throw CancellationError() }
                let relative = String(item.path.dropFirst(candidate.folder.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let target = staging.appendingPathComponent(relative)
                try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                report(.verifying, Double(copied) / Double(total), relative)
                do { try files.copyItem(at: item, to: target) } catch {
                    throw GameDataError.message("复制「\(relative)」失败，可能是存储空间不足。")
                }
                copied += files.allocatedSize(of: item) + 1
            }
            let valid = candidate.slot == .rct2
                ? ORCTLauncherBridge.classifyRCT2(atPath: staging.path) != .none
                : ORCTLauncherBridge.rct1Present(atPath: staging.path)
            guard valid else { throw GameDataError.message("复制后的数据不完整，请重新导入。") }
            staged.append((candidate, staging))
        }

        report(.installing, 1, "")
        var installed: [GameDataInfo] = []
        for (candidate, staging) in staged {
            let info = GameDataStore.writeInfoAt(staging, Detector.inspect(staging, slot: candidate.slot, source: candidate.source))
            let target = GameDataLocation.folder(candidate.slot)
            if files.fileExists(atPath: target.path) {
                _ = try files.replaceItemAt(target, withItemAt: staging)
            } else {
                try files.moveItem(at: staging, to: target)
            }
            installed.append(info)
        }
        return installed
    }

    // MARK: Helpers

    private enum Format { case zip, gogInstaller, otherArchive(String), unknown }

    private nonisolated static func format(of url: URL) throws -> Format {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = [UInt8](try handle.read(upToCount: 8) ?? Data())
        func starts(_ bytes: [UInt8]) -> Bool { head.count >= bytes.count && Array(head.prefix(bytes.count)) == bytes }
        if starts([0x50, 0x4B, 0x03, 0x04]) || starts([0x50, 0x4B, 0x05, 0x06]) { return .zip }
        if starts([0x4D, 0x5A]) || starts(Array("idska".utf8)) { return .gogInstaller }
        if starts([0x37, 0x7A, 0xBC, 0xAF]) { return .otherArchive("7z") }
        if starts(Array("Rar!".utf8)) { return .otherArchive("RAR") }
        if starts([0x1F, 0x8B]) || starts([0x42, 0x5A, 0x68]) || starts([0xFD, 0x37, 0x7A, 0x58]) { return .otherArchive("TAR") }
        return .unknown
    }

    /// Files in iCloud may not be downloaded yet; a coordinated read brings them down.
    private nonisolated static func coordinatedRead(_ url: URL) throws {
        var coordinatorError: NSError?
        var innerError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { _ in
            if !FileManager.default.fileExists(atPath: url.path) {
                innerError = GameDataError.message("无法读取「\(url.lastPathComponent)」。")
            }
        }
        if let error = coordinatorError ?? innerError { throw error }
    }

    private nonisolated static func scan(_ folder: URL, depth: Int, source: GameDataInfo.Source, into candidates: inout [Candidate]) {
        let files = FileManager.default
        let rct2 = ORCTLauncherBridge.classifyRCT2(atPath: folder.path)
        if rct2 != .none {
            let objects = files.child(folder, named: "ObjData").flatMap { try? files.contentsOfDirectory(atPath: $0.path).count } ?? 0
            candidates.append(Candidate(slot: .rct2, folder: folder, source: gogDetails(folder, source), score: objects + (rct2 == .original ? 1 : 0)))
        } else if ORCTLauncherBridge.rct1Present(atPath: folder.path) {
            let usable = ORCTLauncherBridge.rct1Usable(atPath: folder.path)
            candidates.append(Candidate(slot: .rct1, folder: folder, source: gogDetails(folder, source), score: usable ? 2 : 1))
        }
        guard depth < 4, let children = try? files.contentsOfDirectory(atPath: folder.path) else { return }
        for name in children where !name.hasPrefix(".") && name != "__MACOSX" {
            let child = folder.appendingPathComponent(name)
            if files.isDirectory(child) { scan(child, depth: depth + 1, source: source, into: &candidates) }
        }
    }

    /// GOG installs carry goggame-<id>.info with the product name, build and language.
    private nonisolated static func gogDetails(_ folder: URL, _ source: GameDataInfo.Source) -> GameDataInfo.Source {
        var result = source
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        guard let info = names.first(where: { $0.lowercased().hasPrefix("goggame-") && $0.lowercased().hasSuffix(".info") }),
            let data = try? Data(contentsOf: folder.appendingPathComponent(info)),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return result }
        result.gogName = json["name"] as? String
        result.gogBuildId = json["buildId"] as? String
        result.language = json["language"] as? String
        return result
    }

    private nonisolated static func wantedItems(_ candidate: Candidate) -> [URL] {
        let files = FileManager.default
        let folder = candidate.folder
        let names: [String]
        switch (candidate.slot, ORCTLauncherBridge.classifyRCT2(atPath: folder.path)) {
        case (.rct1, _): names = ["Data", "Scenarios", "Tracks", "Landscapes", "RCTdeluxe_install"]
        case (_, .classicWindows): names = ["Assets"]
        case (_, .classicMac): names = ["RCT Classic.app"]
        case (_, .classicPlusMac): names = ["RCT Classic+.app"]
        default: names = ["Data", "ObjData", "Scenarios", "Tracks", "Landscapes", "Saved Games"]
        }
        var items = names.compactMap { files.child(folder, named: $0) }
        // From a macOS app bundle only its resources matter.
        items = items.map { item in
            item.pathExtension == "app" ? item.appendingPathComponent("Contents/Resources") : item
        }
        return items
    }
}

extension GameDataStore {
    nonisolated static func writeInfoAt(_ folder: URL, _ info: GameDataInfo) -> GameDataInfo {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(info).write(to: folder.appendingPathComponent(".openrct2-import.json"), options: .atomic)
        return info
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
