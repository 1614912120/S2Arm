// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import Combine
import SwiftUI
import XCTest
import NXLauncher
@testable import NX2AppleUI

@MainActor final class PadControlsTests: XCTestCase {
    func testControllerAdjustsCustomSliderAndSkipsDisabledButton() async throws {
        let state = ControlsState()
        let navigation = LauncherPadNavigation()
        let window = host(ControlsFixture(state: state), navigation: navigation)
        defer { navigation.detach(); window.close() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(navigation.controlTargets(in: window).contains { $0.id == "disabled" })
        navigation.focus("slider")
        navigation.handle(.right)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(state.value, 0.6, accuracy: 0.0001)
        navigation.handle(.left)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(state.value, 0.5, accuracy: 0.0001)
        navigation.focus("toggle"); navigation.handle(.confirm)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(state.enabled)
        navigation.handle(.left)
        XCTAssertFalse(state.enabled)
        navigation.focus("default"); navigation.handle(.confirm)
        XCTAssertEqual(state.invocations, 1, "默认样式按钮也必须接收手柄确认")
    }

    func testDropdownOwnsControllerFocusAndReturnsToItsButton() async throws {
        let state = ControlsState()
        let navigation = LauncherPadNavigation()
        let window = host(ControlsFixture(state: state), navigation: navigation)
        defer { navigation.detach(); window.close() }
        try await Task.sleep(for: .milliseconds(100))
        navigation.focus("choice"); navigation.handle(.confirm)
        try await Task.sleep(for: .milliseconds(100))
        let targets = navigation.controlTargets(in: window)
        XCTAssertEqual(Set(targets.map(\.id)), ["dropdown.one", "dropdown.two", "dropdown.three"])
        navigation.handle(.down)
        XCTAssertEqual(navigation.focusedID, "dropdown.three", "打开时从当前选项 two 往下移动")
        navigation.handle(.confirm)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(state.choice, "three")
        navigation.handle(.up)
        XCTAssertFalse(navigation.focusedID?.hasPrefix("dropdown.") == true)
        XCTAssertTrue(navigation.controlTargets(in: window).contains { $0.id == "choice" })
    }

    private func host<V: View>(_ content: V, navigation: LauncherPadNavigation) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 500, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content.environment(\.padControls, navigation))
        window.orderBack(nil); window.contentView?.layoutSubtreeIfNeeded()
        navigation.attach(window)
        return window
    }
}

@MainActor private final class ControlsState: ObservableObject {
    @Published var value = 0.5
    @Published var enabled = false
    @Published var choice = "two"
    @Published var invocations = 0
}
private struct ControlsFixture: View {
    @ObservedObject var state: ControlsState
    var body: some View {
        VStack(spacing: 24) {
            Button("Disabled") {}.controllerButtonStyle(.plain).controllerID("disabled").disabled(true)
            LauncherDropdown(options: [("one", "One"), ("two", "Two"), ("three", "Three")], selection: state.choice) { state.choice = $0 }
                .controllerID("choice")
            LauncherSlider(value: state.value, range: 0...1, step: 0.1) { state.value = $0 }.controllerID("slider")
            Toggle("Enabled", isOn: $state.enabled).toggleStyle(PadToggleStyle(.switch)).controllerID("toggle")
            Button("Default action") { state.invocations += 1 }.controllerID("default")
        }.controllerButtonStyle(DefaultButtonStyle()).padding(50).frame(width: 500, height: 400).launcherDropdownHost()
    }
}
