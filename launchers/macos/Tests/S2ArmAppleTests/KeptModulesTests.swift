// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import AppKit
import XCTest
@testable import NX2AppleUI
import S2ArmAppleAdapter

// 手机上宿主留下的代码模块（#8be819，S2ArmLauncherModel.keptModulesTick）：phoneKeptPull 回报有还没补进 iPhone 件的款 → 自动发起一次「更新 iPhone」，
//   带上那台设备、不弹确认（ask: false）；同一批再查到不重复发起；没有要补的 → 不发起；手机上 S2Arm 正在跑 → 这一轮不推、退了再推
@MainActor final class KeptModulesTests: XCTestCase {
    func testTickStartsOneUpdatePerBatch() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-kept-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
        let runner = KeptRunner()
        let model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
            privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"), runner: runner))
        runner.kept = []
        let none = await model.keptModulesTick()
        XCTAssertFalse(none, "没有要补的款：不发起")
        runner.kept = ["0100C9C00E25C000"]; runner.running = true
        let playing = await model.keptModulesTick()
        XCTAssertFalse(playing, "手机上 S2Arm 正在跑：不推（装 App 会杀掉这局）")
        XCTAssertEqual(runner.updates.count, 0)
        runner.running = false
        let first = await model.keptModulesTick()
        for _ in 0..<300 where model.busy || runner.updates.count < 1 { try? await Task.sleep(for: .milliseconds(10)) }
        let again = await model.keptModulesTick()
        XCTAssertTrue(first, "退出后有没补进的款：发起（正在玩那一轮没记已试）")
        XCTAssertFalse(again, "同一批只发起一次")
        XCTAssertEqual(runner.updates.count, 1)
        XCTAssertEqual(runner.updates.first?["device"] as? String, "00008160-FIXTURE", "带上回报的那台")
    }

    // 启动器升级顺带更新 iPhone App（11-16）：壳旧了且不用问（shellUpdate）→ 开关开着就自动更新一次；开关关 → 不发起；正在玩 → 不发起
    func testShellUpdateFollowsSwitch() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-shell-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
        let runner = KeptRunner(); runner.kept = []; runner.shellUpdate = true
        let model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
            privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"), runner: runner))
        let key = S2ArmLauncherModel.autoUpdatePhoneOffKey, before = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(before, forKey: key) }
        S2ArmLauncherModel.setAutoUpdatePhone(false)
        let off = await model.keptModulesTick()
        XCTAssertFalse(off, "开关关：壳旧了也不自动更新")
        S2ArmLauncherModel.setAutoUpdatePhone(true); runner.running = true
        let playing = await model.keptModulesTick()
        XCTAssertFalse(playing, "正在玩：不更新")
        runner.running = false
        let first = await model.keptModulesTick()
        for _ in 0..<300 where model.busy || runner.updates.count < 1 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(first, "开关开、没在玩、壳旧了不用问：自动更新")
        XCTAssertEqual(runner.updates.count, 1)
        XCTAssertEqual(runner.updates.first?["device"] as? String, "00008160-FIXTURE")
        XCTAssertTrue(S2ArmLauncherModel.autoUpdatePhoneOn(UserDefaults(suiteName: "s2arm-fresh-" + UUID().uuidString)!), "没碰过开关：缺省开")
    }
}

private final class KeptRunner: JobProcessRunner {
    final class Handle: JobProcessHandle { func terminate() {} }
    var updates: [[String: Any]] = []
    var kept: [String] = []
    var running = false
    var shellUpdate = false
    func start(executable: URL, arguments: [String], environment: [String: String],
               onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        var taskId = "", op = ""
        if let last = arguments.last, last.hasSuffix(".json"), let data = try? Data(contentsOf: URL(fileURLWithPath: last)),
           let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            taskId = request["taskId"] as? String ?? ""; op = request["operation"] as? String ?? ""
            if op == "installUpdate" { updates.append(request) }
        }
        let result: [String: Any] = op == "phoneKeptPull" ? ["device": "00008160-FIXTURE", "new": kept.count, "kept": kept, "shellUpdate": shellUpdate, "stale": [String](), "running": running] : [:]
        let event: [String: Any] = ["schema": 1, "taskId": taskId, "type": "result", "state": "succeeded", "result": result, "message": ""]
        DispatchQueue.main.async { onLine(try! JSONSerialization.data(withJSONObject: event)); onExit(0) }
        return Handle()
    }
}
