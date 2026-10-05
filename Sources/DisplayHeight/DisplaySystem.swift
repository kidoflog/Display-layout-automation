import AppKit
import CoreGraphics
import DisplayHeightCore

struct ConnectedDisplay {
    let id: CGDirectDisplayID
    let layout: Display
    let screen: NSScreen

    var active: ActiveDisplay { .init(id: id, layout: layout) }
}

struct ActiveDisplay {
    let id: CGDirectDisplayID
    let layout: Display
}

enum DisplaySystemError: Error, LocalizedError {
    case unavailable(String)
    case transient(String)
    case graphics(CGError)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .transient(let message): message
        case .graphics(let error): "macOSの画面配置APIでエラーが発生しました（\(error.rawValue)）。"
        }
    }
}

enum DisplaySystem {
    @MainActor static func activeDisplays() throws -> [ActiveDisplay] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        let result = CGGetActiveDisplayList(UInt32(ids.count), &ids, &count)
        guard result == .success else { throw DisplaySystemError.graphics(result) }
        guard count <= ids.count else { throw DisplaySystemError.unavailable("画面数が上限を超えました。") }
        var found: [ActiveDisplay] = []
        for id in ids.prefix(Int(count)) {
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else {
                throw DisplaySystemError.unavailable("画面の識別子を取得できません。")
            }
            guard let mode = CGDisplayCopyDisplayMode(id) else {
                throw DisplaySystemError.unavailable("画面の表示設定を取得できません。")
            }
            let frame = CGDisplayBounds(id)
            let layout = Display(identity: CFUUIDCreateString(nil, uuid) as String,
                                 x: Int(frame.minX.rounded()), y: Int(frame.minY.rounded()),
                                 width: Int(frame.width.rounded()), height: Int(frame.height.rounded()),
                                 pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                                 rotation: Int(CGDisplayRotation(id).rounded()),
                                 isMain: CGDisplayIsMain(id) != 0)
            found.append(.init(id: id, layout: layout))
        }
        guard Set(found.map(\.layout.identity)).count == found.count else {
            throw DisplaySystemError.unavailable("同じ識別子の画面があり、正しく対応付けられません。")
        }
        return found
    }

    @MainActor static func snapshot() throws -> [ConnectedDisplay] {
        let active = try activeDisplays()
        guard active.count >= 2 else {
            throw DisplaySystemError.unavailable("2枚以上の拡張ディスプレイが必要です。")
        }
        return try active.map { display in
            guard CGDisplayIsInMirrorSet(display.id) == 0 else {
                throw DisplaySystemError.unavailable("ミラーリングされた画面は対象外です。")
            }
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id
            }) else {
                throw DisplaySystemError.transient("画面とオーバーレイを対応付けられません。")
            }
            try verifySupportedDisplay(id: display.id, screen: screen)
            return .init(id: display.id, layout: display.layout, screen: screen)
        }
    }

    @MainActor private static func verifySupportedDisplay(id: CGDirectDisplayID,
                                                            screen: NSScreen) throws {
        let name = screen.localizedName.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                                locale: nil)
        let excludedNames = ["sidecar", "airplay", "virtual", "ipad", "iphone", "apple tv",
                             "サイドカー", "エアプレイ", "仮想", "ワイヤレス"]
        guard !excludedNames.contains(where: name.contains) else {
            throw DisplaySystemError.unavailable("Sidecar、AirPlay、仮想画面は対象外です。")
        }
        if CGDisplayIsBuiltin(id) == 0 {
            let size = CGDisplayScreenSize(id)
            guard CGDisplayVendorNumber(id) != 0, CGDisplayModelNumber(id) != 0,
                  size.width > 0, size.height > 0 else {
                throw DisplaySystemError.unavailable(
                    "物理的な外部ディスプレイと確認できない画面があります。")
            }
        }
    }

    @MainActor static func apply(_ y: [String: Int], to displays: [ConnectedDisplay],
                                 permanent: Bool) throws {
        try apply(y, to: displays.map(\.active), permanent: permanent)
    }

    @MainActor static func apply(_ y: [String: Int], to displays: [ActiveDisplay],
                                 permanent: Bool) throws {
        let movable = displays.filter { !$0.layout.isMain }
        guard !movable.isEmpty else { return }
        var configuration: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&configuration)
        guard begin == .success else { throw DisplaySystemError.graphics(begin) }
        guard let configuration else { throw DisplaySystemError.unavailable("配置変更を開始できません。") }
        for display in movable {
            guard let originY = y[display.layout.identity],
                  let x = Int32(exactly: display.layout.x),
                  let newY = Int32(exactly: originY) else {
                CGCancelDisplayConfiguration(configuration)
                throw DisplaySystemError.unavailable("画面の予定位置を適用できません。")
            }
            let result = CGConfigureDisplayOrigin(configuration, display.id, x, newY)
            guard result == .success else {
                CGCancelDisplayConfiguration(configuration)
                throw DisplaySystemError.graphics(result)
            }
        }
        let result = CGCompleteDisplayConfiguration(configuration,
                                                    permanent ? .permanently : .forAppOnly)
        guard result == .success else { throw DisplaySystemError.graphics(result) }
    }
}
