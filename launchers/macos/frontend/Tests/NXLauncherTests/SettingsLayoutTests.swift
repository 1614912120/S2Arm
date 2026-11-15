// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import SwiftUI
import XCTest
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter
@testable import NX2AppleUI

/// Real SwiftUI pages with original, asset-free job responses; never reads the player's library.
@MainActor final class SettingsLayoutTests: XCTestCase {
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
                for id in ["home.search", "home.refresh", "library.sgradeUpgrade", "home.group.all", "home.group.recent", "home.group.favorites"] {
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
        fixture.model.updatePopup = ["kind": "available", "version": "1.0.0", "notes": ["sections": [
            ["title": "UI", "items": [["zh-Hans": "统一设置界面", "en": "Consistent settings"]]]]]]
        fixture.model.messages = [["id": "original-message", "text": ["zh-Hans": "原创界面检查消息", "en": "Original interface review message"]]]
        for language in [Lang.zh, .en] {
            let uiLanguage = language == .zh ? "zh-Hans" : "en"
            let pages: [(String, AnyView)] = [
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
                try snapshot(host, "\(name)-\(language.code)")
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
        if request["operation"] as? String == "catalog" {
            let copy: [String: Any] = [
                "zh": ["title": "选择运行方案", "body": "以下为原创布局说明，用于验证长内容滚动", "points": (1...24).map { "原创说明第 \($0) 项：此处展示较长的方案说明，以检查窗口与底部操作的边界" },
                       "recommend": "使用推荐方案", "original": "使用原版方案"],
                "en": ["title": "Choose a configuration", "body": "Original layout fixture for long content", "points": (1...24).map { "Original item \($0): a longer configuration description to verify scrolling and keep the actions visible" },
                       "recommend": "Use recommended", "original": "Use original"]]
            result = ["games": (0..<catalogGameCount).map { index in
                ["id": index == 0 ? "fixture" : "fixture-\(index)", "name": "Original UI fixture \(index)", "ready": true, "missing": [],
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
