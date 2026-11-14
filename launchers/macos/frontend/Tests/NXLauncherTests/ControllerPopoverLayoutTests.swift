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
                let view = Switch2ProConnectionPopover(controller: controller, systems: systems, simplifiedChinese: zh)
                XCTAssertEqual(view.connectionSections, [.init(source: .system, title: "DualSense Wireless Controller", status: .connected)],
                               "Switch 的 \(phase) 不能在 DualSense 上显示失败或生成第二个连接卡片")
                XCTAssertEqual(controller.title(simplifiedChinese: zh), "DualSense Wireless Controller")
                XCTAssertEqual(controller.buttonStatus, "已连接")
            }
            controller.apply(status: 4, ["status": 4, "kind": 1, "players": 1, "devices": [["kind": 1, "id": "fixture-switch"]]])
            let mixed = Switch2ProConnectionPopover(controller: controller, systems: systems, simplifiedChinese: zh)
            XCTAssertEqual(mixed.connectionSections, [.init(source: .switchRelay, title: "Switch 2 Pro", status: .connected),
                .init(source: .system, title: "DualSense Wireless Controller", status: .connected)], "混连时分别显示真实来源")
            controller.setPhaseForTesting(.handedOff)
            XCTAssertEqual(Switch2ProConnectionPopover(controller: controller, systems: systems, simplifiedChinese: zh).connectionSections.first?.status, .inUse)
            controller.apply(status: 0, ["status": 0, "kind": 0, "devices": []])
            controller.setPhaseForTesting(.off)
            let another = NSObject()
            let two = SystemControllers(pads: systems.pads + [.init(id: ObjectIdentifier(another), name: "DualSense Wireless Controller", family: .playstation)])
            let multiple = Switch2ProConnectionPopover(controller: controller, systems: two, simplifiedChinese: zh)
            XCTAssertEqual(multiple.connectionSections, [.init(source: .system,
                title: zh ? "2 个蓝牙手柄" : "2 Bluetooth controllers", status: .connected)], "两只同名设备不能按名字误合并")
            let empty = Switch2ProConnectionPopover(controller: controller, systems: SystemControllers(pads: []), simplifiedChinese: zh)
            XCTAssertEqual(empty.connectionSections, [.init(source: .switchRelay,
                title: zh ? "Switch 手柄" : "Switch Controller", status: .notConnected)], "空闲的 Switch 卡片不能借用系统手柄名称")
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
                let host = NSHostingView(rootView: Switch2ProConnectionPopover(controller: controller, systems: systems, simplifiedChinese: zh)
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
                XCTAssertEqual(Set(navigation.controlTargets(in: window).map(\.id)), ["controller.system.settings", "controller.switch-options"],
                               "系统手柄默认只提供系统设置和独立 Switch 入口，不能出现伪装成 DualSense 的重连按钮")
                XCTAssertEqual(host.bounds.width, 380, accuracy: 0.5)
                XCTAssertGreaterThanOrEqual(frames.count, 2, "必须测到 Switch 入口和蓝牙设置按钮")
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
                    _ = try XCTUnwrap(navigation.controlTargets(in: window).first { $0.id == "controller.switch-options" })
                    navigation.source.controllers = { [] }
                    navigation.attach(window)
                    defer { navigation.detach() }
                    navigation.focus("controller.switch-options"); navigation.handle(.confirm)
                    try await Task.sleep(for: .milliseconds(80))
                    let expanded = Set(navigation.controlTargets(in: window).map(\.id))
                    XCTAssertTrue(expanded.contains("controller.main-action"), "手柄 A 能展开 Switch 选项并保留实际连接操作")
                    XCTAssertTrue(expanded.contains("controller.system.settings"))
                    XCTAssertFalse(expanded.contains("controller.switch-options"))
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
