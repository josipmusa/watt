import AppKit
import Combine
import SwiftUI
import WattCore

@MainActor
final class FloatingHUDController: ObservableObject {
    @Published private(set) var isVisible: Bool
    @Published private(set) var isExpanded = false

    private enum Keys {
        static let visible = "hud.isVisible"
        static let x = "hud.origin.x"
        static let y = "hud.origin.y"
        static let hasPosition = "hud.origin.hasSavedPosition"
    }

    private let defaults: UserDefaults
    private let store: UsageStore
    private var panel: HUDPanel?
    private var stateCancellable: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var escapeMonitor: Any?
    private var isProgrammaticallyResizing = false

    init(store: UsageStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        // A fresh install should be discoverable. Once the user hides or shows the
        // HUD explicitly, preserve that choice on subsequent launches.
        isVisible = defaults.object(forKey: Keys.visible) as? Bool ?? true
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.keepOnScreen() }
        }
        stateCancellable = store.$states
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.resizeForContent() }
            }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    }

    func restoreIfNeeded() {
        if isVisible { show() }
    }

    #if DEBUG
    func showForPreview(expanded: Bool) {
        isVisible = true
        show()
        if expanded { setExpanded(true) }
    }
    #endif

    func setVisible(_ visible: Bool) {
        isVisible = visible
        defaults.set(visible, forKey: Keys.visible)
        visible ? show() : hide()
    }

    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        panel?.acceptsKey = expanded
        updateEscapeMonitor(isExpanded: expanded)
        guard let panel else { return }

        let size = expanded ? expandedSize : compactSize
        let frame = frameByChangingSize(panel.frame, to: size)

        isProgrammaticallyResizing = true
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.01 : 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            },
            completionHandler: { [weak self] in
                Task { @MainActor in
                    self?.isProgrammaticallyResizing = false
                    self?.savePosition()
                }
            }
        )
        if expanded {
            panel.becomesKeyOnlyIfNeeded = false
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.resignKey()
            panel.becomesKeyOnlyIfNeeded = true
        }
    }

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.setFrame(initialFrame(for: compactSize), display: true)
        panel.orderFrontRegardless()
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    private var compactSize: NSSize {
        NSSize(width: 330, height: CGFloat(max(1, store.states.count) * 58 + 16))
    }

    private var expandedSize: NSSize {
        let contentHeight: CGFloat
        if store.states.isEmpty {
            contentHeight = 74
        } else {
            contentHeight = store.states.reduce(0) { total, state in
                let limitHeight = state.snapshot.map { CGFloat($0.limits.count) * 48 } ?? 58
                return total + 30 + limitHeight
            }
        }
        return NSSize(width: 330, height: 34 + contentHeight + 44 + 4)
    }

    private func resizeForContent() {
        guard let panel, panel.isVisible else { return }
        let size = isExpanded ? expandedSize : compactSize
        guard panel.frame.size != size else { return }
        panel.setFrame(frameByChangingSize(panel.frame, to: size), display: true, animate: true)
        savePosition()
    }

    private func hide() {
        savePosition()
        isExpanded = false
        updateEscapeMonitor(isExpanded: false)
        panel?.acceptsKey = false
        panel?.orderOut(nil)
    }

    private func makePanel() -> HUDPanel {
        let panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: compactSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow
        panel.becomesKeyOnlyIfNeeded = true
        panel.onEscape = { [weak self] in self?.setExpanded(false) }
        panel.onMove = { [weak self] in
            guard self?.isProgrammaticallyResizing == false else { return }
            self?.savePosition()
        }
        panel.contentView = NSHostingView(rootView: FloatingHUDView(store: store, controller: self))
        return panel
    }

    private func updateEscapeMonitor(isExpanded: Bool) {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        guard isExpanded else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor in self?.setExpanded(false) }
            return nil
        }
    }

    private func initialFrame(for size: NSSize) -> NSRect {
        if defaults.bool(forKey: Keys.hasPosition) {
            let frame = NSRect(
                x: defaults.double(forKey: Keys.x),
                y: defaults.double(forKey: Keys.y),
                width: size.width,
                height: size.height
            )
            return constrained(frame)
        }
        let pointer = NSEvent.mouseLocation
        let preferredScreen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
        let visible = preferredScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(
            x: visible.maxX - size.width - 22,
            y: visible.maxY - size.height - 22,
            width: size.width,
            height: size.height
        )
    }

    private func constrained(_ frame: NSRect) -> NSRect {
        let target = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main
        guard let visible = target?.visibleFrame else { return frame }
        let margin: CGFloat = 8
        var result = frame
        result.origin.x = min(max(result.origin.x, visible.minX + margin), visible.maxX - result.width - margin)
        result.origin.y = min(max(result.origin.y, visible.minY + margin), visible.maxY - result.height - margin)
        return result
    }

    /// Resizing around the center drifts when the larger frame is constrained by
    /// a screen edge. Anchoring to the nearest horizontal and vertical edges makes
    /// expansion and collapse perfectly reversible, including in screen corners.
    private func frameByChangingSize(_ frame: NSRect, to size: NSSize) -> NSRect {
        let target = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main
        guard let visible = target?.visibleFrame else {
            return NSRect(origin: frame.origin, size: size)
        }

        let anchorsRight = frame.midX >= visible.midX
        let anchorsTop = frame.midY >= visible.midY
        let origin = NSPoint(
            x: anchorsRight ? frame.maxX - size.width : frame.minX,
            y: anchorsTop ? frame.maxY - size.height : frame.minY
        )
        return constrained(NSRect(origin: origin, size: size))
    }

    private func keepOnScreen() {
        guard let panel, panel.isVisible else { return }
        panel.setFrame(constrained(panel.frame), display: true, animate: true)
        savePosition()
    }

    private func savePosition() {
        guard let panel else { return }
        let compactFrame = isExpanded
            ? frameByChangingSize(panel.frame, to: compactSize)
            : panel.frame
        let origin = compactFrame.origin
        defaults.set(origin.x, forKey: Keys.x)
        defaults.set(origin.y, forKey: Keys.y)
        defaults.set(true, forKey: Keys.hasPosition)
    }
}

private final class HUDPanel: NSPanel {
    var acceptsKey = false
    var onEscape: (() -> Void)?
    var onMove: (() -> Void)?

    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(point)
        onMove?()
    }
}
