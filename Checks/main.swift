import DisplayHeightCore

func screen(_ id: String, _ x: Int, _ y: Int, main: Bool = false) -> Display {
    Display(identity: id, x: x, y: y, width: 100, height: 100,
            pixelWidth: 200, pixelHeight: 200, rotation: 0, isMain: main)
}

func sizedScreen(_ id: String, _ x: Int, _ y: Int, _ width: Int, _ height: Int,
                 main: Bool = false) -> Display {
    Display(identity: id, x: x, y: y, width: width, height: height,
            pixelWidth: width * 2, pixelHeight: height * 2, rotation: 0, isMain: main)
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

do {
    let chain = [screen("A", 0, 0, main: true), screen("B", 100, 0), screen("C", 200, 0)]
    let pairs = try LayoutPlanner.sequence(chain)
    check(pairs == [.init(reference: "A", target: "B"), .init(reference: "B", target: "C")],
          "3枚の測定順序")
    let result = try LayoutPlanner.plannedY(displays: chain, measurements: [
        .init(pair: pairs[0], referenceY: 40, targetY: 50),
        .init(pair: pairs[1], referenceY: 60, targetY: 20)
    ])
    check(result == ["A": 0, "B": -10, "C": 30], "連鎖時に予定位置を使用")

    let differentSizes = [sizedScreen("A", 0, 0, 120, 90, main: true),
                          sizedScreen("B", 120, 0, 80, 150)]
    let differentPair = try LayoutPlanner.sequence(differentSizes)[0]
    let differentY = try LayoutPlanner.plannedY(displays: differentSizes, measurements: [
        .init(pair: differentPair, referenceY: 45, targetY: 75)
    ])
    check(differentY == ["A": 0, "B": -30], "異なる画面サイズの座標変換")

    let four = [screen("A", 0, 0, main: true), screen("B", 100, 0),
                screen("C", 200, 0), screen("D", 300, 0)]
    let fourPairs = try LayoutPlanner.sequence(four)
    check(fourPairs == [
        .init(reference: "A", target: "B"), .init(reference: "B", target: "C"),
        .init(reference: "C", target: "D")
    ], "4枚の連鎖順序")

    let branch = [screen("L", -100, 0), screen("M", 0, 0, main: true),
                  screen("R", 100, 0), screen("RR", 200, 0)]
    let branchPairs = try LayoutPlanner.sequence(branch)
    check(branchPairs == [
        .init(reference: "M", target: "L"), .init(reference: "M", target: "R"),
        .init(reference: "R", target: "RR")
    ], "主画面の両側から幅優先で進む")

    let middle = [screen("A", 0, 0), screen("M", 100, 0, main: true), screen("C", 200, 0)]
    let middlePairs = try LayoutPlanner.sequence(middle)
    check(middlePairs == [
        .init(reference: "M", target: "A"), .init(reference: "M", target: "C")
    ], "主画面が中央の測定順序")

    let two = [screen("A", 0, 0, main: true), screen("B", 100, 0)]
    let pair = try LayoutPlanner.sequence(two)[0]
    do {
        _ = try LayoutPlanner.plannedY(displays: two, measurements: [
            .init(pair: pair, referenceY: 0, targetY: 100)
        ])
        preconditionFailure("接触しない配置を拒否")
    } catch LayoutError.impossibleLayout { }

    do {
        _ = try LayoutPlanner.plannedY(displays: two, measurements: [])
        preconditionFailure("測定数の不一致を拒否")
    } catch LayoutError.invalidMeasurement { }
    do {
        _ = try LayoutPlanner.plannedY(displays: two, measurements: [
            .init(pair: pair, referenceY: 101, targetY: 50)
        ])
        preconditionFailure("画面外の指定点を拒否")
    } catch LayoutError.invalidMeasurement { }

    let stacked = [screen("A", 0, 0, main: true), screen("B", 50, 100)]
    do {
        try LayoutPlanner.validatePlannedLayout(displays: stacked,
                                                y: ["A": 0, "B": 50], pairs: [])
        preconditionFailure("予定配置の重なりを拒否")
    } catch LayoutError.impossibleLayout { }
    do {
        _ = try LayoutPlanner.sequence([screen("A", 0, 0, main: true),
                                        screen("B", 50, 50)])
        preconditionFailure("開始時配置の重なりを拒否")
    } catch LayoutError.invalidConfiguration { }

    do {
        _ = try LayoutPlanner.sequence([screen("A", 0, 0, main: true), screen("B", 300, 0)])
        preconditionFailure("到達不能画面を拒否")
    } catch LayoutError.unreachableDisplays { }

    check(LayoutPlanner.matchingConfiguration(two,
          [screen("A", 0, 0, main: true), screen("B", 100, 25)]), "Y変更を許容")
    check(!LayoutPlanner.matchingConfiguration(two,
          [screen("A", 0, 0, main: true), screen("B", 101, 25)]), "X変更を拒否")
    check(!LayoutPlanner.matchingConfiguration([two[0], two[0]], two),
          "重複した保存画面を拒否")

    let fractional = PointMeasurement(pair: pair, referenceY: 40.5, targetY: 40)
    let fractionalY = try LayoutPlanner.plannedY(displays: two, measurements: [fractional])
    let exact = [two[0], screen("B", 100, 1)]
    check(fractionalY == ["A": 0, "B": 1], "端数を整数位置へ丸める")
    check(LayoutPlanner.matchesPlannedY(exact, plannedY: fractionalY), "予定位置の完全一致")
    check(LayoutPlanner.matchesMeasuredPoints([fractional], actual: exact), "丸め誤差を許容")
    let corrected = [two[0], screen("B", 100, 2)]
    check(!LayoutPlanner.matchesPlannedY(corrected, plannedY: fractionalY),
          "OSによる1単位の補正を拒否")

    do {
        _ = try LayoutPlanner.sequence([screen("A", 0, 0, main: true),
                                        screen("B", 100, Int.max)])
        preconditionFailure("極端な保存座標を拒否")
    } catch LayoutError.invalidConfiguration { }

    do {
        try LayoutPlanner.validatePlannedLayout(displays: two,
                                                y: ["A": 0, "B": Int.max], pairs: [pair])
        preconditionFailure("極端な復元予定座標を拒否")
    } catch LayoutError.impossibleLayout { }

    check(LayoutPlanner.sameLayout(two, Array(two.reversed())), "順序が異なる同一配置")
    check(!LayoutPlanner.sameLayout(two,
          [screen("A", 0, 0, main: true), screen("B", 100, 25)]), "Y変更を検出")

    var tracker = ConnectionTracker()
    check(tracker.observe("A"), "初回接続を検出")
    tracker.cancel("A")
    check(!tracker.observe("A"), "取消後の同じ接続を抑止")
    check(!tracker.observe("A", force: true), "強制再判定でも取消済み接続を抑止")
    _ = tracker.observe("single")
    check(tracker.observe("A"), "切断後の同じ2枚の再接続を検出")
    check(tracker.observe("A", force: true), "操作中に消費した接続を再判定")
    let movedOnly = [screen("A", 0, 0, main: true), screen("B", 100, 25)]
    check(!LayoutPlanner.sameLayout(two, movedOnly), "測定中の手動位置変更を検出")
    check(!ConnectionTracker.shouldRecheckAfterInterruption(
        from: "A+B", to: "A+B"), "位置だけの変更では自動復元を始めない")
    check(ConnectionTracker.shouldRecheckAfterInterruption(
        from: "A+B", to: "A+C"), "画面の組み合わせ変更後は復元を再判定")

    let remaining = [screen("A", 0, 0, main: true), screen("B", 100, 25)]
    check(LayoutPlanner.restorableY(original: chain, current: remaining) == ["B": 0],
          "切断後は残った画面だけを復元")
    check(LayoutPlanner.restorableY(original: chain,
          current: [screen("A", 0, 0), screen("B", 100, 25, main: true)]) == nil,
          "主画面変更時は旧座標を適用しない")
    print("LayoutChecks: all checks passed")
} catch {
    fatalError("LayoutChecks: \(error)")
}
