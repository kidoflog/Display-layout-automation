import AppKit
import DisplayHeightCore

@MainActor final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    var cancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancel?() } else { super.keyDown(with: event) }
    }
}

@MainActor final class OverlayView: NSView {
    enum SelectionMode { case inactive, reference, target }

    var instruction = "" { didSet { needsDisplay = true } }
    var isExpected = false { didSet { needsDisplay = true } }
    var markers: [(Double, String)] = [] { didSet { needsDisplay = true } }
    var selectionMode: SelectionMode = .inactive {
        didSet { candidateFraction = nil; isDraggingSelection = false; needsDisplay = true }
    }
    var click: ((Double) -> Void)?
    var cancel: (() -> Void)?
    private var candidateFraction: Double? { didSet { needsDisplay = true } }
    private var isDraggingSelection = false

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        switch selectionMode {
        case .inactive:
            NSSound.beep()
        case .reference, .target:
            isDraggingSelection = true
            candidateFraction = fraction(for: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard selectionMode != .inactive, isDraggingSelection else { return }
        candidateFraction = fraction(for: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard selectionMode != .inactive, isDraggingSelection else { return }
        isDraggingSelection = false
        let point = convert(event.locationInWindow, from: nil)
        let selected = bounds.contains(point) ? fraction(for: event) : nil
        candidateFraction = nil
        if let selected { click?(selected) }
    }

    private func fraction(for event: NSEvent) -> Double {
        let point = convert(event.locationInWindow, from: nil)
        return Double(min(max(0, (bounds.height - point.y) / bounds.height), 1))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancel?() } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(isExpected ? 0.12 : 0.28).setFill()
        bounds.fill()

        if isExpected {
            NSColor.systemYellow.setStroke()
            let outline = NSBezierPath(rect: bounds.insetBy(dx: 4, dy: 4))
            outline.lineWidth = 8
            outline.stroke()
        }

        let text = instruction as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 22), .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.75)
        ]
        let textOptions: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let textWidth = max(1, bounds.width - 56)
        let textHeight = ceil(text.boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: textOptions, attributes: attributes).height)
        text.draw(with: NSRect(x: 28, y: bounds.height - 28 - textHeight,
                               width: textWidth, height: textHeight),
                  options: textOptions, attributes: attributes)
        for (fraction, label) in markers {
            let y = bounds.height * (1 - fraction)
            NSColor.systemYellow.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 3
            path.move(to: NSPoint(x: 0, y: y))
            path.line(to: NSPoint(x: bounds.width, y: y))
            path.stroke()
            (label as NSString).draw(at: NSPoint(x: 28, y: y + 8), withAttributes: attributes)
        }
        if let candidateFraction {
            let y = bounds.height * (1 - candidateFraction)
            NSColor.systemOrange.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 4
            path.move(to: NSPoint(x: 0, y: y))
            path.line(to: NSPoint(x: bounds.width, y: y))
            path.stroke()
            ("離すと確定" as NSString).draw(at: NSPoint(x: 28, y: y + 8), withAttributes: attributes)
        }
    }
}

@MainActor final class OverlaySet {
    private(set) var windows: [String: OverlayWindow] = [:]
    private(set) var views: [String: OverlayView] = [:]
    private let displayNumber: [String: Int]

    init(displays: [ConnectedDisplay], click: @escaping (String, Double) -> Void,
         cancel: @escaping () -> Void) {
        displayNumber = Dictionary(uniqueKeysWithValues: displays
            .sorted { ($0.layout.x, $0.layout.identity) < ($1.layout.x, $1.layout.identity) }
            .enumerated().map { ($0.element.layout.identity, $0.offset + 1) })
        for display in displays {
            let window = OverlayWindow(contentRect: display.screen.frame, styleMask: .borderless,
                                       backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = OverlayView(frame: NSRect(origin: .zero, size: display.screen.frame.size))
            // Closing an overlay while a mouse/key event is still running can
            // release the receiving NSView before AppKit finishes the event.
            view.click = { fraction in
                DispatchQueue.main.async { click(display.layout.identity, fraction) }
            }
            view.cancel = {
                DispatchQueue.main.async { cancel() }
            }
            window.contentView = view
            window.cancel = { DispatchQueue.main.async { cancel() } }
            window.makeFirstResponder(view)
            window.makeKeyAndOrderFront(nil)
            windows[display.layout.identity] = window
            views[display.layout.identity] = view
        }
    }

    func update(pair: MeasurementPair, expectingReference: Bool, index: Int, total: Int) {
        let expected = expectingReference ? pair.reference : pair.target
        let pointNumber = 2 * index - (expectingReference ? 1 : 0)
        let expectedNumber = displayNumber[expected, default: 0]
        for (id, view) in views {
            let number = displayNumber[id, default: 0]
            view.isExpected = id == expected
            view.selectionMode = id == expected ? (expectingReference ? .reference : .target) : .inactive
            view.instruction = id == expected
                ? "画面\(number)｜\(pointNumber)/\(total * 2)点目・\(expectingReference ? "基準点" : "対象点")：押して線を表示 → ドラッグで調整 → 離して確定（Escで中止）"
                : "画面\(number)｜次は画面\(expectedNumber)で線を調整（\(pointNumber)/\(total * 2)点目）"
        }
        windows[expected]?.makeKeyAndOrderFront(nil)
    }

    func mark(identity: String, fraction: Double, label: String) {
        views[identity]?.markers.append((fraction, label))
    }

    func clearMarkers() {
        for view in views.values { view.markers = [] }
    }

    func close() {
        for window in windows.values { window.close() }
        windows.removeAll()
        views.removeAll()
    }
}
