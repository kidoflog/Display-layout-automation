import Foundation
import DisplayHeightCore

@main struct ProfileStoreChecks {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "DisplayHeightProfileChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let file = folder.appendingPathComponent("profiles.json")
        let damaged = Data("{broken".utf8)
        try damaged.write(to: file)
        let store = ProfileStore(fileURL: file)
        let first = profile("A", "B")
        try store.save(first)
        let recovered = try store.load()
        precondition(recovered[first.key] != nil, "damaged file recovery")
        let backups = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("profiles.corrupt-") && $0.hasSuffix(".json") }
        precondition(backups.count == 1, "damaged file backup")
        let backedUp = try Data(contentsOf: folder.appendingPathComponent(backups[0]))
        precondition(backedUp == damaged, "backup preserves original bytes")

        let second = profile("C", "D")
        try store.save(second)
        let saved = try store.load()
        precondition(saved[first.key] != nil && saved[second.key] != nil,
                     "existing configurations remain saved")
        print("ProfileStoreChecks: all checks passed")
    }

    private static func profile(_ main: String, _ other: String) -> SavedProfile {
        let displays = [
            Display(identity: main, x: 0, y: 0, width: 100, height: 100,
                    pixelWidth: 200, pixelHeight: 200, rotation: 0, isMain: true),
            Display(identity: other, x: 100, y: 0, width: 100, height: 100,
                    pixelWidth: 200, pixelHeight: 200, rotation: 0, isMain: false)
        ]
        return SavedProfile(displays: displays, savedAt: Date())
    }
}
