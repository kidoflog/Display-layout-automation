import AppKit
import CoreGraphics
import DisplayHeightCore
import ServiceManagement

nonisolated(unsafe) private var activeController: Controller?

private func reconfigurationCallback(_ display: CGDirectDisplayID,
                                     _ flags: CGDisplayChangeSummaryFlags,
                                     _ userInfo: UnsafeMutableRawPointer?) {
    if !flags.contains(.beginConfigurationFlag) {
        DispatchQueue.main.async { activeController?.configurationChanged() }
    }
}

@MainActor private final class ControlWindow: NSWindow {
    var escapeAction: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { escapeAction?() } else { super.keyDown(with: event) }
    }
}

@MainActor final class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private enum State {
        case idle
        case measuring([ConnectedDisplay], [MeasurementPair], [PointMeasurement], Double?)
        case applying([ConnectedDisplay], [PointMeasurement], [String: Int], Bool)
        case confirming([ConnectedDisplay], [String: Int], Bool, TimeInterval)
    }

    private enum RestoreOutcome {
        case complete
        case partial(String)
        case failed(String)

        var message: String {
            switch self {
            case .complete: "元の配置に戻しました。"
            case .partial(let reason): "接続中の画面で復元可能な位置を戻しました。\(reason)"
            case .failed(let reason): "元の配置に戻せませんでした。\(reason)"
            }
        }
    }

    private var state: State = .idle
    private var window: ControlWindow!
    private var status: NSTextField!
    private var action: NSButton!
    private var cancelButton: NSButton!
    private var launchCheckbox: NSButton!
    private var statusItem: NSStatusItem!
    private var overlay: OverlaySet?
    private var timer: Timer?
    private var reconfigurationTimer: Timer?
    private var reconnectionRetries = 0
    private var connectionTracker = ConnectionTracker()
    private var store: ProfileStore?
    private var confirmationSummary = ""
    private var terminating = false
    private var previewVerification = PreviewVerification()

    func applicationDidFinishLaunching(_ notification: Notification) {
        activeController = self
        store = try? ProfileStore()
        createWindow()
        createStatusItem()
        if !LaunchContext.isLoginLaunch(NSAppleEventManager.shared().currentAppleEvent) {
            showControlWindow()
        }
        CGDisplayRegisterReconfigurationCallback(reconfigurationCallback, nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep),
            name: NSWorkspace.willSleepNotification, object: nil)
        scheduleReconnectionCheck(force: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminating = true
        cancelSession(message: nil)
        return .terminateNow
    }

    // The control window is hidden during measurement. Closing the last
    // overlay must not terminate the app before the preview transaction runs.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if case .idle = state {} else {
            cancelSession(message: "ウィンドウを閉じたため、変更を取り消しました。")
        }
        window.orderOut(nil)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showControlWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        CGDisplayRemoveReconfigurationCallback(reconfigurationCallback, nil)
    }

    @objc private func willSleep() { cancelSession(message: "スリープにより未確定の変更を取り消しました。") }

    private func createWindow() {
        window = ControlWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 240),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = "ディスプレイ高さ調整"
        window.escapeAction = { [weak self] in self?.cancelSession(message: "変更を取り消しました。") }
        status = NSTextField(wrappingLabelWithString: "接続された画面を確認しています。")
        status.font = .systemFont(ofSize: 14)
        action = NSButton(title: "調整を開始", target: self, action: #selector(primaryAction))
        cancelButton = NSButton(title: "取り消す", target: self, action: #selector(cancelAction))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.isHidden = true
        launchCheckbox = NSButton(checkboxWithTitle: "ログイン時に起動", target: self,
                                  action: #selector(toggleLoginItem))
        launchCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let stack = NSStackView(views: [status, action, cancelButton, launchCheckbox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView()
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor)
        ])
        window.center()
        status.stringValue = "調整を始めると、各画面で対応する高さを順に指定します。"
    }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "↕︎"
        let menu = NSMenu()
        let open = NSMenuItem(title: "調整画面を開く", action: #selector(openControlWindow),
                              keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "DisplayHeightを終了", action: #selector(quitApplication),
                              keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func showControlWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openControlWindow() { showControlWindow() }
    @objc private func quitApplication() { NSApp.terminate(nil) }

    @objc private func toggleLoginItem() {
        do {
            if launchCheckbox.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            launchCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
            show("\(error.localizedDescription)\nアプリの置き場所を確認してください。ログイン時起動にはApplicationsフォルダに置いたアプリを使ってください。")
        }
    }

    @objc private func primaryAction() {
        switch state {
        case .idle: startManual()
        case .confirming: confirm()
        default: break
        }
    }

    @objc private func cancelAction() { cancelSession(message: "変更を取り消しました。") }

    private func startManual() {
        do {
            guard store != nil else {
                throw DisplaySystemError.unavailable("アプリの保存領域を開けません。")
            }
            let displays = try DisplaySystem.snapshot()
            let pairs = try LayoutPlanner.sequence(displays.map(\.layout))
            state = .measuring(displays, pairs, [], nil)
            action.isEnabled = false
            cancelButton.isHidden = false
            window.orderOut(nil)
            overlay = OverlaySet(displays: displays, click: { [weak self] id, fraction in
                self?.receiveClick(identity: id, fraction: fraction)
            }, cancel: { [weak self] in self?.cancelSession(message: "測定を中止しました。") })
            overlay?.update(pair: pairs[0], expectingReference: true, index: 1, total: pairs.count)
        } catch { show(error.localizedDescription) }
    }

    private func receiveClick(identity: String, fraction: Double) {
        guard case let .measuring(displays, pairs, measurements, referenceY) = state else { return }
        let pair = pairs[measurements.count]
        let expected = referenceY == nil ? pair.reference : pair.target
        guard identity == expected, let clicked = displays.first(where: { $0.layout.identity == identity }) else {
            NSSound.beep()
            return
        }
        let localY = fraction * Double(clicked.layout.height)
        if referenceY == nil {
            overlay?.mark(identity: identity, fraction: fraction, label: "基準点")
            state = .measuring(displays, pairs, measurements, localY)
            overlay?.update(pair: pair, expectingReference: false,
                            index: measurements.count + 1, total: pairs.count)
            return
        }
        overlay?.mark(identity: identity, fraction: fraction, label: "対象点")
        let next = measurements + [PointMeasurement(pair: pair, referenceY: referenceY!, targetY: localY)]
        if next.count < pairs.count {
            state = .measuring(displays, pairs, next, nil)
            overlay?.clearMarkers()
            overlay?.update(pair: pairs[next.count], expectingReference: true,
                            index: next.count + 1, total: pairs.count)
        } else {
            overlay?.close()
            overlay = nil
            do {
                let proposed = try LayoutPlanner.plannedY(displays: displays.map(\.layout), measurements: next)
                guard displays.contains(where: { proposed[$0.layout.identity] != $0.layout.y }) else {
                    state = .idle
                    resetControls()
                    show("今回の指定点から計算した移動量は0です。高さを変えるには、対応する2点を異なる画面内Y位置で指定してください。")
                    return
                }
                applyPreview(displays: displays, measurements: next, proposed: proposed, automatic: false)
            } catch {
                state = .idle
                resetControls()
                show(error.localizedDescription)
            }
        }
    }

    private func applyPreview(displays: [ConnectedDisplay], measurements: [PointMeasurement],
                              proposed: [String: Int], automatic: Bool) {
        do {
            let current = try DisplaySystem.snapshot()
            guard LayoutPlanner.sameLayout(displays.map(\.layout), current.map(\.layout)) else {
                throw DisplaySystemError.unavailable("測定後に画面構成または配置が変わりました。もう一度測定してください。")
            }
            state = .applying(current, measurements, proposed, automatic)
            let token = previewVerification.begin()
            try DisplaySystem.apply(proposed, to: current, permanent: false)
            schedulePreviewVerification(token: token, attempt: 1)
        } catch {
            previewVerification.invalidate()
            let restoration: String
            if case .applying(let before, _, _, _) = state {
                restoration = rollback(displays: before).message
            } else {
                restoration = "配置は変更していません。"
            }
            state = .idle
            resetControls()
            show("仮適用に失敗しました。\(restoration)\n\(error.localizedDescription)")
        }
    }

    private func schedulePreviewVerification(token: UUID, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + PreviewVerification.interval) { [weak self] in
            self?.verifyPreview(token: token, attempt: attempt)
        }
    }

    private func verifyPreview(token: UUID, attempt: Int) {
        guard previewVerification.accepts(token),
              case let .applying(before, measurements, proposed, automatic) = state else { return }
        let reading: PreviewVerification.Reading
        var actual: [Display] = []
        var reason = ""
        do {
            actual = try DisplaySystem.snapshot().map(\.layout)
            if !LayoutPlanner.matchingConfiguration(before.map(\.layout), actual) {
                reading = .configurationMismatch
                reason = "画面構成、主画面、X座標または表示設定が変わりました。"
            } else if !LayoutPlanner.matchesPlannedY(actual, plannedY: proposed) {
                reading = .positionMismatch
                reason = "macOSによる位置補正で、指定位置を実現できませんでした。"
            } else if !LayoutPlanner.matchesMeasuredPoints(measurements, actual: actual) {
                reading = .pointMismatch
                reason = "指定した点の高さが一致しませんでした。"
            } else {
                reading = .matched
            }
        } catch DisplaySystemError.transient(let message) {
            reading = .transient
            reason = message
        } catch {
            reading = .unavailable
            reason = error.localizedDescription
        }
        switch PreviewVerification.decide(reading, attempt: attempt) {
        case .retry:
            schedulePreviewVerification(token: token, attempt: attempt + 1)
        case .confirm:
            previewVerification.invalidate()
            showConfirmation(before: before, actual: actual, proposed: proposed, automatic: automatic)
        case .cancel:
            previewVerification.invalidate()
            let restoration = rollback(displays: before)
            state = .idle
            resetControls()
            show("仮適用を取り消しました。\(restoration.message)\n\(reason)")
        }
    }

    private func showConfirmation(before: [ConnectedDisplay], actual: [Display],
                                  proposed: [String: Int],
                                  automatic: Bool) {
        let original = Dictionary(uniqueKeysWithValues: before.map { ($0.layout.identity, $0.layout) })
        let ordered = actual.sorted { ($0.x, $0.identity) < ($1.x, $1.identity) }
        let changes = ordered.enumerated().compactMap { index, display -> String? in
            guard let prior = original[display.identity], display.y != prior.y else { return nil }
            let delta = display.y - prior.y
            return "画面\(index + 1)を\(delta < 0 ? "上" : "下")へ\(abs(delta))単位"
        }
        confirmationSummary = changes.isEmpty ? "読み取った位置に変化はありません" : changes.joined(separator: "、")
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        state = .confirming(before, proposed, automatic, deadline)
        action.title = "確定して保存"
        action.isEnabled = true
        cancelButton.isHidden = false
        if let main = before.first(where: { $0.layout.isMain })?.screen {
            window.setFrameOrigin(NSPoint(x: main.visibleFrame.midX - window.frame.width / 2,
                                          y: main.visibleFrame.midY - window.frame.height / 2))
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        timer?.invalidate()
        let confirmationTimer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = confirmationTimer
        RunLoop.main.add(confirmationTimer, forMode: .common)
        tick()
    }

    private func tick() {
        guard case let .confirming(_, _, automatic, deadline) = state else { return }
        let remaining = max(0, Int(ceil(deadline - ProcessInfo.processInfo.systemUptime)))
        let introduction = automatic ? "保存した配置を仮適用しました。" : "全画面の配置を仮適用しました。"
        status.stringValue = "\(introduction)\(confirmationSummary)。確定しない場合、残り\(remaining)秒で元に戻ります。"
        if ProcessInfo.processInfo.systemUptime >= deadline {
            cancelSession(message: "10秒以内に確定されなかったため、元の配置に戻しました。")
        }
    }

    private func confirm() {
        guard case let .confirming(before, proposed, _, deadline) = state,
              ProcessInfo.processInfo.systemUptime < deadline else { return }
        timer?.invalidate()
        var permanentAttempted = false
        var savedConfigurationVerified = false
        do {
            let now = try DisplaySystem.snapshot()
            guard LayoutPlanner.matchingConfiguration(before.map(\.layout), now.map(\.layout)),
                  LayoutPlanner.matchesPlannedY(now.map(\.layout), plannedY: proposed) else {
                throw DisplaySystemError.unavailable("確認中に画面構成または配置が変わりました。")
            }
            permanentAttempted = true
            try DisplaySystem.apply(proposed, to: now, permanent: true)
            let saved = try DisplaySystem.snapshot().map(\.layout)
            guard LayoutPlanner.matchingConfiguration(before.map(\.layout), saved),
                  LayoutPlanner.matchesPlannedY(saved, plannedY: proposed) else {
                throw DisplaySystemError.unavailable("永続保存後の実際の配置が予定位置と一致しません。")
            }
            savedConfigurationVerified = true
            guard let store else { throw DisplaySystemError.unavailable("保存先を開けません。") }
            try store.save(SavedProfile(displays: saved, savedAt: Date()))
            state = .idle
            resetControls()
            show("配置を確定して保存しました。")
        } catch {
            let restoration = savedConfigurationVerified ? nil
                : rollback(displays: before, permanent: permanentAttempted)
            state = .idle
            resetControls()
            let explanation = savedConfigurationVerified
                ? "macOSには配置を保存しましたが、アプリ側の保存に失敗しました。自動復元は更新されません。"
                : "確定に失敗しました。\(restoration?.message ?? "現在の配置を確認してください。")"
            show("\(explanation)\n\(error.localizedDescription)")
        }
    }

    private func cancelSession(message: String?) {
        previewVerification.invalidate()
        if case .idle = state { return }
        timer?.invalidate()
        switch state {
        case .confirming(let before, _, _, _), .applying(let before, _, _, _):
            let restoration = rollback(displays: before)
            if let current = try? DisplaySystem.activeDisplays(),
               topology(current.map(\.layout)) == topology(before.map(\.layout)) {
                connectionTracker.cancel(topology(before.map(\.layout)))
            }
            state = .idle
            resetControls()
            if !terminating {
                let prefix = message.map { "\($0) " } ?? ""
                show("\(prefix)\(restoration.message)")
            }
            return
        case .measuring: overlay?.close(); overlay = nil
        case .idle: break
        }
        state = .idle
        resetControls()
        if let message { show(message) }
    }

    @discardableResult private func rollback(displays: [ConnectedDisplay],
                                             permanent: Bool = false) -> RestoreOutcome {
        let original = displays.map(\.layout)
        do {
            let current = try DisplaySystem.activeDisplays()
            let currentLayouts = current.map(\.layout)
            guard let origins = LayoutPlanner.restorableY(original: original, current: currentLayouts) else {
                return .failed("主画面が変わったため、安全に元の座標へ戻せません。システム設定で確認してください。")
            }
            let recoverable = current.filter { origins[$0.layout.identity] != nil }
            let fullConfiguration = LayoutPlanner.matchingConfiguration(original, currentLayouts)
            var errors: [String] = []
            if fullConfiguration {
                try DisplaySystem.apply(origins, to: recoverable, permanent: permanent)
            } else {
                // A disappearing display must not cancel restoration of the others.
                for item in recoverable {
                    do {
                        try DisplaySystem.apply(origins, to: [item], permanent: false)
                    } catch {
                        errors.append(error.localizedDescription)
                    }
                }
            }
            let after = try DisplaySystem.activeDisplays().map(\.layout)
            guard LayoutPlanner.matchingConfiguration(currentLayouts, after) else {
                return .failed("復元中に画面構成が変わりました。システム設定で確認してください。")
            }
            let afterByID = Dictionary(uniqueKeysWithValues: after.map { ($0.identity, $0) })
            let restoredAllTargets = recoverable.allSatisfy { item in
                guard let actual = afterByID[item.layout.identity], let expected = origins[item.layout.identity] else {
                    return false
                }
                return actual.y == expected
            }
            guard errors.isEmpty, restoredAllTargets else {
                return .failed("接続中の画面の一部を復元できませんでした。システム設定で確認してください。")
            }
            let originalByID = Dictionary(uniqueKeysWithValues: original.map { ($0.identity, $0) })
            let complete = LayoutPlanner.matchingConfiguration(original, after) &&
                after.allSatisfy { item in
                    guard let expected = originalByID[item.identity] else { return false }
                    return item.y == expected.y
                }
            if complete { return .complete }
            return .partial("元の画面構成とは異なります。システム設定で確認してください。")
        } catch {
            return .failed("システム設定で確認してください。\n\(error.localizedDescription)")
        }
    }

    private func resetControls() {
        action.title = "調整を開始"
        action.isEnabled = true
        cancelButton.isHidden = true
        if !terminating { window.makeKeyAndOrderFront(nil) }
    }

    private func show(_ message: String) {
        status.stringValue = message
        if !terminating { window.makeKeyAndOrderFront(nil) }
    }

    func configurationChanged() {
        reconnectionRetries = 0
        scheduleReconnectionCheck(force: false)
    }

    private func scheduleReconnectionCheck(force: Bool) {
        reconfigurationTimer?.invalidate()
        reconfigurationTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.checkReconnection(force: force) }
        }
    }

    private func topology(_ displays: [Display]) -> String {
        ProfileStore.key(for: displays)
    }

    private func checkReconnection(force: Bool) {
        let configuration: [Display]
        do {
            configuration = try DisplaySystem.activeDisplays().map(\.layout)
        } catch {
            _ = connectionTracker.observe("<unavailable>")
            switch state {
            case .measuring, .applying, .confirming:
                cancelSession(message: "画面情報を取得できなくなったため、操作を中断しました。")
            case .idle: break
            }
            return
        }
        let key = topology(configuration)
        let shouldRestore = connectionTracker.observe(key, force: force)
        if case .measuring(let before, _, _, _) = state,
           !LayoutPlanner.sameLayout(before.map(\.layout), configuration) {
            let recheck = ConnectionTracker.shouldRecheckAfterInterruption(
                from: topology(before.map(\.layout)), to: key)
            cancelSession(message: "画面構成が変わったため、測定を中止しました。")
            if recheck { scheduleReconnectionCheck(force: true) }
            return
        }
        if case .confirming(let before, _, _, _) = state,
           !LayoutPlanner.matchingConfiguration(before.map(\.layout), configuration) {
            let recheck = ConnectionTracker.shouldRecheckAfterInterruption(
                from: topology(before.map(\.layout)), to: key)
            cancelSession(message: "画面構成が変わったため、未確定の変更を取り消しました。")
            if recheck { scheduleReconnectionCheck(force: true) }
            return
        }
        if case .applying(let before, _, _, _) = state,
           !LayoutPlanner.matchingConfiguration(before.map(\.layout), configuration) {
            let recheck = ConnectionTracker.shouldRecheckAfterInterruption(
                from: topology(before.map(\.layout)), to: key)
            cancelSession(message: "画面構成が変わったため、仮適用を中断しました。")
            if recheck { scheduleReconnectionCheck(force: true) }
            return
        }
        guard case .idle = state else { return }
        guard configuration.count >= 2, shouldRestore else { return }
        guard let profile = try? store?.load()[key] else { return }
        guard LayoutPlanner.matchingConfiguration(profile.displays, configuration) else {
            show("画面の左右の位置が保存時と異なるため、自動復元を見送りました。手動で調整してください。")
            return
        }
        let current: [ConnectedDisplay]
        do {
            current = try DisplaySystem.snapshot()
        } catch DisplaySystemError.transient {
            if reconnectionRetries < 3 {
                reconnectionRetries += 1
                scheduleReconnectionCheck(force: true)
            } else {
                show("画面構成が安定せず、自動復元を見送りました。手動調整してください。")
            }
            return
        } catch {
            reconnectionRetries = 0
            show("自動復元を見送りました。\(error.localizedDescription)")
            return
        }
        guard LayoutPlanner.sameLayout(configuration, current.map(\.layout)) else {
            if reconnectionRetries < 3 {
                reconnectionRetries += 1
                scheduleReconnectionCheck(force: true)
            } else {
                show("画面構成が安定せず、自動復元を見送りました。手動調整してください。")
            }
            return
        }
        reconnectionRetries = 0
        let proposed = Dictionary(uniqueKeysWithValues: profile.displays.map { ($0.identity, $0.y) })
        guard current.contains(where: { $0.layout.y != proposed[$0.layout.identity] }) else { return }
        do {
            let pairs = try LayoutPlanner.sequence(profile.displays)
            try LayoutPlanner.validatePlannedLayout(displays: profile.displays, y: proposed, pairs: pairs)
            applyPreview(displays: current, measurements: [], proposed: proposed, automatic: true)
        } catch { show("保存配置を安全に適用できません。手動調整してください。\n\(error.localizedDescription)") }
    }
}

let application = NSApplication.shared
let controller = Controller()
application.delegate = controller
application.setActivationPolicy(.regular)
application.run()
