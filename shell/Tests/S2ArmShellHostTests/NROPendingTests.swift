// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import Testing
@testable import S2ArmShellHost

/// 待补文件提示（#8be819）：宿主把游戏解开的 NRO 存到 <文档根>/games/<号>/wire/<号大写>/nro/<SHA-256>.nro；
///   装机作业拉回、补进包、装好后删掉手机上的这几份。目录里还有这几份 = 还没补好 → 库顶提示；没了 → 不提示
struct NROPendingTests {
    let sha = String(repeating: "ab", count: 32)

    func root() throws -> URL {
        let r = FileManager.default.temporaryDirectory.appendingPathComponent("s2a-nro-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
        return r
    }
    func keep(_ root: URL, _ id: String, _ name: String) throws {
        let d = root.appendingPathComponent(id).appendingPathComponent("wire/\(id.uppercased())/nro", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try Data([1]).write(to: d.appendingPathComponent(name))
    }

    @Test func onlyGamesWithAKeptNROArePending() throws {
        let r = try root(); defer { try? FileManager.default.removeItem(at: r) }
        try keep(r, "0100c9c00e25c000", "\(sha).nro")              // 待补：文件名是 64 位小写十六进制 + .nro
        try keep(r, "0100000000010000", "\(sha).nro.123.tmp")      // 宿主写到一半的临时文件不算
        try FileManager.default.createDirectory(at: r.appendingPathComponent("0100000000020000/wire/0100000000020000/nro"), withIntermediateDirectories: true)   // 补好后删空的目录
        let ids = ["0100c9c00e25c000", "0100000000010000", "0100000000020000", "0100000000030000"]
        #expect(S2ArmShellHostModel.nroPending(gamesRoot: r, ids: ids) == ["0100c9c00e25c000"])
    }

    @Test func noticeNamesTheGamesAndSaysHowToFixIt() throws {
        #expect(S2ArmShellHostModel.nroNotice(names: []) == nil)
        let one = try #require(S2ArmShellHostModel.nroNotice(names: ["Game A"]))
        #expect(one.title.contains("Game A"))
        #expect(one.body.contains("S2Arm"))
        let two = try #require(S2ArmShellHostModel.nroNotice(names: ["Game A", "Game B"]))
        #expect(two.title.contains("2") && two.title.contains("Game A") && two.title.contains("Game B"))
    }
}
