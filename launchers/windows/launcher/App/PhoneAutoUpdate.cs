// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 手机连着、启动器开着时自动更新 iPhone 上的 S2Arm（同 Mac S2ArmLauncherModel.keptModulesLoop / keptModulesTick）。
//   每 2 分钟跑一次 phoneKeptPull 作业：手机上宿主留下的代码模块拉回游戏库；有还没补进 iPhone 件的款（kept），
//   或连着的这台壳比本版旧、且没有要按新版重出包的款（shellUpdate，11-16 维护者「启动器升级并更新 IPA，点一次完成整个流程」），
//   就自动发起一次「更新 iPhone」。手机上正在玩（Windows 读不到进程，作业层按游玩心跳判）或查不清时不发起，下一轮再看。
//   同一批只自动发起一次，没成（要确认 / 失败）就留给顶栏「更新 iPhone」按钮。有作业在跑时跳过这一轮。
//   开关：privateRoot/auto-update-phone.off 存在 = 玩家关了壳自动更新（缺省开，存的是「关」，同 Mac S2AAutoUpdatePhoneOff）。
// 启动器升级顺带更新 iPhone App（同 Mac S2ArmLauncherModel+PhoneBanner.swift）：更新弹窗按钮写「更新启动器和 iPhone App」（UpdateAlsoPhone）；
//   新版启动器头一次读到要更新的手机 → 后台 installUpdatePrepare（不连手机），顶部横幅「正在更新 iPhone 版 S2Arm…」→「已准备好，连上手机后自动装」，
//   作业不在 / 失败 →「手机连上时会自动更新」；自动 / 手动更新 iPhone 时横幅显示进度；装完 phoneUpdates 空了横幅自己收起。
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
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

    /// <summary>横幅状态："" 不显示 / preparing / ready / onConnect</summary>
    private string phoneBanner = "";
    private bool phonePrepareTried;

    /// <summary>更新弹窗主按钮写「更新启动器和 iPhone App」：装过 iPhone、且没关自动更新 iPhone App</summary>
    private bool UpdateAlsoPhone => (catalog?.PhoneDevices ?? 0) > 0 && AutoUpdatePhoneOn;

    /// <summary>这次启动头一次读到要更新的手机：后台准备一次</summary>
    private async Task PreparePhoneUpdateAsync()
    {
        if (phonePrepareTried || catalog is not { PhoneUpdates.Count: > 0 } || !AutoUpdatePhoneOn || connectedFolder is null || libraryId is null) return;
        phonePrepareTried = true;
        phoneBanner = "preparing"; Render();
        var ok = false;
        try { ok = (await PackJobClient.RunAsync(PackRequest("installUpdatePrepare", ""), null, CancellationToken.None)).Report.Succeeded; }
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or ArgumentException or
            InvalidOperationException or OperationCanceledException or System.ComponentModel.Win32Exception) { }
        if (phoneBanner == "preparing") { phoneBanner = ok ? "ready" : "onConnect"; Render(); }
    }

    /// <summary>横幅这一刻的文案键（Percent 非空 = 进行中、不给 ×）：在更新 iPhone → 正在更新；否则按准备结果；手机已是本版 → null</summary>
    private (string Key, long? Percent)? PhoneBannerLine()
    {
        if (phoneBanner.Length == 0) return null;
        if (phoneUpdating) return ("phone.update.banner.preparing", -1);   // 更新进度事件只刷新顶栏那一格（RefreshLive），横幅不写会停住的百分比；-1 = 进行中、不给 ×
        if (catalog is not { PhoneUpdates.Count: > 0 }) return null;
        return phoneBanner switch { "preparing" => ("phone.update.banner.preparing", null), "ready" => ("phone.update.banner.ready", null), _ => ("phone.update.banner.on_connect", null) };
    }

    private void AddPhoneUpdateBar(StackPanel body)
    {
        if (PhoneBannerLine() is not { } line) return;
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 10 };
        var text = new TextBlock { Text = T(line.Key), FontSize = 13, FontWeight = FontWeight.SemiBold,
            Foreground = Ink, TextWrapping = TextWrapping.Wrap, VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center };
        Avalonia.Automation.AutomationProperties.SetAutomationId(text, "notice.phoneUpdate");
        row.Children.Add(text);
        if (line.Percent is null)
        {
            var close = new Button { Content = "✕", Padding = new Thickness(8, 4), Background = Brushes.Transparent, Foreground = Ink };
            ToolTip.SetTip(close, T("notice.close"));
            Avalonia.Automation.AutomationProperties.SetName(close, T("notice.close"));
            Avalonia.Automation.AutomationProperties.SetAutomationId(close, "notice.phoneUpdate.close");
            close.Click += (_, _) => { phoneBanner = ""; Render(); };
            Grid.SetColumn(close, 1); row.Children.Add(close);
        }
        body.Children.Add(new Border { Child = row, Padding = new Thickness(16, 10), CornerRadius = new CornerRadius(10), Background = new SolidColorBrush(Colors.White, 0.06) });
    }

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
            _ = UpdatePhoneAsync(false, [], ask: false, device: device);
            return true;
        }
        finally { phoneAutoTicking = false; }
    }
}
