// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import SwiftUI

/// Buttons register their actual action and view, including when SwiftUI has not
/// materialized its out-of-process accessibility tree. Native panels use AppKit.
@MainActor package protocol PadControlRegistry: AnyObject {
    var presentation: PadPresentation { get }
    func register(_ control: PadControl)
    func removeControl(_ token: UUID)
}
package struct PadControl {
    /// Identity of this native registration, independent of the semantic control ID.
    package let token: UUID
    package let id: String
    package let scope: String
    package let view: NSView
    package let enabled: Bool
    package let activate: () -> Void
    package let adjust: ((Int) -> Void)?
    package let preferred: Bool
    package var shortcuts: [PadShortcut] = []
    package var shortcutsRequireFocus = false
}
/// A operates the focused control; the right trigger submits the current page.
/// Hints follow the primary player's controller family and face-button mapping.
package enum PadShortcut: String, CaseIterable {
    case primary, back, secondary, tertiary, leftTrigger, rightTrigger
    package var symbol: String {
        switch self {
        case .primary: return "a.circle"
        case .back: return "b.circle"
        case .secondary: return "x.circle"
        case .tertiary: return "y.circle"
        case .leftTrigger: return "lt.rectangle.roundedtop"
        case .rightTrigger: return "rt.rectangle.roundedtop"
        }
    }
}
@MainActor package final class PadPresentation: ObservableObject {
    @Published package var connected = false
    @Published package var symbols: [PadShortcut: String] = [:]
    package init() {}
}
private struct PadShortcutsKey: EnvironmentKey { static let defaultValue: [PadShortcut] = [] }
private struct PadShortcutsRequireFocusKey: EnvironmentKey { static let defaultValue = false }
private struct PadRegistryKey: EnvironmentKey { static let defaultValue: (any PadControlRegistry)? = nil }
private struct PadControlIDKey: EnvironmentKey { static let defaultValue: String? = nil }
private struct PadControlScopeKey: EnvironmentKey { static let defaultValue = "page" }
private struct PadPreferredKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    package var padControls: (any PadControlRegistry)? { get { self[PadRegistryKey.self] } set { self[PadRegistryKey.self] = newValue } }
    package var padControlID: String? { get { self[PadControlIDKey.self] } set { self[PadControlIDKey.self] = newValue } }
    package var padControlScope: String { get { self[PadControlScopeKey.self] } set { self[PadControlScopeKey.self] = newValue } }
    package var padPreferred: Bool { get { self[PadPreferredKey.self] } set { self[PadPreferredKey.self] = newValue } }
    package var padShortcuts: [PadShortcut] { get { self[PadShortcutsKey.self] } set { self[PadShortcutsKey.self] = newValue } }
    package var padShortcutsRequireFocus: Bool { get { self[PadShortcutsRequireFocusKey.self] } set { self[PadShortcutsRequireFocusKey.self] = newValue } }
}
extension View {
    package func controllerID(_ id: String) -> some View { environment(\.padControlID, id).accessibilityIdentifier(id) }
    package func controllerScope(_ scope: String) -> some View { environment(\.padControlScope, scope) }
    package func controllerPreferredFocus(_ preferred: Bool) -> some View { environment(\.padPreferred, preferred) }
    /// Secondary submit actions in a page with multiple tasks require focus, so
    /// R2 cannot start an unrelated row or replace the page's default action.
    /// Back and other aliases remain available regardless of focus.
    package func controllerShortcut(_ shortcuts: PadShortcut..., focused: Bool = false) -> some View {
        environment(\.padShortcuts, shortcuts).environment(\.padShortcutsRequireFocus, focused)
    }
    package func controllerConnectedOnly() -> some View { modifier(PadConnectedOnlyModifier()) }
    package func controllerButtonStyle<S: ButtonStyle>(_ style: S) -> some View { buttonStyle(PadVisualButtonStyle(style: style)) }
    package func controllerButtonStyle<S: PrimitiveButtonStyle>(_ style: S) -> some View { buttonStyle(PadPrimitiveButtonStyle(style: style)) }
    package func controllerControl(id: String? = nil, activate: @escaping () -> Void, adjust: ((Int) -> Void)? = nil) -> some View {
        modifier(PadControlModifier(explicitID: id, activate: activate, adjust: adjust))
    }
}
private struct PadVisualButtonStyle<Style: ButtonStyle>: PrimitiveButtonStyle {
    let style: Style
    func makeBody(configuration: Configuration) -> some View {
        Button(action: configuration.trigger) { PadButtonLabel(label: configuration.label) }
            .buttonStyle(style).modifier(PadControlModifier(activate: configuration.trigger))
    }
}
private struct PadPrimitiveButtonStyle<Style: PrimitiveButtonStyle>: PrimitiveButtonStyle {
    let style: Style
    func makeBody(configuration: Configuration) -> some View {
        Button(action: configuration.trigger) { PadButtonLabel(label: configuration.label) }
            .buttonStyle(style).modifier(PadControlModifier(activate: configuration.trigger))
    }
}
private struct PadButtonLabel<Label: View>: View {
    let label: Label
    @Environment(\.padShortcuts) private var shortcuts
    @Environment(\.padControls) private var registry
    @ViewBuilder var body: some View {
        if let shortcut = shortcuts.first, let presentation = registry?.presentation {
            PadConnectedButtonLabel(label: label, shortcut: shortcut, presentation: presentation)
        } else { label }
    }
}
private struct PadConnectedButtonLabel<Label: View>: View {
    let label: Label
    let shortcut: PadShortcut
    @ObservedObject var presentation: PadPresentation
    @ViewBuilder var body: some View {
        if presentation.connected {
            HStack(spacing: 6) {
                Image(systemName: presentation.symbols[shortcut] ?? shortcut.symbol)
                    .font(.system(size: 16, weight: .medium)).accessibilityHidden(true)
                label
            }
        } else { label }
    }
}
private struct PadConnectedOnlyModifier: ViewModifier {
    @Environment(\.padControls) private var registry
    @ViewBuilder func body(content: Content) -> some View {
        if let presentation = registry?.presentation {
            PadConnectedContent(content: content, presentation: presentation)
        }
    }
}
private struct PadConnectedContent<Content: View>: View {
    let content: Content
    @ObservedObject var presentation: PadPresentation
    @ViewBuilder var body: some View {
        if presentation.connected { content }
    }
}
private struct PadControlModifier: ViewModifier {
    var explicitID: String?
    let activate: () -> Void
    var adjust: ((Int) -> Void)?
    @State private var token = UUID()
    @Environment(\.padControls) private var registry
    @Environment(\.padControlID) private var identifier
    @Environment(\.padControlScope) private var scope
    @Environment(\.isEnabled) private var enabled
    @Environment(\.padPreferred) private var preferred
    @Environment(\.padShortcuts) private var shortcuts
    @Environment(\.padShortcutsRequireFocus) private var shortcutsRequireFocus
    func body(content: Content) -> some View {
        content.background {
            if registry != nil {
                PadControlFrame(registry: registry, id: explicitID ?? identifier ?? "control." + token.uuidString,
                    scope: scope, enabled: enabled, activate: activate, adjust: adjust, preferred: preferred, shortcuts: shortcuts,
                    shortcutsRequireFocus: shortcutsRequireFocus)
            }
        }
    }
}
private struct PadControlFrame: NSViewRepresentable {
    let registry: (any PadControlRegistry)?
    let id: String
    let scope: String
    let enabled: Bool
    let activate: () -> Void
    let adjust: ((Int) -> Void)?
    let preferred: Bool
    let shortcuts: [PadShortcut]
    let shortcutsRequireFocus: Bool
    final class Host: NSView {
        weak var registry: (any PadControlRegistry)?
        // SwiftUI can overlap old and new hosts during a button-style update.
        // Each host must remove only its own registration when dismantled.
        let token = UUID()
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
    }
    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ view: Host, context: Context) {
        if let previous = view.registry, previous !== registry { previous.removeControl(view.token) }
        view.registry = registry
        registry?.register(PadControl(token: view.token, id: id, scope: scope, view: view, enabled: enabled, activate: activate, adjust: adjust, preferred: preferred, shortcuts: shortcuts, shortcutsRequireFocus: shortcutsRequireFocus))
    }
    static func dismantleNSView(_ view: Host, coordinator: ()) {
        view.registry?.removeControl(view.token)
    }
}

/// Preserve the requested system switch/checkbox appearance and expose its value
/// action directly; it must not depend on the macOS Full Keyboard Access setting.
package struct PadToggleStyle<Style: ToggleStyle>: ToggleStyle {
    let style: Style
    package init(_ style: Style) { self.style = style }
    package func makeBody(configuration: Configuration) -> some View {
        Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(style)
            .modifier(PadControlModifier(activate: { configuration.isOn.toggle() }, adjust: { configuration.isOn = $0 > 0 }))
    }
}
