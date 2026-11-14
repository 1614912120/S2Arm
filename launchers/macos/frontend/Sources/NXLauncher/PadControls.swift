// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import SwiftUI

/// Buttons register their actual action and view, including when SwiftUI has not
/// materialized its out-of-process accessibility tree. Native panels use AppKit.
@MainActor package protocol PadControlRegistry: AnyObject {
    func register(_ control: PadControl)
    func removeControl(_ token: UUID)
}
package struct PadControl {
    package let token: UUID
    package let id: String
    package let scope: String
    package let view: NSView
    package let enabled: Bool
    package let activate: () -> Void
    package let adjust: ((Int) -> Void)?
    package let preferred: Bool
}
private struct PadRegistryKey: EnvironmentKey { static let defaultValue: (any PadControlRegistry)? = nil }
private struct PadControlIDKey: EnvironmentKey { static let defaultValue: String? = nil }
private struct PadControlScopeKey: EnvironmentKey { static let defaultValue = "page" }
private struct PadPreferredKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    package var padControls: (any PadControlRegistry)? { get { self[PadRegistryKey.self] } set { self[PadRegistryKey.self] = newValue } }
    package var padControlID: String? { get { self[PadControlIDKey.self] } set { self[PadControlIDKey.self] = newValue } }
    package var padControlScope: String { get { self[PadControlScopeKey.self] } set { self[PadControlScopeKey.self] = newValue } }
    package var padPreferred: Bool { get { self[PadPreferredKey.self] } set { self[PadPreferredKey.self] = newValue } }
}
extension View {
    package func controllerID(_ id: String) -> some View { environment(\.padControlID, id).accessibilityIdentifier(id) }
    package func controllerScope(_ scope: String) -> some View { environment(\.padControlScope, scope) }
    package func controllerPreferredFocus(_ preferred: Bool) -> some View { environment(\.padPreferred, preferred) }
    package func controllerButtonStyle<S: ButtonStyle>(_ style: S) -> some View { buttonStyle(PadVisualButtonStyle(style: style)) }
    package func controllerButtonStyle<S: PrimitiveButtonStyle>(_ style: S) -> some View { buttonStyle(PadPrimitiveButtonStyle(style: style)) }
    package func controllerControl(id: String? = nil, activate: @escaping () -> Void, adjust: ((Int) -> Void)? = nil) -> some View {
        modifier(PadControlModifier(explicitID: id, activate: activate, adjust: adjust))
    }
}
private struct PadVisualButtonStyle<Style: ButtonStyle>: PrimitiveButtonStyle {
    let style: Style
    func makeBody(configuration: Configuration) -> some View {
        Button(action: configuration.trigger) { configuration.label }
            .buttonStyle(style).modifier(PadControlModifier(activate: configuration.trigger))
    }
}
private struct PadPrimitiveButtonStyle<Style: PrimitiveButtonStyle>: PrimitiveButtonStyle {
    let style: Style
    func makeBody(configuration: Configuration) -> some View {
        Button(action: configuration.trigger) { configuration.label }
            .buttonStyle(style).modifier(PadControlModifier(activate: configuration.trigger))
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
    func body(content: Content) -> some View {
        content.background(PadControlFrame(registry: registry, token: token, id: explicitID ?? identifier ?? "control." + token.uuidString,
            scope: scope, enabled: enabled, activate: activate, adjust: adjust, preferred: preferred))
    }
}
private struct PadControlFrame: NSViewRepresentable {
    let registry: (any PadControlRegistry)?
    let token: UUID
    let id: String
    let scope: String
    let enabled: Bool
    let activate: () -> Void
    let adjust: ((Int) -> Void)?
    let preferred: Bool
    final class Host: NSView {
        weak var registry: (any PadControlRegistry)?
        var token: UUID?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
    }
    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ view: Host, context: Context) {
        view.registry = registry; view.token = token
        registry?.register(PadControl(token: token, id: id, scope: scope, view: view, enabled: enabled, activate: activate, adjust: adjust, preferred: preferred))
    }
    static func dismantleNSView(_ view: Host, coordinator: ()) { if let token = view.token { view.registry?.removeControl(token) } }
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
