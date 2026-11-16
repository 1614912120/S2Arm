// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 启动器升级顺带更新 iPhone App（11-16 维护者「把启动器升级改成启动器升级并更新 IPA，点一次完成整个流程；更新的启动器启动了以后，
//   直接弹出 IPA 正在更新这样的信息；IPA 更新也并不需要连手机」）：
//   - 更新弹窗：这台电脑装过 iPhone、自动更新开着 → 按钮写「更新启动器和 iPhone App」（updateAlsoPhone）；
//   - 新版启动器首次读到游戏库、有要更新的手机（phoneUpdates）→ 后台跑 installUpdatePrepare（不连手机：按本引擎核各款 iPhone 程序），
//     顶部横幅「正在更新 iPhone 版 S2Arm…」→「已准备好，连上手机后自动装」；作业不在 / 失败 →「手机连上时会自动更新」（照旧在装机时补）；
//   - 手机连上、没在玩：keptModulesLoop 自动发起「更新 iPhone」，横幅显示进度；装完 phoneUpdates 空了横幅自己收起。
import Foundation
import S2ArmAppleAdapter

enum PhoneBanner: Equatable { case preparing, ready, onConnect }

extension S2ArmLauncherModel {
    /// 更新弹窗的主按钮写「更新启动器和 iPhone App」：装过 iPhone、且没关自动更新 iPhone App
    var updateAlsoPhone: Bool { phoneDevices > 0 && Self.autoUpdatePhoneOn() }

    /// 启动后一次（refresh 的 startup）：有要更新的手机就后台准备，横幅跟着变
    func preparePhoneUpdate() {
        guard !phoneUpdates.isEmpty, Self.autoUpdatePhoneOn(), phoneBanner == nil else { return }
        phoneBanner = .preparing
        Task { [weak self] in
            guard let self else { return }
            let ok = (try? await self.provider.client.perform("installUpdatePrepare")) != nil
            if self.phoneBanner == .preparing { self.phoneBanner = ok ? .ready : .onConnect }
        }
    }

    /// 横幅这一刻的文案键与百分比：正在更新 iPhone（手机槽 installUpdate）→ 进度；否则按准备结果；手机已是本版 → nil（不显示）
    var phoneBannerLine: (key: String, percent: Int?)? {
        guard let banner = phoneBanner else { return nil }
        if phoneBusy, let phone = phoneSession, phone.kind == .installUpdate {
            return ("phone.update.banner.progress", Int(((phone.progress.overall ?? 0) * 100).rounded()))
        }
        if phoneUpdates.isEmpty { return nil }
        switch banner {
        case .preparing: return ("phone.update.banner.preparing", nil)
        case .ready: return ("phone.update.banner.ready", nil)
        case .onConnect: return ("phone.update.banner.on_connect", nil)
        }
    }
}
