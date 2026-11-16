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
                XCTAssertEqual(Set(navigation.controlTargets(in: window).map(\.id)), ["controller.main-action", "controller.settings", "controller.system.settings", "controller.player.0", "controller.assign",
                    "controller.face.0", "controller.face.1", "controller.face.2", "controller.face.3", "controller.face.switch", "controller.face.reset"],
                               "Switch 2 区块（主按钮 + 齿轮）与蓝牙区块常驻；玩家选择、四键映射与分配玩家")
                XCTAssertEqual(host.bounds.width, 380, accuracy: 0.5)
                XCTAssertGreaterThanOrEqual(frames.count, 2, "必须测到 Switch 2 主按钮和蓝牙设置按钮")
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
                    XCTAssertEqual(shortcuts[.back]?.count, 1, "分配玩家的取消按钮必须有直接快捷键")
                    navigation.handle(.back)
                    XCTAssertFalse(controller.assigning, "B 应实际取消当前分配")
                }
            }
        }
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
