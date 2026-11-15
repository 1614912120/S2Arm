// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
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
                    .overlay(alignment: .topTrailing) {
                        if !text.isEmpty { Circle().fill(LauncherPalette.cream).frame(width: 5, height: 5).offset(x: 5, y: -3) }
                    }
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
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(width: isExpanded ? width : 40, height: 40)
        .foregroundStyle(LauncherTheme.Colors.text)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(focused || hovered ? 0.4 : 0.12)))
        .clipShape(Capsule())
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: isExpanded)
        .onChange(of: isExpanded) { if !$0 { focused = false } }
        .accessibilityElement(children: .contain).accessibilityIdentifier("home.search.control")
    }
}
