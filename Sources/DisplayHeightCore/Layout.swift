import Foundation

public struct Display: Codable, Equatable, Sendable {
    public let identity: String
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let rotation: Int
    public let isMain: Bool

    public init(identity: String, x: Int, y: Int, width: Int, height: Int,
                pixelWidth: Int, pixelHeight: Int, rotation: Int, isMain: Bool) {
        self.identity = identity
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.rotation = rotation
        self.isMain = isMain
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
}

public struct MeasurementPair: Equatable, Sendable {
    public let reference: String
    public let target: String

    public init(reference: String, target: String) {
        self.reference = reference
        self.target = target
    }
}

public struct PointMeasurement: Equatable, Sendable {
    public let pair: MeasurementPair
    public let referenceY: Double
    public let targetY: Double

    public init(pair: MeasurementPair, referenceY: Double, targetY: Double) {
        self.pair = pair
        self.referenceY = referenceY
        self.targetY = targetY
    }
}

public enum LayoutError: Error, Equatable, LocalizedError {
    case invalidConfiguration(String)
    case unreachableDisplays
    case invalidMeasurement(String)
    case impossibleLayout(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message), .invalidMeasurement(let message),
             .impossibleLayout(let message): message
        case .unreachableDisplays: "主画面から左右の隣接関係をたどれない画面があります。"
        }
    }
}

public enum LayoutPlanner {
    public static func sequence(_ displays: [Display]) throws -> [MeasurementPair] {
        try validate(displays)
        let main = displays.first(where: \.isMain)!
        var visited: Set<String> = [main.identity]
        var queue = [main.identity]
        var pairs: [MeasurementPair] = []
        let byID = Dictionary(uniqueKeysWithValues: displays.map { ($0.identity, $0) })

        while !queue.isEmpty {
            let referenceID = queue.removeFirst()
            let reference = byID[referenceID]!
            let neighbors = displays.filter { !visited.contains($0.identity) && adjacent(reference, $0) }
                .sorted { ($0.x, $0.identity) < ($1.x, $1.identity) }
            for target in neighbors {
                visited.insert(target.identity)
                queue.append(target.identity)
                pairs.append(.init(reference: referenceID, target: target.identity))
            }
        }
        guard visited.count == displays.count else { throw LayoutError.unreachableDisplays }
        return pairs
    }

    public static func plannedY(displays: [Display], measurements: [PointMeasurement]) throws -> [String: Int] {
        let pairs = try sequence(displays)
        guard measurements.map(\.pair) == pairs else {
            throw LayoutError.invalidMeasurement("測定順序または測定数が現在の構成と一致しません。")
        }
        let byID = Dictionary(uniqueKeysWithValues: displays.map { ($0.identity, $0) })
        let main = displays.first(where: \.isMain)!
        var result = [main.identity: main.y]
        for item in measurements {
            let reference = byID[item.pair.reference]!
            let target = byID[item.pair.target]!
            guard item.referenceY.isFinite, item.targetY.isFinite,
                  (0...Double(reference.height)).contains(item.referenceY),
                  (0...Double(target.height)).contains(item.targetY) else {
                throw LayoutError.invalidMeasurement("指定点が画面の範囲外です。")
            }
            let exact = Double(result[reference.identity]!) + item.referenceY - item.targetY
            guard exact.isFinite, exact >= Double(Int32.min), exact <= Double(Int32.max) else {
                throw LayoutError.invalidMeasurement("計算した位置がmacOSの設定可能な範囲外です。")
            }
            result[target.identity] = Int(exact.rounded())
        }
        try validatePlannedLayout(displays: displays, y: result, pairs: pairs)
        return result
    }

    public static func matchingConfiguration(_ lhs: [Display], _ rhs: [Display]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        guard Set(lhs.map(\.identity)).count == lhs.count else { return false }
        let rhsByID = Dictionary(rhs.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        guard rhsByID.count == rhs.count else { return false }
        return lhs.allSatisfy { left in
            guard let right = rhsByID[left.identity] else { return false }
            return left.isMain == right.isMain && left.x == right.x &&
                left.width == right.width && left.height == right.height &&
                left.pixelWidth == right.pixelWidth && left.pixelHeight == right.pixelHeight &&
                left.rotation == right.rotation
        }
    }

    public static func sameLayout(_ lhs: [Display], _ rhs: [Display]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        guard Set(lhs.map(\.identity)).count == lhs.count else { return false }
        let rhsByID = Dictionary(rhs.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        guard rhsByID.count == rhs.count else { return false }
        return lhs.allSatisfy { left in rhsByID[left.identity] == left }
    }

    /// The requested origin must be reproduced exactly; rounding of a measured
    /// point is checked separately with a one-unit point tolerance.
    public static func matchesPlannedY(_ actual: [Display], plannedY: [String: Int]) -> Bool {
        guard actual.count == plannedY.count,
              Set(actual.map(\.identity)).count == actual.count else { return false }
        return actual.allSatisfy { $0.y == plannedY[$0.identity] }
    }

    public static func matchesMeasuredPoints(_ measurements: [PointMeasurement],
                                             actual: [Display], tolerance: Double = 1) -> Bool {
        guard tolerance >= 0, tolerance.isFinite,
              Set(actual.map(\.identity)).count == actual.count else { return false }
        let byID = Dictionary(uniqueKeysWithValues: actual.map { ($0.identity, $0) })
        return measurements.allSatisfy { item in
            guard let reference = byID[item.pair.reference],
                  let target = byID[item.pair.target] else { return false }
            return abs(Double(reference.y) + item.referenceY
                       - Double(target.y) - item.targetY) <= tolerance
        }
    }

    /// Only returns positions that can be restored without changing the
    /// current primary display, horizontal origins, or display modes.
    public static func restorableY(original: [Display], current: [Display]) -> [String: Int]? {
        guard original.first(where: \.isMain)?.identity == current.first(where: \.isMain)?.identity else {
            return nil
        }
        let originalByID = Dictionary(original.map { ($0.identity, $0) },
                                      uniquingKeysWith: { first, _ in first })
        var result: [String: Int] = [:]
        for display in current where !display.isMain {
            guard let old = originalByID[display.identity],
                  old.x == display.x, old.width == display.width, old.height == display.height,
                  old.pixelWidth == display.pixelWidth, old.pixelHeight == display.pixelHeight,
                  old.rotation == display.rotation else { continue }
            result[display.identity] = old.y
        }
        return result
    }

    public static func validatePlannedLayout(displays: [Display], y: [String: Int],
                                             pairs: [MeasurementPair]) throws {
        try validate(displays)
        guard y.count == displays.count,
              displays.allSatisfy({ display in
                  guard let position = y[display.identity] else { return false }
                  return validExtent(origin: position, size: display.height)
              }) else {
            throw LayoutError.impossibleLayout("予定位置が不足しているか、設定可能な範囲外です。")
        }
        let byID = Dictionary(uniqueKeysWithValues: displays.map { ($0.identity, $0) })
        for i in displays.indices {
            for j in displays.indices where j > i {
                let a = displays[i], b = displays[j]
                let overlapX = min(a.maxX, b.maxX) - max(a.x, b.x)
                let overlapY = min(y[a.identity]! + a.height, y[b.identity]! + b.height)
                    - max(y[a.identity]!, y[b.identity]!)
                if overlapX > 0 && overlapY > 0 {
                    throw LayoutError.impossibleLayout("画面の領域が重なります。")
                }
            }
        }
        for pair in pairs {
            let a = byID[pair.reference]!, b = byID[pair.target]!
            let overlapY = min(y[a.identity]! + a.height, y[b.identity]! + b.height)
                - max(y[a.identity]!, y[b.identity]!)
            guard (a.maxX == b.x || b.maxX == a.x), overlapY > 0 else {
                throw LayoutError.impossibleLayout("測定した画面同士の左右の接触が失われます。")
            }
        }
    }

    private static func validate(_ displays: [Display]) throws {
        guard displays.count >= 2, displays.filter(\.isMain).count == 1,
              Set(displays.map(\.identity)).count == displays.count,
              displays.allSatisfy({ display in
                  !display.identity.isEmpty && display.pixelWidth > 0 && display.pixelHeight > 0 &&
                  validExtent(origin: display.x, size: display.width) &&
                  validExtent(origin: display.y, size: display.height)
              }) else {
            throw LayoutError.invalidConfiguration("2枚以上の一意に識別できる拡張画面と主画面が必要です。")
        }
        for i in displays.indices {
            for j in displays.indices where j > i {
                let a = displays[i], b = displays[j]
                if min(a.maxX, b.maxX) > max(a.x, b.x) &&
                    min(a.maxY, b.maxY) > max(a.y, b.y) {
                    throw LayoutError.invalidConfiguration("開始時の画面配置が重なっています。")
                }
            }
        }
    }

    private static func validExtent(origin: Int, size: Int) -> Bool {
        guard size > 0, Int32(exactly: origin) != nil, Int32(exactly: size) != nil else { return false }
        let (end, overflow) = origin.addingReportingOverflow(size)
        return !overflow && Int32(exactly: end) != nil
    }

    private static func adjacent(_ a: Display, _ b: Display) -> Bool {
        (a.maxX == b.x || b.maxX == a.x) && min(a.maxY, b.maxY) > max(a.y, b.y)
    }
}

public struct ConnectionTracker: Sendable {
    public private(set) var lastTopology: String?
    public private(set) var canceledTopology: String?

    public init() {}

    /// A change to positions alone must not trigger an automatic restore.
    public static func shouldRecheckAfterInterruption(from previousTopology: String,
                                                      to currentTopology: String) -> Bool {
        previousTopology != currentTopology
    }

    public mutating func cancel(_ topology: String) {
        canceledTopology = topology
    }

    /// Record every stable topology, including a single remaining display.
    /// A canceled topology becomes eligible again only after a different one appears.
    public mutating func observe(_ topology: String, force: Bool = false) -> Bool {
        let changed = lastTopology != topology
        lastTopology = topology
        if canceledTopology != topology { canceledTopology = nil }
        return (force || changed) && canceledTopology != topology
    }
}
