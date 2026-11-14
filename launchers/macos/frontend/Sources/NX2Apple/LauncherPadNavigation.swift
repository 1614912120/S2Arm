// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import Combine
import SwiftUI
import LauncherPadBridge
import NXLauncher

struct LauncherPadTarget {
    let id: String
    let frame: CGRect
    let role: String
    let element: Any
}

enum LauncherPadSpatial {
    /// Accessibility frames use screen coordinates (up is positive Y).
    static func next(from current: CGRect, targets: [LauncherPadTarget], action: LauncherPadAction) -> LauncherPadTarget? {
        let horizontal = action == .left || action == .right
        let sign: CGFloat = action == .left || action == .down ? -1 : 1
        let candidates = targets.compactMap { target -> (LauncherPadTarget, CGFloat, Bool)? in
            let along = horizontal ? (target.frame.midX - current.midX) * sign : (target.frame.midY - current.midY) * sign
            guard along > 4 else { return nil }
            let across = horizontal ? abs(target.frame.midY - current.midY) : abs(target.frame.midX - current.midX)
            let overlap = horizontal ? target.frame.minY < current.maxY && target.frame.maxY > current.minY
                : target.frame.minX < current.maxX && target.frame.maxX > current.minX
            return (target, along + across * 2, overlap)
        }
        let aligned = candidates.filter { $0.2 }
        let pool = horizontal || !aligned.isEmpty ? aligned : candidates
        return pool.min { $0.1 < $1.1 }?.0
    }
}

/// One focus owner for the whole app: SwiftUI views, titlebar hosting views,
/// sheets, popovers, native file panels and menus. Only this process's own public
/// accessibility objects are inspected; no Accessibility permission or global events.
@MainActor final class LauncherPadNavigation: ObservableObject, PadControlRegistry {
    @Published private(set) var focusedID: String?
    @Published private(set) var visible = false
    let source = LauncherPadSource()
    var language = "zh-Hans"
    var text: (String) -> String = { $0 }
    var onAction: ((LauncherPadAction) -> Bool)?
    var defaultFocus: () -> String? = { nil }
    var context: () -> String = { "home" }
    private(set) weak var window: NSWindow?
    private var scope = ""
    private var memories: [String: String] = [:]
    private var overlays: [Int: LauncherPadRing] = [:]
    private var monitors: [Any] = []
    private var notifications: [NSObjectProtocol] = []
    private var trackingMenu = false
    var keyboard: LauncherPadKeyboard?
    private var controls: [UUID: PadControl] = [:]

    func register(_ control: PadControl) {
        controls[control.token] = control
        if visible, focusedID == control.id {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.visible, self.focusedID == control.id, let window = control.view.window else { return }
                self.draw(self.targets(in: window).first { $0.id == control.id }, in: window)
            }
        }
    }
    func removeControl(_ token: UUID) { controls[token] = nil }
    func isFullyVisible(_ id: String) -> Bool {
        guard let control = controls.values.first(where: { $0.id == id && $0.view.window === window }) else { return false }
        return control.view.visibleRect.contains(control.view.bounds.insetBy(dx: 1, dy: 1))
    }
    func controlTargets(in window: NSWindow) -> [LauncherPadTarget] {
        let registered = controls.values.filter { $0.enabled && $0.view.window === window && !$0.view.isHiddenOrHasHiddenAncestor && !$0.view.visibleRect.isEmpty }
        let modal = registered.filter { $0.scope == "dropdown" }
        return (modal.isEmpty ? Array(registered) : modal).compactMap { control in
            let frame = window.convertToScreen(control.view.convert(control.view.bounds, to: nil))
            guard frame.width > 2, frame.height > 2, window.frame.intersects(frame) else { return nil }
            return LauncherPadTarget(id: control.id, frame: frame, role: "AXButton", element: control.view)
        }.sorted(by: Self.order)
    }
    private static func order(_ a: LauncherPadTarget, _ b: LauncherPadTarget) -> Bool {
        let ay = Int(a.frame.midY / 24), by = Int(b.frame.midY / 24)
        if ay != by { return ay > by }
        if a.frame.midX != b.frame.midX { return a.frame.midX < b.frame.midX }
        return a.id < b.id
    }

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        source.receive = { [weak self] action in self?.handle(action) }
        source.start()
        if monitors.isEmpty {
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
                self?.hide(); return event
            }) { monitors.append(monitor) }
            let center = NotificationCenter.default
            notifications.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.trackingMenu = true; self?.clearRings() }
            })
            notifications.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.trackingMenu = false }
            })
            notifications.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.clearRings() }
            })
            notifications.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let closed = note.object as? NSWindow else { return }
                    if closed === self.window { self.detach() }
                    else {
                        self.overlays.removeValue(forKey: closed.windowNumber)?.removeFromSuperview()
                        self.memories = self.memories.filter { !$0.key.hasPrefix("\(closed.windowNumber):") }
                    }
                }
            })
        }
    }
    func detach() {
        source.stop(); clearRings(); keyboard?.close(apply: false); keyboard = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }; monitors.removeAll()
        for observer in notifications { NotificationCenter.default.removeObserver(observer) }; notifications.removeAll()
        for overlay in overlays.values { overlay.removeFromSuperview() }; overlays.removeAll()
        onAction = nil; defaultFocus = { nil }; context = { "home" }; text = { $0 }; source.relayPath = { nil }; source.relayAllowed = { true }
        controls.removeAll(); window = nil
    }
    func hide() { visible = false; clearRings() }
    func releaseRelay() { source.releaseRelay() }

    var activeWindow: NSWindow? {
        guard let window else { return nil }
        if let keyboard, keyboard.panel.isVisible { return keyboard.panel }
        if let modal = NSApp.modalWindow { return modal }
        if let sheet = window.attachedSheet { return sheet.attachedSheet ?? sheet }
        if let key = NSApp.keyWindow, key !== window, key.isVisible { return key }
        if let child = window.childWindows?.last(where: { $0.isVisible }) { return child }
        if let popup = NSApp.orderedWindows.first(where: { candidate in
            candidate !== window && candidate.isVisible && !candidate.canBecomeMain && controls.values.contains { $0.view.window === candidate }
        }) { return popup }
        return window
    }
    var inMainContent: Bool { activeWindow === window && !trackingMenu && !hasDropdown }
    private var hasDropdown: Bool {
        guard let window = activeWindow else { return false }
        if controls.values.contains(where: { $0.scope == "dropdown" && $0.view.window === window && !$0.view.visibleRect.isEmpty }) { return true }
        return Self.elements(window).contains { S2ALauncherAX.identifier($0) == "launcher.dropdown" }
    }

    static func elements(_ root: Any) -> [Any] {
        var result: [Any] = [], seen = Set<ObjectIdentifier>()
        func visit(_ item: Any) {
            let object = item as AnyObject
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(item)
            for child in S2ALauncherAX.children(item) ?? [] { visit(child) }
        }
        visit(root)
        return result
    }
    func targets(in window: NSWindow) -> [LauncherPadTarget] {
        let registered = controlTargets(in: window)
        if controls.values.contains(where: { $0.scope == "dropdown" && $0.view.window === window && !$0.view.visibleRect.isEmpty }) { return registered }
        let all = Self.elements(window)
        let dropdown = all.first { S2ALauncherAX.identifier($0) == "launcher.dropdown" }
        let elements = dropdown.map(Self.elements) ?? all
        let roles: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXTextField", "AXTextArea", "AXComboBox", "AXSlider", "AXIncrementor", "AXDisclosureTriangle", "AXLink", "AXRow"]
        let native: [LauncherPadTarget] = elements.enumerated().compactMap { index, element in
            let role = S2ALauncherAX.role(element) ?? ""
            guard roles.contains(role), S2ALauncherAX.enabled(element) else { return nil }
            let frame = S2ALauncherAX.frame(element)
            guard frame.width > 2, frame.height > 2, window.frame.intersects(frame) else { return nil }
            if role == "AXButton", frame.width <= 18, frame.height <= 18 { return nil }
            if registered.contains(where: { $0.frame.insetBy(dx: -2, dy: -2).contains(CGPoint(x: frame.midX, y: frame.midY)) }) { return nil }
            let explicit = S2ALauncherAX.identifier(element) ?? ""
            if ["AXCloseButton", "AXMinimizeButton", "AXZoomButton"].contains(explicit) { return nil }
            let id = explicit.isEmpty ? "ax.\(role).\(S2ALauncherAX.label(element) ?? "").\(index)" : explicit
            return LauncherPadTarget(id: id, frame: frame, role: role, element: element)
        }
        return (registered + native).sorted(by: Self.order)
    }
    func focus(_ id: String) {
        visible = true
        focusedID = id
        guard let window = activeWindow else { return }
        memories[scope] = id
        draw(targets(in: window).first { $0.id == id }, in: window)
    }
    private func prepare(in window: NSWindow) -> [LauncherPadTarget] {
        let nextScope = "\(window.windowNumber):\(context()):\(hasDropdown ? "dropdown" : "page")"
        let targets = targets(in: window)
        if nextScope != scope {
            if let focusedID { memories[scope] = focusedID }
            scope = nextScope
            if !targets.contains(where: { $0.id == focusedID }) { focusedID = memories[scope] }
        }
        if !targets.contains(where: { $0.id == focusedID }) && !(window === self.window && focusedID?.hasPrefix("card.") == true) {
            let registeredDefault = controls.values.first { $0.preferred && $0.enabled && $0.view.window === window && !$0.view.visibleRect.isEmpty }?.id
            let preferred = registeredDefault ?? (window === self.window ? defaultFocus() : nil)
            let content = window === self.window ? targets.filter { $0.frame.maxY < window.frame.maxY - 64 } : targets
            focusedID = preferred.flatMap { id in targets.first(where: { $0.id == id })?.id } ?? content.first?.id ?? targets.first?.id
        }
        return targets
    }
    func handle(_ action: LauncherPadAction) {
        guard let currentWindow = activeWindow else { return }
        if !visible, currentWindow === window, let preferred = defaultFocus() { focusedID = preferred }
        visible = true
        if trackingMenu {
            switch action {
            case .confirm: sendKey(36, "\r", in: currentWindow)
            case .back: sendKey(53, "\u{1b}", in: currentWindow)
            case .up: sendKey(126, "\u{f700}", in: currentWindow)
            case .down: sendKey(125, "\u{f701}", in: currentWindow)
            case .left: sendKey(123, "\u{f702}", in: currentWindow)
            case .right: sendKey(124, "\u{f703}", in: currentWindow)
            default: break
            }
            return
        }
        let all = prepare(in: currentWindow)
        if let keyboard, currentWindow === keyboard.panel, keyboard.handle(action) { return }
        if inMainContent, onAction?(action) == true { return }
        let selected = all.first { $0.id == focusedID }
        switch action {
        case .confirm:
            guard let selected else { return }
            if let control = controls.values.first(where: { $0.id == selected.id && $0.enabled && $0.view.window === currentWindow }) { control.activate(); break }
            if ["AXTextField", "AXTextArea", "AXComboBox"].contains(selected.role) { edit(selected, window: currentWindow) }
            else if !S2ALauncherAX.press(selected.element) {
                S2ALauncherAX.focus(selected.element)
                if !S2ALauncherAX.pick(selected.element) { sendKey(36, "\r", in: currentWindow) }
            }
        case .back:
            if !S2ALauncherAX.cancel(currentWindow) { sendKey(53, "\u{1b}", in: currentWindow) }
        case .left, .right, .up, .down:
            let step = action == .left ? -1 : 1
            if action == .left || action == .right,
               let control = controls.values.first(where: { $0.id == focusedID && $0.enabled && $0.view.window === currentWindow }), let adjust = control.adjust { adjust(step); break }
            if let selected, ["AXSlider", "AXIncrementor"].contains(selected.role), action == .left || action == .right,
               S2ALauncherAX.adjust(selected.element, step: step) { break }
            if let selected, let next = LauncherPadSpatial.next(from: selected.frame, targets: all.filter { $0.id != selected.id }, action: action) {
                focus(next.id)
                if next.role == "AXRow" { _ = S2ALauncherAX.pick(next.element) }
            } else if let selected, action == .up || action == .down,
                      scroll(action == .up ? -1 : 1, page: false, window: currentWindow, selected: selected) {
                let oldScope = scope
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self, weak currentWindow] in
                    guard let self, let currentWindow, self.activeWindow === currentWindow, self.scope == oldScope else { return }
                    let fresh = self.targets(in: currentWindow)
                    let from = fresh.first { $0.id == selected.id } ?? selected
                    if let next = LauncherPadSpatial.next(from: from.frame, targets: fresh.filter { $0.id != selected.id }, action: action) { self.focus(next.id) }
                }
            }
        case .previousGroup: linear(-1, all: all)
        case .nextGroup: linear(1, all: all)
        case .scrollUp, .pageUp: scroll(-1, page: action == .pageUp, window: currentWindow, selected: selected)
        case .scrollDown, .pageDown: scroll(1, page: action == .pageDown, window: currentWindow, selected: selected)
        default: break
        }
        if let focusedID { memories[scope] = focusedID }
        draw(targets(in: currentWindow).first { $0.id == focusedID }, in: currentWindow)
    }
    private func linear(_ step: Int, all: [LauncherPadTarget]) {
        guard !all.isEmpty else { return }
        let index = all.firstIndex { $0.id == focusedID } ?? 0
        focus(all[(index + step + all.count) % all.count].id)
    }
    func activateFocused() { handle(.confirm) }
    func editFocused() {
        guard let window = activeWindow, let target = targets(in: window).first(where: { $0.id == focusedID }) else { return }
        edit(target, window: window)
    }
    func editText(value: String, label: String, apply: @escaping (String) -> Void) {
        guard keyboard == nil, let window = activeWindow else { return }
        keyboard = LauncherPadKeyboard(value: value, label: label, owner: window, navigation: self, apply: apply)
        keyboard?.show()
    }
    private func edit(_ target: LauncherPadTarget, window: NSWindow) {
        guard keyboard == nil else { return }
        keyboard = LauncherPadKeyboard(element: target.element, owner: window, navigation: self)
        keyboard?.show()
    }
    func sendKey(_ code: UInt16, _ characters: String, in window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }
    @discardableResult private func scroll(_ step: Int, page: Bool, window: NSWindow, selected: LauncherPadTarget?) -> Bool {
        func scrollViews(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews) }
        guard let content = window.contentView else { return false }
        let views = scrollViews(content).filter { $0.hasVerticalScroller && !$0.isHidden }
        let scrollView = views.first { view in
            guard let selected else { return true }
            return view.convert(view.bounds, to: nil).intersects(window.convertFromScreen(selected.frame))
        } ?? views.first
        guard let scrollView, let document = scrollView.documentView else { return false }
        var origin = scrollView.contentView.bounds.origin
        let before = origin
        let distance = page ? scrollView.contentView.bounds.height * 0.85 : 65
        origin.y += CGFloat(step) * distance * (document.isFlipped ? 1 : -1)
        origin.y = max(0, min(origin.y, max(0, document.bounds.height - scrollView.contentView.bounds.height)))
        scrollView.contentView.scroll(to: origin); scrollView.reflectScrolledClipView(scrollView.contentView)
        return origin != before
    }
    private func clearRings() { for overlay in overlays.values { overlay.target = nil } }
    private func draw(_ target: LauncherPadTarget?, in window: NSWindow) {
        clearRings()
        guard visible, let target, !target.id.hasPrefix("card."), let container = window.contentView?.superview else { return }
        let overlay: LauncherPadRing
        if let existing = overlays[window.windowNumber], existing.superview === container { overlay = existing }
        else {
            overlay = LauncherPadRing(frame: container.bounds)
            overlay.autoresizingMask = [.width, .height]
            container.addSubview(overlay, positioned: .above, relativeTo: nil)
            overlays[window.windowNumber] = overlay
        }
        overlay.target = overlay.convert(window.convertFromScreen(target.frame), from: nil)
    }
}

private final class LauncherPadRing: NSView {
    var target: CGRect? { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let target else { return }
        let ring = NSBezierPath(roundedRect: target.insetBy(dx: -3, dy: -3), xRadius: 10, yRadius: 10)
        NSColor(srgbRed: 1, green: 0.94, blue: 0.84, alpha: 1).setStroke()
        ring.lineWidth = 3; ring.stroke()
    }
}

struct LauncherPadHost: NSViewRepresentable {
    let navigation: LauncherPadNavigation
    let update: () -> Void
    final class Host: NSView {
        var navigation: LauncherPadNavigation?
        weak var lastWindow: NSWindow?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { lastWindow = window; navigation?.attach(window) } }
    }
    func makeNSView(context: Context) -> Host { let host = Host(); host.navigation = navigation; return host }
    func updateNSView(_ view: Host, context: Context) { update(); if let window = view.window { navigation.attach(window) } }
    static func dismantleNSView(_ view: Host, coordinator: ()) { if view.navigation?.window === view.lastWindow { view.navigation?.detach() } }
}
