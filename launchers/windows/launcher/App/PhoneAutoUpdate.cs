// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 手机连着、启动器开着时自动更新 iPhone 上的 S2Arm（同 Mac S2ArmLauncherModel.keptModulesLoop / keptModulesTick）。
//   每 2 分钟跑一次 phoneKeptPull 作业：手机上宿主留下的代码模块拉回游戏库；有还没补进 iPhone 件的款（kept），
//   或连着的这台壳比本版旧、且没有要按新版重出包的款（shellUpdate，11-16 维护者「启动器升级并更新 IPA，点一次完成整个流程」），
//   就自动发起一次「更新 iPhone」。手机上正在玩（Windows 读不到进程，作业层按游玩心跳判）或查不清时不发起，下一轮再看。
//   同一批只自动发起一次，没成（要确认 / 失败）就留给顶栏「更新 iPhone」按钮。有作业在跑时跳过这一轮。
//   开关：privateRoot/auto-update-phone.off 存在 = 玩家关了壳自动更新（缺省开，存的是「关」，同 Mac S2AAutoUpdatePhoneOff）。
using System.Text.Json;
using Avalonia.Threading;
using S2Arm.Launcher.Protocol;

namespace S2Arm.Launcher;

public sealed partial class EnvironmentWindow
{
    private DispatcherTimer? phoneAutoTimer;
    private bool phoneAutoTicking;
    private readonly HashSet<string> phoneAutoTried = new();

    private string AutoUpdatePhoneOffPath => Path.Combine(privateRoot, "auto-update-phone.off");
    private bool AutoUpdatePhoneOn => !File.Exists(AutoUpdatePhoneOffPath);

    private void StartPhoneAutoUpdate()
    {
        if (phoneAutoTimer is not null) return;
        phoneAutoTimer = new DispatcherTimer { Interval = TimeSpan.FromMinutes(2) };
        phoneAutoTimer.Tick += (_, _) => _ = PhoneAutoUpdateTickAsync();
        phoneAutoTimer.Start();
    }

    /// <summary>一轮：→ 这次有没有发起「更新 iPhone」</summary>
    private async Task<bool> PhoneAutoUpdateTickAsync()
    {
        if (phoneAutoTicking || connectedFolder is null || libraryId is null || ControlBusy || batchRunning) return false;
        phoneAutoTicking = true;
        try
        {
            JsonElement r;
            try
            {
                var job = await PackJobClient.RunAsync(PackRequest("phoneKeptPull", ""), null, CancellationToken.None);
                if (!job.Report.Succeeded || job.Report.Result.ValueKind != JsonValueKind.Object) return false;
                r = job.Report.Result;
            }
            catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or ArgumentException or
                InvalidOperationException or OperationCanceledException or System.ComponentModel.Win32Exception) { return false; }
            var device = r.TryGetProperty("device", out var d) && d.ValueKind == JsonValueKind.String ? d.GetString() ?? "" : "";
            var kept = r.TryGetProperty("kept", out var k) && k.ValueKind == JsonValueKind.Array
                ? k.EnumerateArray().Where(e => e.ValueKind == JsonValueKind.String).Select(e => e.GetString()!).OrderBy(s => s, StringComparer.Ordinal).ToList()
                : new List<string>();
            var shellUpdate = r.TryGetProperty("shellUpdate", out var s) && s.ValueKind == JsonValueKind.True && AutoUpdatePhoneOn;
            if ((kept.Count == 0 && !shellUpdate) || device.Length == 0) return false;
            // 正在玩（或查不清）：装 App 会杀掉玩家这一局，等下一轮（这一批不记已试）
            if (!(r.TryGetProperty("running", out var run) && run.ValueKind == JsonValueKind.False)) return false;
            var batch = device + ":" + string.Join(",", kept) + (shellUpdate ? ":shell" : "");
            if (phoneAutoTried.Contains(batch) || ControlBusy || batchRunning) return false;
            phoneAutoTried.Add(batch);
            await RefreshLibraryAsync();   // 顶栏 / 更新页按刚读回的 phoneUpdates 画
            _ = UpdatePhoneAsync(false, [], ask: false, mode: "device", device: device);   // 自动更新只装到连着的手机：显式 device，不跟随「出完之后导出自签」的缺省
            return true;
        }
        finally { phoneAutoTicking = false; }
    }
}
