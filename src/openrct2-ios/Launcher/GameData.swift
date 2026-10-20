/*****************************************************************************
 * Copyright (c) 2026 OpenRCT2 developers
 * OpenRCT2 is licensed under the GNU General Public License version 3.
 *****************************************************************************/
import Foundation

enum Slot: String, Codable, CaseIterable {
    case rct2, rct1
}

/// What the launcher found in one imported slot; stored next to the data as .openrct2-import.json.
struct GameDataInfo: Codable, Equatable {
    struct Source: Codable, Equatable {
        enum Kind: String, Codable { case folder, zip, gogInstaller, migrated }
        var kind: Kind
        var file: String?
        var gogName: String?
        var gogBuildId: String?
        var language: String?
    }

    static let detectorVersion = 1

    var slot: Slot
    var variant: Int
    var source: Source
    var g1Entries: Int?
    var wackyWorlds: Double?
    var timeTwister: Double?
    var sounds: Int
    var scenarios: Int
    var rct1Usable: Bool?
    var bytes: Int64
    var importedAt: Date
    var detector: Int

    var isClassic: Bool { slot == .rct2 && variant != ORCTRCT2Variant.original.rawValue }

    var title: String {
        switch slot {
        case .rct1: "RollerCoaster Tycoon Deluxe"
        case .rct2: isClassic ? "RollerCoaster Tycoon Classic" : "RollerCoaster Tycoon 2"
        }
    }

    var edition: String? {
        guard slot == .rct2, !isClassic else { return slot == .rct1 && rct1Usable == true ? "含 Loopy Landscapes" : nil }
        let ww = (wackyWorlds ?? 0) >= 0.99, tt = (timeTwister ?? 0) >= 0.99
        switch (ww, tt) {
        case (true, true): return "Triple Thrill Pack"
        case (true, false): return "含 Wacky Worlds"
        case (false, true): return "含 Time Twister"
        case (false, false): return "原版（无扩展包）"
        }
    }

    var sourceLine: String {
        var parts: [String] = []
        switch source.kind {
        case .folder: parts.append("来自文件夹")
        case .zip: parts.append("来自 ZIP")
        case .gogInstaller: parts.append("来自 GOG 安装包")
        case .migrated: parts.append("旧版本导入")
        }
        if let name = source.gogName { parts.append("GOG · \(name)") }
        if let language = source.language { parts.append(language) }
        return parts.joined(separator: " · ")
    }
}

enum GameDataError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): text }
    }
}

// MARK: - Locations

enum GameDataLocation {
    static let root: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("GameData", isDirectory: true)
    }()
    static func folder(_ slot: Slot) -> URL { root.appendingPathComponent(slot.rawValue, isDirectory: true) }
    static func metadata(_ slot: Slot) -> URL { folder(slot).appendingPathComponent(".openrct2-import.json") }
    static let workspaces = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Import", isDirectory: true)
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let legacyRCT2 = documents.appendingPathComponent("RCT2", isDirectory: true)
}

// MARK: - File helpers

extension FileManager {
    func child(_ directory: URL, named name: String) -> URL? {
        guard let children = try? contentsOfDirectory(atPath: directory.path) else { return nil }
        return children.first { $0.caseInsensitiveCompare(name) == .orderedSame }.map { directory.appendingPathComponent($0) }
    }

    func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    func allocatedSize(of url: URL) -> Int64 {
        guard let enumerator = enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

// MARK: - Detection

enum Detector {
    /// ObjData files referenced by the bundled Wacky Worlds and Time Twister objects.
    private static let expansionFiles: [String: Set<String>] = {
        let objects = Bundle.main.resourceURL!.appendingPathComponent("data/object")
        let pattern = try! NSRegularExpression(pattern: #"\$RCT2:OBJDATA/([^"\[]+)"#, options: .caseInsensitive)
        var result: [String: Set<String>] = [:]
        for source in ["rct2ww", "rct2tt"] {
            var names = Set<String>()
            let enumerator = FileManager.default.enumerator(at: objects.appendingPathComponent(source), includingPropertiesForKeys: nil)
            while let file = enumerator?.nextObject() as? URL {
                guard file.pathExtension == "json", let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    if let range = Range(match.range(at: 1), in: text) { names.insert(text[range].uppercased()) }
                }
            }
            result[source] = names
        }
        return result
    }()

    static func inspect(_ folder: URL, slot: Slot, source: GameDataInfo.Source, importedAt: Date = Date()) -> GameDataInfo {
        let files = FileManager.default
        let data = files.child(folder, named: "Data")
        var info = GameDataInfo(
            slot: slot, variant: -1, source: source, sounds: 0, scenarios: 0, bytes: files.allocatedSize(of: folder),
            importedAt: importedAt, detector: GameDataInfo.detectorVersion)
        let scenarios = files.child(folder, named: "Scenarios")
        info.scenarios = scenarios.flatMap { try? files.contentsOfDirectory(atPath: $0.path) }?
            .filter { ["sc6", "sc4", "sea"].contains(($0 as NSString).pathExtension.lowercased()) }.count ?? 0

        switch slot {
        case .rct1:
            info.rct1Usable = ORCTLauncherBridge.rct1Usable(atPath: folder.path)
            info.variant = 0
        case .rct2:
            info.variant = ORCTLauncherBridge.classifyRCT2(atPath: folder.path).rawValue
            if info.variant == ORCTRCT2Variant.original.rawValue {
                if let g1 = data.flatMap({ files.child($0, named: "g1.dat") }),
                    let handle = try? FileHandle(forReadingFrom: g1), let header = try? handle.read(upToCount: 4), header.count == 4
                {
                    info.g1Entries = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
                    try? handle.close()
                }
                let present = Set(files.child(folder, named: "ObjData").flatMap { try? files.contentsOfDirectory(atPath: $0.path) }?
                    .map { $0.uppercased() } ?? [])
                func share(_ key: String) -> Double? {
                    guard let wanted = expansionFiles[key], !wanted.isEmpty else { return nil }
                    return Double(wanted.intersection(present).count) / Double(wanted.count)
                }
                info.wackyWorlds = share("rct2ww")
                info.timeTwister = share("rct2tt")
                info.sounds = (1...46).filter { n in data.flatMap { files.child($0, named: "css\(n).dat") } != nil }.count
            } else {
                info.sounds = 46
            }
        }
        return info
    }
}

// MARK: - Store

@MainActor
final class GameDataStore: ObservableObject {
    @Published private(set) var installed: [Slot: GameDataInfo] = [:]
    @Published private(set) var loading = true

    var canPlay: Bool { installed[.rct2] != nil }

    func load() async {
        loading = true
        installed = await Task.detached(priority: .userInitiated) { Self.loadAll() }.value
        loading = false
    }

    func remove(_ slot: Slot) async {
        await Task.detached { try? FileManager.default.removeItem(at: GameDataLocation.folder(slot)) }.value
        installed[slot] = nil
    }

    func redetect() async {
        let current = installed
        installed = await Task.detached(priority: .userInitiated) {
            current.mapValues { Self.writeInfo(Detector.inspect(GameDataLocation.folder($0.slot), slot: $0.slot, source: $0.source, importedAt: $0.importedAt)) }
        }.value
    }

    func didImport(_ infos: [GameDataInfo]) {
        for info in infos { installed[info.slot] = info }
    }

    nonisolated static func writeInfo(_ info: GameDataInfo) -> GameDataInfo {
        writeInfoAt(GameDataLocation.folder(info.slot), info)
    }

    private nonisolated static func loadAll() -> [Slot: GameDataInfo] {
        let files = FileManager.default
        try? files.createDirectory(at: GameDataLocation.root, withIntermediateDirectories: true)
        var root = GameDataLocation.root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        cleanWorkspaces()
        migrateLegacyFolder()

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var result: [Slot: GameDataInfo] = [:]
        for slot in Slot.allCases {
            let folder = GameDataLocation.folder(slot)
            guard files.isDirectory(folder) else { continue }
            var info = (try? Data(contentsOf: GameDataLocation.metadata(slot))).flatMap { try? decoder.decode(GameDataInfo.self, from: $0) }
            if info == nil || info!.detector != GameDataInfo.detectorVersion {
                info = writeInfo(Detector.inspect(folder, slot: slot, source: info?.source ?? .init(kind: .migrated), importedAt: info?.importedAt ?? Date()))
            }
            let valid = slot == .rct2 ? info!.variant >= 0 : true
            if valid { result[slot] = info }
        }
        return result
    }

    /// Earlier builds imported into Documents/RCT2, where the Files app shows it. Move it out of sight once.
    private nonisolated static func migrateLegacyFolder() {
        let files = FileManager.default
        let legacy = GameDataLocation.legacyRCT2, target = GameDataLocation.folder(.rct2)
        guard files.isDirectory(legacy), !files.fileExists(atPath: target.path),
            ORCTLauncherBridge.classifyRCT2(atPath: legacy.path) != .none
        else { return }
        try? files.moveItem(at: legacy, to: target)
    }

    private nonisolated static func cleanWorkspaces() {
        let files = FileManager.default
        try? files.removeItem(at: GameDataLocation.workspaces)
        for name in (try? files.contentsOfDirectory(atPath: GameDataLocation.root.path)) ?? [] where name.hasPrefix(".staging-") || name.hasPrefix(".old-") {
            try? files.removeItem(at: GameDataLocation.root.appendingPathComponent(name))
        }
    }
}
