// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// The Home search stays in the control row while its capsule expands toward the available space.
struct HomeSearchControl: View {
    @Binding var isExpanded: Bool
    @Binding var text: String
    let width: CGFloat
    let edit: () -> Void
    @EnvironmentObject private var loc: Localizer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                focused = false
                isExpanded.toggle()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(hovered ? 0.08 : 0), in: Circle())
                    .contentShape(Circle())
            }
            .controllerButtonStyle(.plain).controllerID("home.search")
            .onHover { hovered = $0 }
            .help(loc.t(isExpanded ? "home.collapseSearch" : "home.search"))
            .accessibilityLabel(loc.t(isExpanded ? "home.collapseSearch" : "home.search"))
            .accessibilityValue(text).accessibilityAddTraits(isExpanded ? .isSelected : [])
            if isExpanded {
                HStack(spacing: LauncherTheme.Space.xSmall) {
                    TextField("", text: $text, prompt: Text(loc.t(width <= LauncherControl.width ? "home.search.compact" : "home.search"))
                        .foregroundColor(LauncherTheme.Colors.secondary))
                        .textFieldStyle(.plain).font(LauncherTheme.TypeStyle.body)
                        .focused($focused).onAppear { focused = true }
                        .onExitCommand { focused = false; isExpanded = false }
                        .controllerControl(id: "home.search.field", activate: edit)
                        .accessibilityLabel(loc.t("home.search")).accessibilityIdentifier("home.search.field")
                    if !text.isEmpty {
                        Button { text = ""; focused = true } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                .frame(width: 28, height: 36).contentShape(Rectangle())
                        }
                        .controllerButtonStyle(.plain).controllerID("home.search.clear")
                        .help(loc.t("home.clearSearch")).accessibilityLabel(loc.t("home.clearSearch"))
                    }
                }
                .padding(.leading, LauncherTheme.Space.xSmall).padding(.trailing, LauncherTheme.Space.medium)
                .transition(.opacity)
            }
        }
        // Keep the icon in the same leading slot while the outer capsule reveals the field.
        .frame(width: width, height: 40, alignment: .leading)
        .frame(width: isExpanded ? width : 40, height: 40, alignment: .leading)
        .foregroundStyle(LauncherTheme.Colors.text)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(focused || hovered ? 0.4 : 0.12)))
        .clipShape(Capsule())
        .background(HomeSearchDismissal(isExpanded: isExpanded) { focused = false; isExpanded = false })
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: isExpanded)
        .onChange(of: isExpanded) { if !$0 { focused = false } }
        .onChange(of: focused) { if !$0 { isExpanded = false } }
        .accessibilityElement(children: .contain).accessibilityIdentifier("home.search.control")
    }
}

/// Blank areas and most macOS buttons do not take text focus when clicked.
/// Observe those clicks without intercepting the action at their destination.
private struct HomeSearchDismissal: NSViewRepresentable {
    let isExpanded: Bool
    let dismiss: () -> Void
    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ view: Host, context: Context) {
        view.isExpanded = isExpanded
        view.dismiss = dismiss
    }
    static func dismantleNSView(_ view: Host, coordinator: ()) { view.stopObserving() }

    final class Host: NSView {
        var isExpanded = false
        var dismiss: () -> Void = {}
        private var monitor: Any?
        private var resignation: NSObjectProtocol?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                guard let self, self.isExpanded else { return event }
                if event.window !== self.window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.dismiss()
                }
                return event
            }
            resignation = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                object: window, queue: .main) { [weak self] _ in
                    guard let self, self.isExpanded else { return }
                    self.dismiss()
                }
        }
        func stopObserving() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let resignation { NotificationCenter.default.removeObserver(resignation) }
            monitor = nil; resignation = nil
        }
        deinit { stopObserving() }
    }
}
