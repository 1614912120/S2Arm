// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import GameController
import SwiftUI
import XCTest
import NXLauncher
@testable import NX2AppleUI

@MainActor final class ControllerPopoverLayoutTests: XCTestCase {
    func testSystemSnapshotHonorsConnectionEventsAndDeviceIdentity() {
        let dualSense = PopoverLayoutController("DualSense Wireless Controller")
        let xbox = PopoverLayoutController("Xbox Wireless Controller")
        XCTAssertEqual(SystemControllers.snapshot([], connected: dualSense).map(\.id), [ObjectIdentifier(dualSense)], "连接通知先于枚举列表时也要显示新设备")
        XCTAssertEqual(SystemControllers.snapshot([dualSense, xbox], disconnected: dualSense).map(\.id), [ObjectIdentifier(xbox)], "断开通知必须移除滞后枚举里的设备，保留其他手柄")
        XCTAssertEqual(SystemControllers.snapshot([dualSense, dualSense], connected: dualSense).count, 1, "枚举和连接通知指向同一设备时只列一次")
        let other = PopoverLayoutController("DualSense Wireless Controller")
        XCTAssertEqual(SystemControllers.snapshot([dualSense, other]).count, 2, "同名的两只实际设备各自保留")
        let switchPad = PopoverLayoutController("Nintendo Switch 2 Pro Controller")
        XCTAssertTrue(SystemControllers.snapshot([switchPad], connected: switchPad).isEmpty, "专用通道设备不重复列入系统手柄")
    }

    func testSystemConnectionDoesNotInheritSwitchHelperFailures() throws {
        let pad = PopoverLayoutController("DualSense Wireless Controller")
        let suite = "s2arm-connection-presentation-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let order = FileManager.default.temporaryDirectory.appendingPathComponent(suite + ".json")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: order) }
        let controller = NS2LauncherController(socketURL: URL(fileURLWithPath: "/tmp/" + suite + ".sock"), store: defaults,
            orderFile: order, systemControllers: { [pad] }, notifications: NotificationCenter())
        let systems = SystemControllers(pads: [.init(id: ObjectIdentifier(pad), name: "DualSense Wireless Controller", family: .playstation)])
        for zh in [true, false] {
            for phase in [NS2LauncherController.Phase.off, .scanning, .connecting, .failed] {
                controller.setPhaseForTesting(phase)
                // Switch 2 区块与蓝牙区块常驻、各讲各的通道：Switch 的失败只落在 Switch 2 区块，不借 DualSense 的名字
                XCTAssertNotEqual(controller.switch2Title(lang: zh ? "zh" : "en"), "DualSense Wireless Controller",
                                  "Switch 的 \(phase) 不能借用 DualSense 的名字")
                XCTAssertEqual(controller.title(lang: zh ? "zh" : "en"), "DualSense Wireless Controller")
                XCTAssertEqual(controller.buttonStatus, "已连接")
            }
            controller.apply(status: 4, ["status": 4, "kind": 1, "players": 1, "devices": [["kind": 1, "id": "fixture-switch"]]])
            XCTAssertEqual(controller.switch2Title(lang: zh ? "zh" : "en"), "Switch 2 Pro", "混连时 Switch 2 区块写自己的手柄")
            XCTAssertEqual(controller.status, .connected)
            controller.setPhaseForTesting(.handedOff)
            XCTAssertEqual(controller.status, .inUse)
            controller.apply(status: 0, ["status": 0, "kind": 0, "devices": []])
            controller.setPhaseForTesting(.off)
            let another = NSObject()
            let two = SystemControllers(pads: systems.pads + [.init(id: ObjectIdentifier(another), name: "DualSense Wireless Controller", family: .playstation)])
            XCTAssertEqual(controller.switch2Title(lang: zh ? "zh" : "en"), "Joy-Con 2 · Pro 2", "空闲的 Switch 2 区块不能借用系统手柄名称")
        }
    }

    func testLongControllerNamesPreservePanelInsets() async throws {
        _ = NSApplication.shared
        for name in ["DualSense Wireless Controller", "DualSense Edge Wireless Controller — A deliberately long device name"] {
            for zh in [true, false] {
                let pad = PopoverLayoutController(name)
                let suite = "s2arm-popover-layout-" + UUID().uuidString
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                let order = FileManager.default.temporaryDirectory.appendingPathComponent(suite + ".json")
                let controller = NS2LauncherController(socketURL: URL(fileURLWithPath: "/tmp/" + suite + ".sock"), store: defaults,
                    orderFile: order, systemControllers: { [pad] }, notifications: NotificationCenter())
                let systems = SystemControllers(pads: [.init(id: ObjectIdentifier(pad), name: name, family: .playstation)])
                controller.updateSystem(systems.presentKeys)
                let navigation = LauncherPadNavigation()
                let host = NSHostingView(rootView: Switch2ProConnectionPopover(controller: controller, systems: systems, lang: zh ? "zh" : "en")
                    .environment(\.padControls, navigation))
                let size = host.fittingSize
                let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 100, y: 100), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
                defer {
                    window.close(); defaults.removePersistentDomain(forName: suite)
                    try? FileManager.default.removeItem(at: order)
                }
                host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(80))
                let frames = navigation.controlTargets(in: window).map { window.convertFromScreen($0.frame) }
                XCTAssertEqual(Set(navigation.controlTargets(in: window).map(\.id)), ["controller.settings", "controller.system.settings", "controller.player.0", "controller.assign",
                    "controller.face.0", "controller.face.1", "controller.face.2", "controller.face.3", "controller.face.switch", "controller.face.reset"],
                               "Switch 2 连接 / 断开不给手柄按（只给鼠标）；齿轮、蓝牙设置、玩家选择、四键映射与分配玩家")
                XCTAssertEqual(host.bounds.width, 380, accuracy: 0.5)
                XCTAssertGreaterThanOrEqual(frames.count, 2, "必须测到齿轮和蓝牙设置按钮")
                print("popover-insets name=\(name) zh=\(zh) width=\(host.bounds.width) frames=\(frames)")
                for frame in frames {
                    XCTAssertGreaterThanOrEqual(frame.minX, 19.5, "\(name): 内容左侧必须保留 20 pt，不能被长标题挤出")
                    XCTAssertLessThanOrEqual(frame.maxX, 360.5, "\(name): 内容右侧必须保留 20 pt")
                }
                if let output = ProcessInfo.processInfo.environment["S2A_SNAPSHOT_OUT"], name == "DualSense Wireless Controller", zh {
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: output).appendingPathComponent("controller-popover.png"))
                }
                if name == "DualSense Wireless Controller", zh {
                    navigation.source.controllers = { [] }
                    navigation.attach(window)
                    defer { navigation.detach() }
                    controller.setAssignmentForTesting(.init())
                    try await Task.sleep(for: .milliseconds(100))
                    let shortcuts = navigation.shortcutTargets(in: window)
                    XCTAssertEqual(shortcuts[.rightTrigger]?.count, 1, "分配玩家的完成按钮必须使用 R2")
                    XCTAssertTrue(shortcuts[.back]?.contains("controller.panel.back") == true, "B 由面板接住（分配中 = 取消分配），不落到系统取消 / Esc（会「叮」一声）")
                    navigation.handle(.back)
                    XCTAssertFalse(controller.assigning, "B 应实际取消当前分配")
                }
            }
        }
    }
}

@MainActor final class ControllerAssignNavigationTests: XCTestCase {
    /// 分配中 Switch 2 按键（原始、未转横握）→ 界面导航：竖握 A/B，单只横握照 NS2JoyCon.c 的转法
    func testSwitch2ButtonsMapToNavigation() {
        func bits(_ n: Int...) -> UInt64 { n.reduce(0) { $0 | (1 << UInt64($1)) } }
        // Pro / 一对（竖握）：A 确认、B 返回、十字键与摇杆方向
        XCTAssertEqual(NS2LauncherController.padAction(ns2Buttons: bits(0), kind: 1, sideways: false), .confirm)
        XCTAssertEqual(NS2LauncherController.padAction(ns2Buttons: bits(1), kind: 1, sideways: false), .back)
        XCTAssertEqual(NS2LauncherController.padAction(ns2Buttons: bits(14), kind: 1, sideways: false), .right)
        XCTAssertEqual(NS2LauncherController.padAction(ns2Buttons: bits(35), kind: 1, sideways: false), .right)
        // 左只横握：下 → A、左 → B；摇杆原始「下」= 横握的右
        XCTAssertEqual(NS2LauncherController.padAction(ns2Buttons: bits(15), kind: 2, sideways: true), .confirm)
        XCTAssertEqual(NS2LauncherController.padAction(ns2Buttons: bits(12), kind: 2, sideways: true), .back)
        XCTAssertEqual(NS2LauncherController.padAction(ns2Buttons: bits(33), kind: 2, sideways: true), .right)
        // 右只横握：X → A、A → B；摇杆原始「上」= 横握的右
        XCTAssertEqual(NS2LauncherController.padAction(ns2Buttons: bits(2), kind: 3, sideways: true), .confirm)
        XCTAssertEqual(NS2LauncherController.padAction(ns2Buttons: bits(0), kind: 3, sideways: true), .back)
        XCTAssertEqual(NS2LauncherController.padAction(ns2Buttons: bits(32), kind: 3, sideways: true), .right)
        // 一代 Joy-Con：只取确认 / 返回
        XCTAssertEqual(NS2LauncherController.padAction(gen1Key: NS2LauncherController.keyDown, side: 0, sideways: true), .confirm)
        XCTAssertEqual(NS2LauncherController.padAction(gen1Key: "X", side: 1, sideways: true), .confirm)
        XCTAssertEqual(NS2LauncherController.padAction(gen1Key: "B", side: 0, sideways: false), .back)
    }

    /// 确认键（ZR 那颗）界面一律显示 A：单只 Joy-Con 没有 ZR
    func testSubmitShortcutDisplaysA() {
        XCTAssertEqual(PadShortcut.rightTrigger.displayed, .primary)
        XCTAssertEqual(PadShortcut.back.displayed, .back)
    }

    /// 分配画面：焦点落在「完成」；Switch 2 连接 / 断开不在手柄导航里（连着时按 A 会断开正在用的手柄）
    func testAssignFocusesDoneAndMainActionIsMouseOnly() async throws {
        _ = NSApplication.shared
        let suite = "s2arm-assign-nav-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let order = FileManager.default.temporaryDirectory.appendingPathComponent(suite + ".json")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: order) }
        let controller = NS2LauncherController(socketURL: URL(fileURLWithPath: "/tmp/" + suite + ".sock"), store: defaults,
            orderFile: order, systemControllers: { [] }, notifications: NotificationCenter())
        let navigation = LauncherPadNavigation()
        let host = NSHostingView(rootView: Switch2ProConnectionPopover(controller: controller, systems: SystemControllers(pads: []), lang: "en")
            .environment(\.padControls, navigation))
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 100, y: 100), size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
        defer { window.close() }
        navigation.source.controllers = { [] }
        navigation.attach(window); defer { navigation.detach() }
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(navigation.targets(in: window).contains { $0.id == "controller.main-action" }, "连接 / 断开只给鼠标，手柄导航（含 AX 兜底）都碰不到")
        controller.setAssignmentForTesting(.init())
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(navigation.focusedID, "controller.assign.done", "进分配画面焦点落在「完成」，按 A 就完成")
        navigation.handle(.left)
        XCTAssertEqual(navigation.focusedID, "controller.assign.cancel")
        navigation.handle(.right)
        XCTAssertEqual(navigation.focusedID, "controller.assign.done")
    }
}

private final class PopoverLayoutController: GCController {
    private let name: String
    private let gamepadSnapshot = GCController.withExtendedGamepad()
    init(_ name: String) { self.name = name; super.init() }
    override var vendorName: String? { name }
    override var productCategory: String { "Fixture Controller" }
    override var extendedGamepad: GCExtendedGamepad? { gamepadSnapshot.extendedGamepad }
}
