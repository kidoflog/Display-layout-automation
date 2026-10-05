import Foundation
import DisplayHeightCore

struct SavedProfile: Codable {
    let displays: [Display]
    let savedAt: Date

    var key: String { ProfileStore.key(for: displays) }
}

struct ProfileStore {
    private let fileURL: URL

    init() throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask, appropriateFor: nil,
                                                  create: true)
        let folder = support.appendingPathComponent("DisplayHeight", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("profiles.json")
    }

    init(fileURL: URL) { self.fileURL = fileURL }

    func load() throws -> [String: SavedProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let decoded = try JSONDecoder().decode([String: SavedProfile].self, from: Data(contentsOf: fileURL))
        return decoded.filter { key, profile in
            key == profile.key && (try? LayoutPlanner.sequence(profile.displays)) != nil
        }
    }

    func save(_ profile: SavedProfile) throws {
        var all: [String: SavedProfile]
        do {
            all = try load()
        } catch is DecodingError {
            // Keep the damaged file for inspection before replacing it.
            let backup = fileURL.deletingLastPathComponent().appendingPathComponent(
                "profiles.corrupt-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).json")
            try FileManager.default.moveItem(at: fileURL, to: backup)
            all = [:]
        }
        all[profile.key] = profile
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(all).write(to: fileURL, options: .atomic)
    }

    static func key(for displays: [Display]) -> String {
        displays.sorted { $0.identity < $1.identity }.map {
            "\($0.identity):\($0.isMain):\($0.width)x\($0.height):\($0.pixelWidth)x\($0.pixelHeight):\($0.rotation)"
        }.joined(separator: "|")
    }
}
