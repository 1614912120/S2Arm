// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import GameController
import LauncherPadBridge
import SwiftUI
import XCTest
import NXCore
import NXModel
@testable import NXLauncher
import S2ArmAppleAdapter
@testable import NX2AppleUI

/// Real SwiftUI pages with original, asset-free job responses; never reads the player's library.
@MainActor final class SettingsLayoutTests: XCTestCase {
    func testPlayResultAlignsWithPageInsetsAndTheSharedPrimaryAction() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.runner.catalogCover = "original-play-cover"
        let artwork = NSImage(size: CGSize(width: 100, height: 100), flipped: false) { rect in
            NSColor(deviceRed: 0.8, green: 0.1, blue: 0.9, alpha: 1).setFill()
            rect.fill(); return true
        }
        let covers = CoverCache { _, _ in CoverCache.Loaded(version: "original", image: artwork) }
        fixture.model.refresh()
        for _ in 0..<100 where fixture.model.games.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let game = try XCTUnwrap(fixture.model.games.first)
        for language in [Lang.zh, .en] {
            for (width, height): (CGFloat, CGFloat) in [(800, 450), (1120, 630), (1440, 810)] {
                let session = JobSession(kind: .play, gameID: game.id, name: game.name,
                    phase: .finished(.completed), stage: "游戏运行中")
                fixture.model.session = session
                let page = AnyView(PlaySessionView(model: fixture.model, covers: covers, session: session,
                    uiLanguage: language == .zh ? "zh-Hans" : "en")
                    .background(LauncherWindowMaterial()).foregroundStyle(LauncherTheme.Colors.text)
                    .preferredColorScheme(.dark).frame(width: width, height: height))
                let (host, window) = try await render(page, fixture: fixture, language: language)
                defer { window.close() }
                for connected in [false, true] {
                    fixture.navigation.presentation.connected = connected
                    try await Task.sleep(for: .milliseconds(80))
                    let back = try XCTUnwrap(fixture.navigation.controlTargets(in: window).first)
                    let bounds = window.convertToScreen(host.bounds)
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let scale = CGFloat(bitmap.pixelsWide) / width
                    // The original magenta cover isolates the information column from text and material shadows.
                    let first = try XCTUnwrap((0..<bitmap.pixelsWide).first { x in
                        guard let color = bitmap.colorAt(x: x, y: Int(80 * scale))?.usingColorSpace(.deviceRGB) else { return false }
                        return color.redComponent - color.greenComponent > 0.3 && color.blueComponent - color.greenComponent > 0.3
                    })
                    let left = CGFloat(first) / scale, buttonFrame = back.frame
                    print("play-result \(language.code)/\(width)/\(connected): left=\(left), right=\(bounds.maxX - buttonFrame.maxX), bottom=\(buttonFrame.minY - bounds.minY), height=\(buttonFrame.height)")
                    XCTAssertEqual(left, 48, accuracy: 1, "游戏信息与游戏库共用 48 pt 左边距")
                    XCTAssertEqual(back.id, "play.back")
                    XCTAssertEqual(bounds.maxX - buttonFrame.maxX, 48, accuracy: 1, "回库按钮应放在右下角，与其他页面右边缘对齐")
                    XCTAssertEqual(buttonFrame.minY - bounds.minY, 16, accuracy: 1)
                    XCTAssertEqual(buttonFrame.height, 48, accuracy: 1, "使用共用的突出主按钮尺寸")
                    XCTAssertTrue(bounds.contains(buttonFrame))
                    let shortcuts = fixture.navigation.shortcutTargets(in: window)
                    XCTAssertEqual(shortcuts[.primary], ["play.back"])
                    XCTAssertEqual(shortcuts[.back], ["play.back"])
                    try snapshot(host, "play-result-\(language.code)-\(Int(width))-\(connected ? "connected" : "disconnected")")
                }
            }
        }
    }

    func testPlayFooterActionsKeepTheirBehaviorInRunningStoppingAndFailedStates() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.model.refresh()
        for _ in 0..<100 where fixture.model.games.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let game = try XCTUnwrap(fixture.model.games.first)
        for phase in [JobSession.Phase.running, .stopping, .finished(.failed)] {
            let session = JobSession(kind: .play, gameID: game.id, name: game.name, phase: phase, stage: "游戏运行中")
            fixture.model.session = session
            let page = AnyView(PlaySessionView(model: fixture.model, covers: CoverCache(), session: session, uiLanguage: "en")
                .background(LauncherWindowMaterial()).frame(width: 800, height: 450))
            let (host, window) = try await render(page, fixture: fixture, language: .en)
            let navigation = fixture.navigation
            navigation.source.controllers = { [] }; navigation.attach(window); navigation.source.stop()
            defer { navigation.detach(); window.close() }
            navigation.presentation.connected = true
            try await Task.sleep(for: .milliseconds(80))
            let bounds = window.convertToScreen(host.bounds)
            let actionID = phase == .finished(.failed) ? "play.back" : "play.stop"
            let button = navigation.controlTargets(in: window).first { $0.id == actionID }
            if phase == .stopping {
                XCTAssertNil(button, "正在停止时不能重复发送停止动作")
            } else {
                let frame = try XCTUnwrap(button).frame
                XCTAssertTrue(bounds.contains(frame), "小窗口中失败说明滚动，底栏操作始终可见")
                XCTAssertEqual(bounds.maxX - frame.maxX, 48, accuracy: 1)
                XCTAssertEqual(frame.minY - bounds.minY, 16, accuracy: 1)
                XCTAssertEqual(frame.height, 48, accuracy: 1)
            }
            if phase == .finished(.failed) {
                for action in [LauncherPadAction.confirm, .menu, .back] {
                    fixture.model.session = session
                    navigation.focus("play.back"); navigation.handle(action)
                    XCTAssertNil(fixture.model.session, "A、Menu 与 B 均应执行原有回库操作")
                }
            } else {
                navigation.handle(.menu)
                XCTAssertEqual(fixture.model.session?.phase, .stopping)
            }
            XCTAssertFalse(fixture.runner.requests.contains { $0["operation"] as? String == "launch" }, "底栏操作不能意外重启游戏")
            try snapshot(host, "play-footer-\(actionID)-\(phase == .stopping ? "stopping" : "active")")
        }
    }

    func testControllerSettingsScrollKeepsFocusOnVisibleControls() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        for language in [Lang.zh, .en] {
            let (host, window) = try await render(AnyView(EnvironmentView(model: fixture.model)), fixture: fixture, language: language)
            let navigation = fixture.navigation
            navigation.source.controllers = { [] }
            navigation.attach(window)
            defer { navigation.detach(); window.close() }
            let snapshot = GCController.withExtendedGamepad()
            let pad = try XCTUnwrap(snapshot.extendedGamepad)
            navigation.source.stop()
            navigation.source.controllers = { [snapshot] }
            navigation.source.isActive = { true }
            var time: TimeInterval = 0
            func press(_ down: Bool) {
                time += 0.1
                pad.dpad.setValueForXAxis(0, yAxis: down ? -1 : 1)
                navigation.source.tick(now: time)
                pad.dpad.setValueForXAxis(0, yAxis: 0)
                navigation.source.tick(now: time + 0.01)
            }
            navigation.source.tick(now: 0)
            navigation.focus("settings.language")
            let scroll = try XCTUnwrap(scrollViews(in: host).first { $0.hasVerticalScroller })
            for down in [true, false] {
                for _ in 0..<22 {
                    press(down)
                    try await Task.sleep(for: .milliseconds(25))
                    let targets = navigation.controlTargets(in: window)
                    let focused = try XCTUnwrap(targets.first { $0.id == navigation.focusedID })
                    let view = try XCTUnwrap(focused.element as? NSView)
                    if view.enclosingScrollView != nil {
                        let viewport = window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
                        XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(focused.unclippedFrame ?? focused.frame),
                            "\(language.code)：方向导航必须先将整个控件滚入可见区域，\(focused.id)")
                    }
                }
            }
            navigation.focus("env.installMode.device")
            for step in 0..<14 {
                navigation.handle(.scrollDown)
                try await Task.sleep(for: .milliseconds(25))
                if let focused = navigation.controlTargets(in: window).first(where: { $0.id == navigation.focusedID }) {
                    let view = try XCTUnwrap(focused.element as? NSView)
                    let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
                    XCTAssertTrue(frame.intersects(window.convertToScreen(host.bounds)), "滚动第 \(step) 步不能留下脱离控件的焦点")
                    XCTAssertTrue(navigation.isFullyVisible(focused.id), "手动滚动后也应选中完整可见的项")
                    let ring = try XCTUnwrap(navigation.focusRingFrame(in: window))
                    XCTAssertEqual(ring.minX, focused.frame.minX, accuracy: 1)
                    XCTAssertEqual(ring.minY, focused.frame.minY, accuracy: 1)
                    XCTAssertEqual(ring.width, focused.frame.width, accuracy: 1)
                    XCTAssertEqual(ring.height, focused.frame.height, accuracy: 1)
                } else { XCTFail("滚动后焦点必须对应仍然可见的控件") }
            }
            try self.snapshot(host, "controller-settings-scrolled-" + language.code)
            if let container = host.superview { try self.snapshot(container, "controller-settings-focus-ring-" + language.code) }
        }
    }

    func testExportLocationSurvivesReopeningAndRestartingWithAnUnchangedList() async throws {
        for language in [Lang.zh, .en] {
            let fixture = try SettingsFixture()
            defer { fixture.remove() }
            let first = "/original/storage-default"
            let chosen = "/original/storage-selected"
            fixture.runner.storageResponse = ["locations": [
                ["id": "default", "path": first, "default": true, "connected": true, "freeBytes": 1000000],
                ["id": "selected", "path": chosen, "connected": true, "freeBytes": 2000000]
            ], "last": "default"]
            fixture.model.loadLocations()
            for _ in 0..<100 where fixture.model.locations.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(fixture.model.locations.count, 2)
            let game = GameSummary(id: "fixture", name: "Original location fixture",
                location: GameLocation(catalog: ["state": "ok", "path": first]))
            for stage in 0..<4 {
                let model = stage < 2 ? fixture.model : S2ArmLauncherModel(client: fixture.model.provider.client)
                if stage >= 2 {
                    if stage == 3 { fixture.runner.storageResponse = ["locations": [], "last": ""] }
                    model.loadLocations()
                    try await Task.sleep(for: .milliseconds(100))
                }
                let dropdown = LauncherDropdownState()
                let padFocus = PadFocus()
                let page = AnyView(ExportView(model: model, covers: CoverCache(), game: game, install: {})
                    .environmentObject(padFocus).padScope("main", padFocus)
                    .environment(\.launcherDropdownHost, dropdown)
                    .background(LauncherWindowMaterial()).foregroundStyle(LauncherTheme.Colors.text).preferredColorScheme(.dark)
                    .frame(width: 1120, height: 900))
                let (host, window) = try await render(page, fixture: fixture, language: language)
                fixture.navigation.source.controllers = { [] }
                fixture.navigation.attach(window)
                defer { fixture.navigation.detach(); window.close() }
                fixture.navigation.focus("export.location"); fixture.navigation.handle(.confirm)
                try await Task.sleep(for: .milliseconds(80))
                let request = try XCTUnwrap(dropdown.request)
                let expected = stage == 0 ? first : chosen
                print("export-location \(language.code)/stage-\(stage): \(request.selection)")
                XCTAssertEqual(request.selection, expected, "缓存列表不变、重开页面及重启模型后都应显示已选位置")
                XCTAssertTrue(request.options.contains { $0.value == expected }, "已选但尚未登记的文件夹也应有可见名称")
                if stage == 0 { request.choose(chosen) }
                dropdown.close()
                if stage == 1 { try snapshot(host, "export-location-remembered-" + language.code) }
            }
            XCTAssertFalse(fixture.runner.requests.contains { $0["operation"] as? String == "export" }, "只选位置不能开始出包或搬游戏")
        }
    }

    func testExportActionsLiveInBottomRightAndHaveControllerShortcuts() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        for platform in fixture.model.exportTargets where platform != .mac { fixture.model.toggleExport(platform) }
        if !fixture.model.exportTargets.contains(.mac) { fixture.model.toggleExport(.mac) }
        fixture.model.refresh()
        for _ in 0..<100 where fixture.model.games.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let game = try XCTUnwrap(fixture.model.games.first)
        for language in [Lang.zh, .en] {
            for width: CGFloat in [800, 1120, 1440] {
                let padFocus = PadFocus()
                let page = AnyView(ExportView(model: fixture.model, covers: CoverCache(), game: game, install: {})
                    .environmentObject(padFocus).padScope("main", padFocus).frame(width: width, height: 630))
                let (host, window) = try await render(page, fixture: fixture, language: language)
                fixture.navigation.source.controllers = { [] }; fixture.navigation.attach(window)
                fixture.navigation.source.stop(); fixture.navigation.source.isActive = { true }
                defer { fixture.navigation.detach(); window.close() }
                let snapshot = GCController.withExtendedGamepad()
                for connected in [false, true, false] {
                    fixture.navigation.source.controllers = { connected ? [snapshot] : [] }
                    fixture.navigation.source.tick()
                    fixture.navigation.hide()
                    if let scroll = scrollViews(in: host).first, let document = scroll.documentView {
                        let clip = scroll.contentView
                        clip.scroll(to: CGPoint(x: 0, y: document.isFlipped ? 0 : max(0, document.bounds.height - clip.bounds.height)))
                        scroll.reflectScrolledClipView(clip)
                    }
                    try await Task.sleep(for: .milliseconds(70))
                    let targets = fixture.navigation.controlTargets(in: window)
                    let ids = Set(LauncherPadNavigation.elements(window).compactMap { S2ALauncherAX.identifier($0) })
                    XCTAssertFalse(ids.contains("export.back"), "出包页不再显示左上角返回")
                    let start = try XCTUnwrap(targets.first { $0.id == "export.start" })
                    let cancel = try XCTUnwrap(targets.first { $0.id == "export.cancel" })
                    let cover = try XCTUnwrap(targets.first { $0.id == "export.cover" })
                    let bounds = window.convertToScreen(host.bounds)
                    XCTAssertEqual(bounds.maxY - cover.frame.maxY, 22, accuracy: 1, "移除返回按钮后，游戏内容直接从 22 pt 顶部边距开始")
                    XCTAssertTrue(bounds.contains(cancel.frame.union(start.frame)))
                    XCTAssertGreaterThan(cancel.frame.midX, bounds.midX, "取消和开始出包都应位于右下角")
                    XCTAssertLessThanOrEqual(cancel.frame.maxX, start.frame.minX)
                    XCTAssertEqual(cancel.frame.midY, start.frame.midY, accuracy: 1)
                    XCTAssertLessThan(start.frame.maxY, bounds.minY + 90)
                    let shortcuts = fixture.navigation.shortcutTargets(in: window)
                    XCTAssertEqual(shortcuts[.primary], ["export.start"])
                    XCTAssertEqual(shortcuts[.back], ["export.cancel"])
                    fixture.model.exportFor = game.id
                    fixture.navigation.focus("export.location"); fixture.navigation.handle(.back)
                    XCTAssertNil(fixture.model.exportFor, "B 与右下角取消执行相同的返回操作")
                    XCTAssertFalse(fixture.runner.requests.contains { $0["operation"] as? String == "export" }, "取消不应开始出包")
                    try self.snapshot(host, "export-actions-\(language.code)-\(Int(width))-\(connected ? "connected" : "disconnected")")
                }
            }
        }
    }

    func testExportSubmitShortcutUsesTheExistingExportAction() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        for platform in fixture.model.exportTargets where platform != .mac { fixture.model.toggleExport(platform) }
        if !fixture.model.exportTargets.contains(.mac) { fixture.model.toggleExport(.mac) }
        fixture.model.refresh()
        for _ in 0..<100 where fixture.model.games.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let game = try XCTUnwrap(fixture.model.games.first)
        fixture.model.exportFor = game.id
        let padFocus = PadFocus()
        let page = AnyView(ExportView(model: fixture.model, covers: CoverCache(), game: game, install: {})
            .environmentObject(padFocus).padScope("main", padFocus).frame(width: 1120, height: 630))
        let (_, window) = try await render(page, fixture: fixture, language: .zh)
        let navigation = fixture.navigation
        navigation.source.controllers = { [] }; navigation.attach(window); navigation.source.stop()
        navigation.source.isActive = { true }
        defer { navigation.detach(); window.close() }
        let snapshot = GCController.withExtendedGamepad()
        navigation.source.controllers = { [snapshot] }; navigation.source.tick(now: 0)
        navigation.focus("export.location")
        snapshot.extendedGamepad?.buttonMenu.setValue(1); navigation.source.tick(now: 0.1)
        for _ in 0..<100 where !fixture.runner.requests.contains(where: { $0["operation"] as? String == "export" }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(fixture.model.exportFor, "Menu 应与开始出包按钮执行同一操作")
        XCTAssertEqual(fixture.runner.requests.filter { $0["operation"] as? String == "export" }.count, 1)
        navigation.source.tick(now: 0.8)
        XCTAssertEqual(fixture.runner.requests.filter { $0["operation"] as? String == "export" }.count, 1, "长按不能重复开始出包")
    }

    func testTitlebarActionsAlignWithTheHomeControls() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.model.refresh()
        for _ in 0..<100 where fixture.model.games.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        fixture.model.gamepad.source.controllers = { [] }
        for language in [Lang.zh, .en] {
            for width: CGFloat in [800, 1120, 1440] {
                let page = AnyView(LauncherView(model: fixture.model, brand: "Original UI fixture").frame(width: width, height: 630))
                let (host, window) = try await render(page, fixture: fixture, language: language)
                defer { window.close() }
                let targets = fixture.model.gamepad.controlTargets(in: window)
                let report = try XCTUnwrap(targets.first { $0.id == "top.report" })
                let refresh = try XCTUnwrap(targets.first { $0.id == "home.refresh" })
                let bounds = window.convertToScreen(host.bounds)
                print("titlebar-right-edge \(language.code)/\(width): report=\(bounds.maxX - report.frame.maxX), home=\(bounds.maxX - refresh.frame.maxX)")
                XCTAssertEqual(report.frame.maxX, refresh.frame.maxX, accuracy: 0.5, "报修按钮应与游戏库控件共用右边缘")
                XCTAssertEqual(bounds.maxX - report.frame.maxX, 48, accuracy: 0.5)
                try snapshot(host, "titlebar-alignment-\(language.code)-\(Int(width))")
            }
        }
    }

    func testHomeSearchDismissesOutsideClicksAndFocusLossWithoutClearingTheQuery() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        let state = SearchControlState()
        let (host, window) = try await render(AnyView(SearchControlPreview(state: state)), fixture: fixture, language: .zh)
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        let navigation = fixture.navigation
        navigation.source.controllers = { [] }
        navigation.attach(window)
        defer { navigation.detach() }
        navigation.focus("home.search"); navigation.handle(.confirm)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(state.expanded)
        XCTAssertTrue(window.firstResponder is NSTextView, "展开后应聚焦原生输入框")
        state.query = "Original"
        try await Task.sleep(for: .milliseconds(80))
        let clear = try XCTUnwrap(navigation.controlTargets(in: window).first { $0.id == "home.search.clear" })
        let clearFrame = window.convertFromScreen(clear.frame)
        try click(CGPoint(x: clearFrame.midX, y: clearFrame.midY), in: window)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(state.expanded, "点击胶囊内的清空按钮不能收起")
        XCTAssertEqual(state.query, "")
        state.query = "Original"
        let outside = try XCTUnwrap(navigation.controlTargets(in: window).first { $0.id == "search-test.outside" })
        let outsideFrame = window.convertFromScreen(outside.frame)
        try click(CGPoint(x: outsideFrame.midX, y: outsideFrame.midY), in: window)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(state.expanded, "点击搜索框外应自动收起")
        XCTAssertEqual(state.outsideClicks, 1, "收起搜索不能吞掉外部按钮的点击")
        XCTAssertEqual(state.query, "Original", "自动收起应保留查询")
        state.expanded = true
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(window.makeFirstResponder(nil))
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(state.expanded, "键盘焦点移出搜索框后应自动收起")
        XCTAssertEqual(state.query, "Original")
        state.expanded = true
        try await Task.sleep(for: .milliseconds(350))
        try click(CGPoint(x: 20, y: 20), in: window)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(state.expanded, "点击非焦点控件的空白处也应收起")
        try snapshot(host, "home-search-dismissed")
    }

    func testCollapsedSearchIconDoesNotChangeWhenTheQueryIsNonempty() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        let state = SearchControlState()
        let (host, window) = try await render(AnyView(SearchControlPreview(state: state)), fixture: fixture, language: .zh)
        defer { window.close() }
        let target = try XCTUnwrap(fixture.navigation.controlTargets(in: window).first { $0.id == "home.search" })
        let rect = host.convert(window.convertFromScreen(target.frame), from: nil)
        func pixels() throws -> Data {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: rect))
            host.cacheDisplay(in: rect, to: bitmap)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        let empty = try pixels()
        state.query = "Original"
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try pixels(), empty, "收起时查询非空不能在放大镜上添加圆点")
        try snapshot(host, "home-search-query-without-badge")
    }

    private func click(_ point: CGPoint, in window: NSWindow) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            NSApp.sendEvent(event)
        }
    }

    func testHomeSearchExpandsInsideTheHomeWindowAndKeepsItsQuery() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.runner.catalogGameCount = 21
        fixture.model.refresh()
        for _ in 0..<100 where fixture.model.games.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let navigation = fixture.model.gamepad
        navigation.source.controllers = { [] }
        for language in [Lang.zh, .en] {
            for width: CGFloat in [800, 1000, 1120, 1440] {
                fixture.model.home.search = ""
                let page = AnyView(LauncherView(model: fixture.model, brand: "Original UI fixture").frame(width: width, height: 630))
                let (host, window) = try await render(page, fixture: fixture, language: language)
                navigation.attach(window)
                defer { navigation.detach(); window.close() }
                let initialWindows = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
                XCTAssertFalse(navigation.controlTargets(in: window).contains { $0.id == "home.filter" }, "首页不再显示重复的筛选按钮")
                navigation.focus("home.search"); navigation.handle(.confirm)
                try await Task.sleep(for: .milliseconds(350))
                let field = try XCTUnwrap(navigation.controlTargets(in: window).first { $0.id == "home.search.field" }, "搜索框应直接在首页展开")
                XCTAssertEqual(Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber)), initialWindows, "展开搜索不能创建 popup")
                XCTAssertTrue(window.convertToScreen(host.bounds).contains(field.frame))
                for id in ["home.search", "home.refresh", "library.sgradeUpgrade", "home.group.all", "home.group.ready", "home.group.recent", "home.group.favorites"] {
                    let control = try XCTUnwrap(navigation.controlTargets(in: window).first { $0.id == id })
                    XCTAssertTrue(window.convertToScreen(host.bounds).contains(control.frame), "\(language)/\(width): 展开后控件必须留在窗口内")
                    XCTAssertLessThanOrEqual(control.frame.height, 44, "\(language)/\(width): 首页控件不能被换行撑高")
                }
                fixture.model.home.search = "Original"
                try await Task.sleep(for: .milliseconds(80))
                try snapshot(host, "home-search-expanded-\(language.code)-\(Int(width))")
                navigation.focus("home.search"); navigation.handle(.confirm)
                try await Task.sleep(for: .milliseconds(350))
                XCTAssertFalse(navigation.controlTargets(in: window).contains { $0.id == "home.search.field" })
                XCTAssertEqual(fixture.model.home.search, "Original", "收起搜索保留筛选条件")
                navigation.focus("home.search"); navigation.handle(.confirm)
                try await Task.sleep(for: .milliseconds(350))
                navigation.focus("home.search.clear"); navigation.handle(.confirm)
                try await Task.sleep(for: .milliseconds(80))
                XCTAssertEqual(fixture.model.home.search, "")
                XCTAssertTrue(navigation.controlTargets(in: window).contains { $0.id == "home.search.field" }, "清空后保持展开")
                let groups = try ["all", "ready", "recent", "favorites"].map { id in
                    try XCTUnwrap(navigation.controlTargets(in: window).first { $0.id == "home.group." + id })
                }
                for pair in zip(groups, groups.dropFirst()) {
                    XCTAssertLessThanOrEqual(pair.0.frame.maxX, pair.1.frame.minX, "分组应按全部、已就绪、最近、收藏顺序排列")
                }
                navigation.focus("home.group.ready"); navigation.handle(.confirm)
                XCTAssertEqual(fixture.model.home.group.rawValue, "ready")
                fixture.model.home.group = .all
            }
        }
    }

    func testSigningSubcontentSharesTheParentRightEdge() async throws {
        let previous = UserDefaults.standard.object(forKey: S2ArmLauncherModel.teamCodeKey)
        UserDefaults.standard.set("fixture-team-id", forKey: S2ArmLauncherModel.teamCodeKey)
        defer { UserDefaults.standard.set(previous, forKey: S2ArmLauncherModel.teamCodeKey) }
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        for language in [Lang.zh, .en] {
            for width: CGFloat in [680, 820] {
                let page = AnyView(ScrollView { InstallModeCard(model: fixture.model).padding(32) }.frame(width: width, height: 700)
                    .background(LauncherWindowMaterial()).foregroundStyle(LauncherTheme.Colors.text).preferredColorScheme(.dark))
                let (host, window) = try await render(page, fixture: fixture, language: language)
                defer { window.close() }
                let controls = fixture.navigation.controlTargets(in: window)
                let parent = try XCTUnwrap(controls.first { $0.id == "env.installMode.device" })
                let identity = try XCTUnwrap(controls.first { $0.id == "export.sign.mode" })
                let delta = parent.frame.maxX - identity.frame.maxX
                print("signing-right-edge language=\(language.code) width=\(width) delta=\(delta)")
                XCTAssertEqual(delta, 0, accuracy: 0.5, "签名子布局右侧应与父选项对齐")
                try snapshot(host, "signing-right-edge-\(language.code)-\(Int(width))")
            }
        }
    }

    func testReadyGroupShowsEmptyStateAndCanReturnToAllGames() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.runner.catalogNeedsPreparation = true
        fixture.model.refresh()
        for _ in 0..<100 where fixture.model.games.first?.needsPreparation != true { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(fixture.model.games.count, 1)
        XCTAssertEqual(fixture.model.games.first?.needsPreparation, true)
        let navigation = fixture.model.gamepad
        navigation.source.controllers = { [] }
        for language in [Lang.zh, .en] {
            let page = AnyView(LauncherView(model: fixture.model, brand: "Original UI fixture").frame(width: 1120, height: 630))
            let (host, window) = try await render(page, fixture: fixture, language: language)
            navigation.attach(window)
            defer { navigation.detach(); window.close() }
            navigation.focus("home.group.ready"); navigation.handle(.confirm)
            try await Task.sleep(for: .milliseconds(120))
            XCTAssertEqual(fixture.model.home.group.rawValue, "ready")
            let targets = navigation.controlTargets(in: window)
            XCTAssertTrue(targets.contains { $0.id == "home.showAll" })
            XCTAssertFalse(targets.contains { $0.id.hasPrefix("card.") || $0.id.hasPrefix("hero.") })
            try snapshot(host, "home-ready-empty-\(language.code)")
            navigation.focus("home.showAll"); navigation.handle(.confirm)
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertEqual(fixture.model.home.group, .all)
            XCTAssertTrue(navigation.controlTargets(in: window).contains { $0.id == "card.fixture" }, "返回全部游戏后应恢复待准备的游戏卡片")
        }
    }

    func testSheetsFitCommonDisplayBudgets() {
        let displays: [(CGSize, CGSize)] = [
            (CGSize(width: 1440, height: 900), CGSize(width: 820, height: 700)),
            (CGSize(width: 1024, height: 720), CGSize(width: 820, height: 620)),
            (CGSize(width: 800, height: 600), CGSize(width: 736, height: 500))
        ]
        for (display, expected) in displays {
            let size = LauncherSheetSize.settings.fitted(to: display, height: 700)
            XCTAssertEqual(size.width, expected.width)
            XCTAssertEqual(size.height, expected.height)
        }
    }

    func testBackendDescriptionsAreConciseWhileLogsKeepTheirPunctuation() {
        let loc = Localizer(.zh)
        XCTAssertEqual(loc.backend("测试说明。"), "测试说明")
        XCTAssertEqual(loc.backendLine("▸ 测试说明。"), "▸ 测试说明。")
        XCTAssertEqual(loc.backend("等待中..."), "等待中...")
    }

    func testSigningGuideFailureIsReportedToTheCallingPage() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        var failure: Error?
        fixture.model.openSigningProject { failure = $0 }
        for _ in 0..<100 where failure == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(failure, "引导项目打开失败必须回到发起操作的设置页")
        XCTAssertNil(fixture.model.installError, "不能把设置页错误写进另一个安装弹窗")
    }

    func testLongConfirmationKeepsActionsOnScreen() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.model.refresh()
        for _ in 0..<100 where fixture.model.games.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(fixture.model.games.count, 1)
        for language in [Lang.zh, .en] {
            let page = AnyView(DownstreamConfirmSheet(model: fixture.model, gameID: "fixture", zh: language == .zh).frame(height: 500))
            let (host, window) = try await render(page, fixture: fixture, language: language)
            defer { window.close() }
            XCTAssertLessThanOrEqual(host.bounds.height, (NSScreen.main?.visibleFrame.height ?? 900) - 100,
                                     "长说明应在内容区滚动，不能将操作推出屏幕")
            let bounds = window.convertToScreen(host.bounds)
            for id in ["downstream.original", "downstream.recommend"] {
                let control = try XCTUnwrap(fixture.navigation.controlTargets(in: window).first { $0.id == id }, "长说明不能隐藏 \(id)")
                XCTAssertTrue(bounds.contains(control.frame), "操作必须位于窗口内")
            }
            try snapshot(host, "confirmation-long-\(language.code)")
        }
    }

    func testInterfaceDescriptionsDoNotEndInFullStops() throws {
        for (language, catalog) in L10n.catalogs {
            for (key, text) in catalog {
                XCTAssertFalse(text.hasSuffix("。") || text.hasSuffix("."), "\(language)/\(key): 说明末尾不加句号")
            }
        }
        for item in try GameSettingsSpec.macItems() {
            for language in ["zh-Hans", "en"] {
                let note = item.detail(language)
                XCTAssertFalse(note.hasSuffix("。") || note.hasSuffix("."), "\(item.id)/\(language)")
            }
        }
        let source = try GameSettingsSpec.url().deletingLastPathComponent().appendingPathComponent("experience.v1.json")
        let spec = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
        let launcher = try XCTUnwrap(spec["launcher"] as? [String: Any])
        for row in try XCTUnwrap(launcher["items"] as? [[String: Any]]) {
            for language in ["zh-Hans", "en"] {
                let text = try XCTUnwrap(row[language] as? String)
                XCTAssertFalse(text.hasSuffix("。") || text.hasSuffix("."), "\(row["id"] ?? "")/\(language)")
            }
        }
    }

    func testUpgradeActionsStayVisibleInAShortWindow() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        let games = (1...9).map { SGradeScanGame(["id": "original-\($0)", "name": "Original game \($0)", "program": "original", "total": 1, "iphone": true, "patches": ["fps": 1]]) }
        for language in [Lang.zh, .en] {
            let code = language == .zh ? "zh-Hans" : "en"
            let page = AnyView(SGradeUpgradeBody(games: games, failure: nil, zh: language == .zh, busy: false,
                x: { BackendText.launcherText("sgrade.upgrade." + $0, language: code) }, upgrade: { _ in }, close: {}).frame(height: 500))
            let (host, window) = try await render(page, fixture: fixture, language: language)
            defer { window.close() }
            let bounds = window.convertToScreen(host.bounds)
            let list = try XCTUnwrap(scrollViews(in: host).first { $0.hasVerticalScroller })
            XCTAssertGreaterThan(list.contentView.bounds.height, 60, "游戏列表不能被压成不可见的滚动区")
            XCTAssertGreaterThan(try XCTUnwrap(list.documentView).bounds.height, 100)
            for id in ["sgrade.upgrade.install", "sgrade.upgrade.export"] {
                let action = try XCTUnwrap(fixture.navigation.controlTargets(in: window).first { $0.id == id }, "升级操作必须始终可见")
                XCTAssertTrue(bounds.contains(action.frame))
            }
            try snapshot(host, "upgrade-short-\(language.code)")
        }
    }

    func testUpgradeRowsAndConfirmationUseConsistentAlignment() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        let games = [
            SGradeScanGame(["id": "alpha", "name": "Original Alpha", "program": "original", "total": 4,
                            "patches": ["widescreen": 1, "fps": 1, "gfx": 1, "cheat": 1]]),
            SGradeScanGame(["id": "beta", "name": "Original Beta", "program": "original", "total": 3,
                            "patches": ["widescreen": 1, "fps": 1, "gfx": 1]])
        ]
        for language in [Lang.zh, .en] {
            let code = language == .zh ? "zh-Hans" : "en"
            let page = AnyView(SGradeUpgradeBody(games: games, failure: nil, zh: language == .zh, busy: false,
                x: { BackendText.launcherText("sgrade.upgrade." + $0, language: code) }, upgrade: { _ in }, close: {}))
            let (host, window) = try await render(page, fixture: fixture, language: language)
            defer { window.close() }
            let bounds = window.convertToScreen(host.bounds)
            let actions = fixture.navigation.controlTargets(in: window)
            XCTAssertEqual(actions.count, 1)
            let button = try XCTUnwrap(actions.first)
            print("upgrade-footer \(language.code): bottom=\(button.frame.minY - bounds.minY), right=\(bounds.maxX - button.frame.maxX)")
            XCTAssertEqual(button.frame.minY - bounds.minY, 16, accuracy: 1, "升级弹窗应使用与设置页一致的 16 pt 底边距")
            XCTAssertEqual(bounds.maxX - button.frame.maxX, 32, accuracy: 1)
            let document = try XCTUnwrap(scrollViews(in: host).first?.documentView)
            let bitmap = try XCTUnwrap(document.bitmapImageRepForCachingDisplay(in: document.bounds))
            document.cacheDisplay(in: document.bounds, to: bitmap)
            // Only the two gray descriptions occupy the right half; the title and names are on the left.
            var rows: [(firstY: Int, lastY: Int, minX: Int)] = []
            for y in 0..<bitmap.pixelsHigh {
                var first: Int?
                for x in (bitmap.pixelsWide / 2)..<bitmap.pixelsWide {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       min(color.redComponent, color.greenComponent, color.blueComponent) > 0.4 {
                        first = x; break
                    }
                }
                if let first {
                    if let last = rows.last, y - last.lastY <= 4 {
                        rows[rows.count - 1] = (last.firstY, y, min(last.minX, first))
                    } else { rows.append((y, y, first)) }
                }
            }
            rows = rows.filter { $0.lastY - $0.firstY >= 4 } // Ignore the thin row separator.
            XCTAssertEqual(rows.count, 2, "应能从实际渲染结果中找到两行优化说明")
            if rows.count == 2 {
                print("upgrade-description-left \(language.code): \(rows.map(\.minX))")
                XCTAssertEqual(rows[0].minX, rows[1].minX, accuracy: 2, "右侧说明文字应共用左边界")
            }
            try snapshot(host, "upgrade-aligned-\(language.code)")
        }
    }

    func testExportPageSharesTheHomeHorizontalInsets() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.model.refresh()
        for _ in 0..<100 where fixture.model.games.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let game = try XCTUnwrap(fixture.model.games.first)
        for language in [Lang.zh, .en] {
            for width: CGFloat in [800, 1120, 1440] {
                let padFocus = PadFocus()
                let page = AnyView(ExportView(model: fixture.model, covers: CoverCache(), game: game, install: {})
                    .environmentObject(padFocus).padScope("main", padFocus)
                    .background(LauncherWindowMaterial()).foregroundStyle(LauncherTheme.Colors.text).preferredColorScheme(.dark)
                    .frame(width: width, height: 630))
                let (host, window) = try await render(page, fixture: fixture, language: language)
                defer { window.close() }
                let bounds = window.convertToScreen(host.bounds)
                let targets = fixture.navigation.controlTargets(in: window)
                let cover = try XCTUnwrap(targets.first { $0.id == "export.cover" })
                let start = try XCTUnwrap(padFocus.frames["main"]?.first { $0.id == "export.start" })
                print("export-insets \(language.code)/\(width): left=\(cover.frame.minX - bounds.minX), right=\(width - start.frame.maxX)")
                XCTAssertEqual(cover.frame.minX - bounds.minX, 48, accuracy: 1, "出包内容应与游戏库的 48 pt 内边距对齐")
                XCTAssertEqual(width - start.frame.maxX, 48, accuracy: 1, "底栏操作应与内容右边缘对齐")
                XCTAssertTrue(bounds.contains(cover.frame))
                XCTAssertTrue(CGRect(x: 0, y: 0, width: width, height: 630).contains(start.frame))
                try snapshot(host, "export-full-width-\(language.code)-\(Int(width))")
            }
        }
    }

    func testInstallRepairActionsShareOneColumnInBothLanguages() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.model.checkInstall("fixture")
        for _ in 0..<100 where fixture.model.installReadiness == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(fixture.model.installReadiness)
        for language in [Lang.zh, .en] {
            let (host, window) = try await render(AnyView(InstallView(model: fixture.model, gameID: "fixture")), fixture: fixture, language: language)
            defer { window.close() }
            let targets = fixture.navigation.controlTargets(in: window)
            let settings = try XCTUnwrap(targets.first { $0.id == "install.goSettings" })
            let xcode = try XCTUnwrap(targets.first { $0.id == "install.openXcode" })
            XCTAssertEqual(settings.frame.width, 106, accuracy: 1)
            XCTAssertEqual(xcode.frame.width, 106, accuracy: 1)
            XCTAssertEqual(settings.frame.union(xcode.frame).width, 220, accuracy: 1)
            XCTAssertEqual(settings.frame.midY, xcode.frame.midY, accuracy: 1)
            XCTAssertTrue(window.convertToScreen(host.bounds).contains(settings.frame.union(xcode.frame)))
            try snapshot(host, "install-repair-\(language.code)")
        }
    }

    func testSettingsPagesHaveRoomForDescriptionAndControls() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        for language in [Lang.zh, .en] {
            let pages: [(String, AnyView)] = [
                ("settings", AnyView(EnvironmentView(model: fixture.model))),
                ("launch", AnyView(LaunchSettingsSheet(model: fixture.model, gameID: "fixture"))),
                ("input", AnyView(InputSettingsSheet(model: fixture.model, gameID: "fixture")))
            ]
            for (name, page) in pages {
                let (host, window) = try await render(page, fixture: fixture, language: language)
                defer { window.close() }
                // 780 pt leaves >= 380 pt for prose beside a 220 pt control, card insets and page margins.
                XCTAssertGreaterThanOrEqual(host.bounds.width, 780, "\(name)/\(language.code): 设置页应有舒适的阅读宽度")
                try snapshot(host, "\(name)-\(language.code)")
            }
        }
    }

    func testLaunchChoicesAndActionsHaveTheSameTrailingEdge() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        for language in [Lang.zh, .en] {
            let (host, window) = try await render(AnyView(LaunchSettingsSheet(model: fixture.model, gameID: "fixture")),
                                                fixture: fixture, language: language)
            defer { window.close() }
            let targets = fixture.navigation.controlTargets(in: window)
            let action = try XCTUnwrap(targets.first { $0.id == "launch.input" }, "手柄设置入口必须可操作")
            let choice = try XCTUnwrap(targets.first { $0.id == "launch.rumbleLevel" }, "震动强度必须可操作")
            XCTAssertEqual(choice.frame.maxX, action.frame.maxX, accuracy: 1,
                           "\(language.code): 下拉框不能越过同列按钮的右边界")
            XCTAssertEqual(choice.frame.width, action.frame.width, accuracy: 1,
                           "\(language.code): 同列下拉框与按钮等宽")
            let content = window.convertToScreen(host.bounds)
            XCTAssertLessThanOrEqual(choice.frame.maxX, content.maxX - 40, "控件与弹窗右缘保持安全边距")
        }
    }

    func testSettingsActionsShareOneColumnAndDropdownStaysInItsWindow() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        let previous = UserDefaults.standard.object(forKey: "appLanguage")
        defer { UserDefaults.standard.set(previous, forKey: "appLanguage") }
        for language in [Lang.zh, .en] {
            let (host, window) = try await render(AnyView(EnvironmentView(model: fixture.model)), fixture: fixture, language: language)
            fixture.navigation.source.controllers = { [] }
            fixture.navigation.attach(window)
            defer { fixture.navigation.detach(); window.close() }
            let targets = fixture.navigation.controlTargets(in: window)
            let open = try XCTUnwrap(targets.first { $0.id == "settings.library.open" })
            let change = try XCTUnwrap(targets.first { $0.id == "settings.library.change" })
            let picker = try XCTUnwrap(targets.first { $0.id == "settings.language" })
            XCTAssertEqual(open.frame.height, 36, accuracy: 0.5)
            XCTAssertEqual(change.frame.height, 36, accuracy: 0.5)
            XCTAssertEqual(picker.frame.height, 36, accuracy: 0.5)
            XCTAssertEqual(change.frame.maxX, picker.frame.maxX, accuracy: 1)
            XCTAssertEqual(change.frame.maxX - open.frame.minX, 220, accuracy: 1,
                           "两个操作共用 220 pt，不能挤占说明区域")
            fixture.navigation.focus("settings.language"); fixture.navigation.handle(.confirm)
            try await Task.sleep(for: .milliseconds(100))
            let options = fixture.navigation.controlTargets(in: window).filter { $0.id.hasPrefix("dropdown.") }
            XCTAssertEqual(options.count, 3, "下拉列表必须显示在当前设置窗口内")
            let bounds = window.convertToScreen(host.bounds)
            for option in options { XCTAssertTrue(bounds.insetBy(dx: -1, dy: -1).contains(option.frame)) }
            fixture.navigation.focus("dropdown." + language.code); fixture.navigation.handle(.confirm)
            for _ in 0..<20 where fixture.navigation.controlTargets(in: window).contains(where: { $0.id.hasPrefix("dropdown.") }) {
                try await Task.sleep(for: .milliseconds(30))
            }
            XCTAssertFalse(fixture.navigation.controlTargets(in: window).contains { $0.id.hasPrefix("dropdown.") }, "选择后恢复页面操作")
        }
    }

    func testStoredTeamIdDoesNotPreventCollapsingTheGuide() async throws {
        let previous = UserDefaults.standard.object(forKey: S2ArmLauncherModel.teamCodeKey)
        UserDefaults.standard.set("fixture-team-id", forKey: S2ArmLauncherModel.teamCodeKey)
        defer { UserDefaults.standard.set(previous, forKey: S2ArmLauncherModel.teamCodeKey) }
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        let page = AnyView(ScrollView { InstallModeCard(model: fixture.model).padding(32) }.launcherSheet())
        let (host, window) = try await render(page, fixture: fixture, language: .zh)
        fixture.navigation.source.controllers = { [] }; fixture.navigation.attach(window)
        defer { fixture.navigation.detach(); window.close() }
        XCTAssertTrue(fixture.navigation.controlTargets(in: window).contains { $0.id == "env.teamGuideOpen" })
        try snapshot(host, "signing-guide-expanded-zh")
        fixture.navigation.focus("env.teamManual"); fixture.navigation.handle(.confirm)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(fixture.navigation.controlTargets(in: window).contains { $0.id == "env.teamGuideOpen" }, "保存过 Team ID 也应能收起引导")
        fixture.navigation.focus("env.teamManual"); fixture.navigation.handle(.confirm)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(fixture.navigation.controlTargets(in: window).contains { $0.id == "env.teamGuideOpen" })
        XCTAssertEqual(UserDefaults.standard.string(forKey: S2ArmLauncherModel.teamCodeKey), "fixture-team-id")
    }

    func testKeyboardClearIsSeparateFromRecordAndSavesOnlyThatBinding() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        let (_, window) = try await render(AnyView(InputSettingsSheet(model: fixture.model, gameID: "fixture")), fixture: fixture, language: .en)
        fixture.navigation.source.controllers = { [] }; fixture.navigation.attach(window)
        defer { fixture.navigation.detach(); window.close() }
        let targets = fixture.navigation.controlTargets(in: window)
        let record = try XCTUnwrap(targets.first { $0.id == "input.keyboard.record" })
        let clear = try XCTUnwrap(targets.first { $0.id == "input.keyboard.clear" })
        XCTAssertEqual(record.frame.height, 36, accuracy: 1)
        XCTAssertEqual(clear.frame.width, 36, accuracy: 1)
        XCTAssertEqual(clear.frame.height, 36, accuracy: 1)
        XCTAssertLessThanOrEqual(record.frame.maxX, clear.frame.minX + 0.5, "清除与录入是两个独立点击区域")
        fixture.navigation.focus("input.keyboard.clear"); fixture.navigation.handle(.confirm)
        try await Task.sleep(for: .milliseconds(50))
        fixture.navigation.focus("input.save"); fixture.navigation.handle(.confirm)
        for _ in 0..<50 where !fixture.runner.requests.contains(where: { $0["operation"] as? String == "saveInput" }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let request = try XCTUnwrap(fixture.runner.requests.first { $0["operation"] as? String == "saveInput" })
        let keyboard = try XCTUnwrap((request["config"] as? [String: Any])?["keyboard"] as? [String: Any])
        XCTAssertNil(keyboard["A"], "清除 A 后保存的配置不能保留旧绑定")
        XCTAssertEqual((keyboard["B"] as? [String: Any])?["code"] as? Int, 56, "B 的 Shift 绑定保持原样")
    }

    func testSliderAdjustsWithControllersAndHonorsDisabledState() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        let value = LayoutSliderValue()
        for enabled in [true, false] {
            let preview = AnyView(LayoutSliderPreview(value: value, enabled: enabled).padding(32).launcherSheet(.compact, height: 160))
            let (_, window) = try await render(preview, fixture: fixture, language: .en)
            fixture.navigation.source.controllers = { [] }; fixture.navigation.attach(window)
            defer { fixture.navigation.detach(); window.close() }
            let target = fixture.navigation.controlTargets(in: window).first { $0.id == "preview.slider" }
            if enabled {
                XCTAssertEqual(try XCTUnwrap(target).frame.height, 36, accuracy: 1)
                fixture.navigation.focus("preview.slider"); fixture.navigation.handle(.right)
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertEqual(value.value, 0.6, accuracy: 0.0001)
                fixture.navigation.handle(.left)
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertEqual(value.value, 0.5, accuracy: 0.0001)
            } else {
                XCTAssertNil(target, "禁用滑块不能接收手柄调整")
                fixture.navigation.focus("preview.slider"); fixture.navigation.handle(.right)
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertEqual(value.value, 0.5, accuracy: 0.0001)
            }
        }
    }

    func testInputAxisControlsFitTheSharedColumnAfterScrolling() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        for language in [Lang.zh, .en] {
            let (host, window) = try await render(AnyView(InputSettingsSheet(model: fixture.model, gameID: "fixture")), fixture: fixture, language: language)
            defer { window.close() }
            let scroll = try XCTUnwrap(scrollViews(in: host).first { $0.hasVerticalScroller })
            let document = try XCTUnwrap(scroll.documentView)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let targets = fixture.navigation.controlTargets(in: window)
            for axis in InputConfig.axisTargets {
                let choice = try XCTUnwrap(targets.first { $0.id == "input.axis.source." + axis })
                let invert = try XCTUnwrap(targets.first { $0.id == "input.axis.invert." + axis })
                XCTAssertEqual(choice.frame.width, 124, accuracy: 1, "来源选择与反向开关必须共用 220 pt 操作列")
                XCTAssertEqual(choice.frame.maxX, window.convertToScreen(host.bounds).maxX - 52, accuracy: 1)
                XCTAssertEqual(choice.frame.union(invert.frame).width, 172, accuracy: 1)
            }
            try snapshot(host, "input-axes-\(language.code)")
        }
    }

    func testAllUtilitySheetsRenderWithContainedControlsInBothLanguages() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.model.messages = [["id": "original-message", "text": ["zh-Hans": "原创界面检查消息", "en": "Original interface review message"]]]
        fixture.model.refresh()
        for _ in 0..<100 where fixture.model.games.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        for language in [Lang.zh, .en] {
            let uiLanguage = language == .zh ? "zh-Hans" : "en"
            fixture.model.updatePopup = ["kind": "available", "version": "1.0.0", "notes": ["sections": [
                ["title": "UI", "items": [["zh-Hans": "统一设置界面", "en": "Consistent settings"]]]]]]
            let pages: [(String, AnyView)] = [
                ("settings", AnyView(EnvironmentView(model: fixture.model))),
                ("launch-settings", AnyView(LaunchSettingsSheet(model: fixture.model, gameID: "fixture"))),
                ("input-settings", AnyView(InputSettingsSheet(model: fixture.model, gameID: "fixture"))),
                ("downstream", AnyView(DownstreamConfirmSheet(model: fixture.model, gameID: "fixture", zh: language == .zh))),
                ("storage", AnyView(FreeSpaceView(model: fixture.model, gameID: "fixture"))),
                ("saves", AnyView(SaveManageSheet(model: fixture.model, gameID: "fixture"))),
                ("certificate", AnyView(DevCertSheet(model: fixture.model))),
                ("import-games", AnyView(ImportSheet(model: fixture.model, kind: .games))),
                ("import-keys", AnyView(ImportSheet(model: fixture.model, kind: .keys))),
                ("install", AnyView(InstallView(model: fixture.model, gameID: "fixture"))),
                ("update", AnyView(UpdatePopupView(model: fixture.model, language: uiLanguage))),
                ("messages", AnyView(MessagesPanel(model: fixture.model, language: uiLanguage))),
                ("diagnostics", AnyView(UploadDiagnosticsSheet(model: fixture.model, gameID: nil, operations: nil, fallback: "") {})),
                ("upgrade", AnyView(SGradeUpgradeBody(games: [], failure: nil, zh: language == .zh, busy: false,
                    x: { BackendText.launcherText("sgrade.upgrade." + $0, language: uiLanguage) }, upgrade: { _ in }, close: {})))
            ]
            for (name, page) in pages {
                let (host, window) = try await render(page, fixture: fixture, language: language)
                for connected in [false, true] {
                    fixture.navigation.presentation.connected = connected
                    try await Task.sleep(for: .milliseconds(70))
                    let bounds = window.convertToScreen(host.bounds)
                    XCTAssertLessThanOrEqual(host.bounds.height, (NSScreen.main?.visibleFrame.height ?? 900) - 100,
                                             "\(name)/\(language.code): 弹层必须适合屏幕")
                    if name == "update" || name == "messages" {
                        let reading = try XCTUnwrap(scrollViews(in: host).first { $0.hasVerticalScroller })
                        XCTAssertGreaterThan(reading.contentView.bounds.height, 40, "\(name): 说明列表必须有可见空间")
                    }
                    for target in fixture.navigation.controlTargets(in: window) {
                        XCTAssertTrue(bounds.insetBy(dx: -1, dy: -1).contains(target.frame),
                                      "\(name)/\(language.code): 控件溢出 \(target.id) \(target.frame), \(bounds)")
                    }
                    if name != "messages" {
                        let shortcuts = fixture.navigation.shortcutTargets(in: window)
                        XCTAssertFalse(shortcuts.isEmpty, "\(name)/\(language.code)：弹窗底栏必须登记手柄快捷键")
                        for (key, ids) in shortcuts {
                            XCTAssertEqual(ids.count, 1, "\(name)/\(language.code)：同一按键不能同时触发多个底栏按钮：\(key) \(ids)")
                        }
                        if !["downstream", "import-games", "import-keys"].contains(name) {
                            XCTAssertNotNil(shortcuts[.back], "\(name)：必须能用 B 关闭或取消")
                        }
                    }
                    try snapshot(host, "\(name)-\(language.code)-\(connected ? "connected" : "disconnected")")
                }
                window.close()
            }
            for feature in [false, true] {
                fixture.model.updatePopup = feature
                    ? ["kind": "feature", "pages": [["title": ["zh-Hans": "原创说明", "en": "Original guide"]], ["title": ["zh-Hans": "第二页", "en": "Second page"]]]]
                    : ["kind": "afterUpdate", "version": "1.0.0", "notes": [:]]
                let page = feature ? AnyView(FeatureSpotlightView(model: fixture.model, language: uiLanguage))
                    : AnyView(UpdatePopupView(model: fixture.model, language: uiLanguage))
                let (host, window) = try await render(page, fixture: fixture, language: language)
                for connected in [false, true] {
                    fixture.navigation.presentation.connected = connected
                    try await Task.sleep(for: .milliseconds(70))
                    let keys = fixture.navigation.shortcutTargets(in: window)
                    XCTAssertEqual(keys[.primary]?.count, 1)
                    XCTAssertEqual(keys[.back]?.count, 1)
                    try snapshot(host, (feature ? "feature-" : "updated-") + language.code + (connected ? "-connected" : "-disconnected"))
                }
                window.close()
            }
        }
    }

    private func render(_ page: AnyView, fixture: SettingsFixture, language: Lang) async throws -> (NSView, NSWindow) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: page.environmentObject(Localizer(language))
            .environment(\.padControls, fixture.navigation).environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 80, y: 80), size: host.fittingSize),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        if let scroll = view as? NSScrollView { return [scroll] }
        return view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func snapshot(_ host: NSView, _ name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["S2A_SETTINGS_SHOTS"] else { return }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
    }
}

@MainActor private final class SearchControlState: ObservableObject {
    @Published var expanded = false
    @Published var query = ""
    var outsideClicks = 0
}

private struct SearchControlPreview: View {
    @ObservedObject var state: SearchControlState
    var body: some View {
        HStack {
            Spacer()
            Button("Outside") { state.outsideClicks += 1 }
                .controllerButtonStyle(.plain).controllerID("search-test.outside")
            HomeSearchControl(isExpanded: $state.expanded, text: $state.query, width: 300, edit: {})
        }
        .padding(30).frame(width: 600, height: 120).background(Color.black)
    }
}

@MainActor private final class SettingsFixture {
    let root: URL
    let model: S2ArmLauncherModel
    let navigation = LauncherPadNavigation()
    let runner = SettingsRunner()
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-settings-layout-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("library"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
        model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(privateRoot: root, resources: root,
            library: root.appendingPathComponent("library").path, libraryId: "layout-fixture"), runner: runner))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class SettingsRunner: JobProcessRunner {
    final class Handle: JobProcessHandle { func terminate() {} }
    private let lock = NSLock()
    private var captured: [[String: Any]] = []
    private var gameCount = 1
    private var needsPreparation = false
    private var cover = ""
    private var storage: [String: Any] = [:]
    var storageResponse: [String: Any] {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
    var catalogNeedsPreparation: Bool {
        get { lock.withLock { needsPreparation } }
        set { lock.withLock { needsPreparation = newValue } }
    }
    var catalogCover: String {
        get { lock.withLock { cover } }
        set { lock.withLock { cover = newValue } }
    }
    var catalogGameCount: Int {
        get { lock.withLock { gameCount } }
        set { lock.withLock { gameCount = newValue } }
    }
    var requests: [[String: Any]] { lock.withLock { captured } }
    func start(executable: URL, arguments: [String], environment: [String: String], onLine: @escaping (Data) -> Void,
               onStderr: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        let request = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments.last!))) as! [String: Any]
        lock.withLock { captured.append(request) }
        var result: [String: Any] = [:]
        if request["operation"] as? String == "locations" { result = storageResponse }
        if request["operation"] as? String == "catalog" {
            let copy: [String: Any] = [
                "zh": ["title": "选择运行方案", "body": "以下为原创布局说明，用于验证长内容滚动", "points": (1...24).map { "原创说明第 \($0) 项：此处展示较长的方案说明，以检查窗口与底部操作的边界" },
                       "recommend": "使用推荐方案", "original": "使用原版方案"],
                "en": ["title": "Choose a configuration", "body": "Original layout fixture for long content", "points": (1...24).map { "Original item \($0): a longer configuration description to verify scrolling and keep the actions visible" },
                       "recommend": "Use recommended", "original": "Use original"]]
            result = ["games": (0..<catalogGameCount).map { index in
                ["id": index == 0 ? "fixture" : "fixture-\(index)", "name": "Original UI fixture \(index)", "cover": catalogCover, "ready": true, "needsPreparation": catalogNeedsPreparation, "missing": [],
                 "downstream": ["id": "original-demo", "name": "Original Demo", "eligible": true, "copy": copy]] as [String: Any]
            }]
        }
        if request["operation"] as? String == "community" {
            var options: [String: Any] = [:]
            for item in try GameSettingsSpec.macItems() {
                options[item.id] = ["available": true, "hidden": item.group != "controls",
                                    "value": item.type == "choice" ? (item.options.first?.value ?? "") : true]
            }
            result = ["mac": options, "graphics": [], "cheats": ["items": []]]
        }
        if request["operation"] as? String == "installMode" { result = ["mode": "device"] }
        if request["operation"] as? String == "installCheck" {
            result = ["ready": true, "items": [["id": "appleId", "title": "Apple ID", "detail": "请在 Xcode 登录 Apple ID", "ok": false]]]
        }
        if request["operation"] as? String == "preflight" {
            result = ["checks": [["id": "xcode", "name": "Xcode", "ok": true, "group": "apple", "requiredFor": ["prepare", "launch", "ipa"]]]]
        }
        if request["operation"] as? String == "saveStatus" {
            result = ["hasSave": true, "fileCount": 3, "totalBytes": 20480]
        }
        if request["operation"] as? String == "spaceSurvey" {
            result = ["games": [["gameId": "fixture", "name": "Original UI fixture", "parts": [
                ["id": "shaders", "title": "着色器缓存", "rebuild": "下次启动时重新生成", "bytes": 1048576]],
                "kept": [["id": "saves", "bytes": 20480]]]]]
        }
        let failed = request["operation"] as? String == "signingProject"
        let event: [String: Any] = ["schema": 1, "taskId": request["taskId"] ?? "", "type": "result",
                                  "state": failed ? "failed" : "succeeded", "result": result,
                                  "message": failed ? "原创测试：引导项目暂不可用" : "", "code": failed ? "tool_missing" : ""]
        let data = try JSONSerialization.data(withJSONObject: event)
        DispatchQueue.main.async { onLine(data); onExit(0) }
        return Handle()
    }
}

@MainActor private final class LayoutSliderValue: ObservableObject {
    @Published var value = 0.5
}
private struct LayoutSliderPreview: View {
    @ObservedObject var value: LayoutSliderValue
    let enabled: Bool
    var body: some View {
        LauncherSlider(value: value.value, range: 0...1, step: 0.1) { value.value = $0 }
            .frame(width: 220).controllerID("preview.slider").disabled(!enabled)
    }
}
