// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import GameController
import SwiftUI
import XCTest
@testable import NXLauncher
@testable import NX2AppleUI

@MainActor final class ControllerInteractionTests: XCTestCase {
    func testManualScrollSelectsTheNextCompleteControlInsteadOfAClippedSliver() async throws {
        let fixture = ScrollFixture()
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(80))
        fixture.navigation.focus("row.1")
        fixture.scroll.contentView.scroll(to: CGPoint(x: 0, y: 110))
        fixture.scroll.reflectScrolledClipView(fixture.scroll.contentView)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(fixture.navigation.focusedID, "row.2", "手动滚动把焦点项裁掉一半时，应移到相邻的完整可见项")
        XCTAssertTrue(fixture.navigation.isFullyVisible(fixture.navigation.focusedID ?? ""))
    }

    func testScrollTargetsStayInsideTheirViewport() async throws {
        let fixture = ScrollFixture()
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(100))
        let clip = fixture.scroll.contentView
        let viewport = fixture.window.convertToScreen(clip.convert(clip.bounds, to: nil))
        let targets = fixture.navigation.controlTargets(in: fixture.window)
        XCTAssertTrue(targets.contains { $0.id == "row.0" })
        for target in targets where target.id.hasPrefix("row.") {
            XCTAssertTrue(viewport.contains(target.frame), "裁剪后的控件不能把焦点框画到标题或底栏：\(target.id) \(target.frame), viewport=\(viewport)")
        }
        fixture.navigation.focus("row.0")
        clip.scroll(to: CGPoint(x: 0, y: 420))
        fixture.scroll.reflectScrolledClipView(clip)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotEqual(fixture.navigation.focusedID, "row.0", "滚动后不能保留已经离开视口的幽灵焦点")
        let focused = try XCTUnwrap(fixture.navigation.controlTargets(in: fixture.window).first { $0.id == fixture.navigation.focusedID })
        XCTAssertEqual(fixture.navigation.focusRingFrame(in: fixture.window), focused.frame, "焦点框必须跟随滚动后的实际控件边界")
    }

    func testDownRevealsTheNextRowBeforeJumpingToFooter() async throws {
        let fixture = ScrollFixture()
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(100))
        fixture.navigation.focus("row.0")
        for index in 1...11 {
            fixture.navigation.handle(.down)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(fixture.navigation.focusedID, "row.\(index)", "下一个内容项应先滚入视口，再到固定底栏")
            XCTAssertTrue(fixture.navigation.isFullyVisible("row.\(index)"))
        }
        fixture.navigation.handle(.down)
        XCTAssertEqual(fixture.navigation.focusedID, "footer")
        fixture.navigation.handle(.up)
        XCTAssertEqual(fixture.navigation.focusedID, "row.11")
    }

    func testControllerSnapshotTraversesTheProductionInputAndShortcutPath() async throws {
        let fixture = ScrollFixture()
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(80))
        let snapshot = GCController.withExtendedGamepad()
        let pad = try XCTUnwrap(snapshot.extendedGamepad)
        let source = fixture.navigation.source
        source.stop()
        source.controllers = { [snapshot] }
        source.isActive = { true }
        source.tick(now: 0) // require a neutral frame on connect
        fixture.navigation.focus("row.0")
        pad.dpad.setValueForXAxis(0, yAxis: -1)
        source.tick(now: 0.01)
        XCTAssertEqual(fixture.navigation.focusedID, "row.1")
        source.tick(now: 0.2)
        XCTAssertEqual(fixture.navigation.focusedID, "row.1", "长按延迟内不能重复")
        source.tick(now: 0.38)
        XCTAssertEqual(fixture.navigation.focusedID, "row.2", "持续按住方向键应按节奏重复")
        pad.dpad.setValueForXAxis(0, yAxis: 0)
        source.tick(now: 0.4)
        pad.buttonA.setValue(1)
        source.tick(now: 0.41)
        XCTAssertEqual(fixture.rowActions, 1, "A 操作当前项，不能误提交弹窗")
        XCTAssertEqual(fixture.submits, 0)
        pad.buttonA.setValue(0); source.tick(now: 0.42)
        pad.buttonMenu.setValue(1); source.tick(now: 0.43)
        XCTAssertEqual(fixture.submits, 1, "Menu 在内容焦点上也能提交底栏动作")
        source.tick(now: 1)
        XCTAssertEqual(fixture.submits, 1, "提交按钮长按不能重复触发")
        pad.buttonMenu.setValue(0); source.tick(now: 1.01)
        pad.buttonB.setValue(1); source.tick(now: 1.02)
        XCTAssertEqual(fixture.cancels, 1)
        source.controllers = { [] }; source.tick(now: 1.03)
        source.controllers = { [snapshot] }; source.tick(now: 1.04)
        XCTAssertEqual(fixture.cancels, 1, "重连接时按住的 B 不能再触发")
        pad.buttonB.setValue(0); source.tick(now: 1.05)
        pad.buttonB.setValue(1); source.tick(now: 1.06)
        XCTAssertEqual(fixture.cancels, 2)
    }

    func testDisabledShortcutCannotDismissOrReachTheParent() async throws {
        let fixture = ScrollFixture()
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(80))
        let disabled = NSView(frame: CGRect(x: 20, y: 10, width: 120, height: 35))
        fixture.window.contentView?.addSubview(disabled)
        fixture.navigation.register(PadControl(token: UUID(), id: "disabled", scope: "page", view: disabled,
            enabled: false, activate: { XCTFail("禁用动作不能执行") }, adjust: nil, preferred: false, shortcuts: [.secondary]))
        fixture.navigation.focus("row.0")
        fixture.navigation.handle(.filter)
        XCTAssertEqual(fixture.navigation.focusedID, "row.0")
        XCTAssertEqual(fixture.submits, 0)
        XCTAssertEqual(fixture.cancels, 0)
    }

    func testDisabledDropdownStillOwnsFocusAndDoesNotTriggerParentShortcuts() async throws {
        let fixture = ScrollFixture()
        defer { fixture.close() }
        fixture.navigation.focus("row.0")
        let option = NSView(frame: CGRect(x: 100, y: 130, width: 240, height: 40))
        fixture.window.contentView?.addSubview(option)
        fixture.navigation.register(PadControl(token: UUID(), id: "dropdown.disabled", scope: "dropdown", view: option,
            enabled: false, activate: { XCTFail("禁用选项不能执行") }, adjust: nil, preferred: false))
        XCTAssertFalse(fixture.navigation.inMainContent, "全禁用的下拉层也必须隔离底层输入")
        XCTAssertTrue(fixture.navigation.controlTargets(in: fixture.window).isEmpty)
        fixture.navigation.handle(.menu)
        fixture.navigation.handle(.confirm)
        XCTAssertEqual(fixture.submits, 0)
        XCTAssertEqual(fixture.rowActions, 0)
    }

    func testKeyboardBackCancelsWhileMenuCommits() async throws {
        let fixture = ScrollFixture()
        defer { fixture.close() }
        var text = "original"
        fixture.navigation.focus("row.0")
        fixture.navigation.editText(value: text, label: "Original text") { text = $0 }
        try await Task.sleep(for: .milliseconds(100))
        fixture.navigation.keyboard?.value = "cancelled"
        fixture.navigation.handle(.back)
        XCTAssertEqual(text, "original", "B 应取消输入，不应悄悄保存")
        XCTAssertNil(fixture.navigation.keyboard)
        XCTAssertEqual(fixture.navigation.focusedID, "row.0")
        fixture.navigation.editText(value: text, label: "Original text") { text = $0 }
        try await Task.sleep(for: .milliseconds(100))
        fixture.navigation.keyboard?.value = "committed"
        fixture.navigation.handle(.menu)
        XCTAssertEqual(text, "committed")
        XCTAssertEqual(fixture.navigation.focusedID, "row.0")
    }

    func testNativeAlertButtonsShowAndExecuteTheirOwnShortcuts() async throws {
        _ = NSApplication.shared
        let alert = NSAlert()
        alert.messageText = "Original controller fixture"
        let primary = alert.addButton(withTitle: "Confirm")
        let cancel = alert.addButton(withTitle: "Cancel")
        primary.keyEquivalent = "\r"; cancel.keyEquivalent = "\u{1b}"
        alert.layout()
        let window = alert.window
        window.isReleasedWhenClosed = false
        let navigation = LauncherPadNavigation()
        navigation.source.controllers = { [] }
        navigation.attach(window)
        defer { navigation.detach(); window.close() }
        window.orderBack(nil)
        _ = navigation.targets(in: window)
        XCTAssertNotNil(primary.image, "原生确认框也应在按钮内显示手柄键")
        XCTAssertNotNil(cancel.image)
        let sink = NativeButtonSink()
        primary.target = sink; primary.action = #selector(NativeButtonSink.submit)
        cancel.target = sink; cancel.action = #selector(NativeButtonSink.cancel)
        navigation.handle(.menu)
        XCTAssertEqual(sink.submits, 1)
        navigation.handle(.back)
        XCTAssertEqual(sink.cancels, 1)
        navigation.detach()
        XCTAssertNil(primary.image, "解绑时恢复原生按钮，不留下测试状态")
    }

    func testChildPanelShortcutsDoNotLeakAndParentFocusReturns() async throws {
        let fixture = ScrollFixture()
        defer { fixture.close() }
        fixture.navigation.focus("row.1")
        fixture.navigation.handle(.right) // save the parent scope
        let child = NSPanel(contentRect: CGRect(x: 120, y: 120, width: 280, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        child.isReleasedWhenClosed = false
        let button = NSView(frame: CGRect(x: 20, y: 20, width: 160, height: 40))
        child.contentView?.addSubview(button)
        var submits = 0
        fixture.navigation.register(PadControl(token: UUID(), id: "child.submit", scope: "page", view: button,
            enabled: true, activate: { submits += 1 }, adjust: nil, preferred: true, shortcuts: [.primary]))
        fixture.window.addChildWindow(child, ordered: .above); child.orderFront(nil)
        defer { fixture.window.removeChildWindow(child); child.close() }
        fixture.navigation.handle(.menu)
        XCTAssertEqual(submits, 1)
        XCTAssertEqual(fixture.submits, 0, "子弹窗不能触发父窗口完成")
        fixture.window.removeChildWindow(child); child.orderOut(nil)
        fixture.navigation.handle(.up)
        XCTAssertEqual(fixture.navigation.focusedID, "row.0", "返回父窗口后从之前的 row.1 继续导航")
        XCTAssertEqual(fixture.rowActions, 0)
    }
}

@MainActor private final class NativeButtonSink: NSObject {
    var submits = 0, cancels = 0
    @objc func submit() { submits += 1 }
    @objc func cancel() { cancels += 1 }
}

@MainActor private final class ScrollFixture {
    let navigation = LauncherPadNavigation()
    let window: NSWindow
    let scroll = NSScrollView()
    var rowActions = 0, submits = 0, cancels = 0
    init() {
        _ = NSApplication.shared
        window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 480, height: 340), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 480, height: 340))
        scroll.frame = CGRect(x: 20, y: 60, width: 440, height: 220)
        scroll.hasVerticalScroller = true
        let document = FlippedDocument(frame: CGRect(x: 0, y: 0, width: 420, height: 840))
        scroll.documentView = document
        content.addSubview(scroll)
        window.contentView = content
        for index in 0..<12 {
            let view = NSView(frame: CGRect(x: 20, y: 20 + index * 70, width: 360, height: 40))
            document.addSubview(view)
            navigation.register(PadControl(token: UUID(), id: "row.\(index)", scope: "page", view: view, enabled: true, activate: { [weak self] in self?.rowActions += 1 }, adjust: nil, preferred: false))
        }
        let footer = NSView(frame: CGRect(x: 280, y: 10, width: 160, height: 35))
        content.addSubview(footer)
        navigation.register(PadControl(token: UUID(), id: "footer", scope: "page", view: footer, enabled: true, activate: { [weak self] in self?.submits += 1 }, adjust: nil, preferred: false, shortcuts: [.primary]))
        let cancel = NSView(frame: CGRect(x: 20, y: 10, width: 100, height: 35))
        content.addSubview(cancel)
        navigation.register(PadControl(token: UUID(), id: "cancel", scope: "page", view: cancel, enabled: true, activate: { [weak self] in self?.cancels += 1 }, adjust: nil, preferred: false, shortcuts: [.back]))
        navigation.source.controllers = { [] }
        navigation.attach(window)
        window.orderBack(nil)
    }
    func close() { navigation.detach(); window.close() }
}

private final class FlippedDocument: NSView { override var isFlipped: Bool { true } }
