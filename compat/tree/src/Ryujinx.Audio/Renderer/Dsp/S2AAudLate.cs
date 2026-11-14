using System;
using System.Runtime.InteropServices;

namespace Ryujinx.Audio.Renderer.Dsp
{
    /// <summary>
    /// S2Arm (11-14 卡顿诊断探针): 把声音渲染线程每个 5 ms 周期的唤醒迟到纳秒累计交给宿主（hle_nvn.c 的 s2a_aud_late_note），
    /// DM_NVN_TSV 每帧取走清零成 @aud_wait_ms 列。慢帧归因「在等事件」时用它看音频占比。
    /// </summary>
    /// <remarks>
    /// 只有苹果宿主定义 s2a_aud_late_note：运行时按名从主程序取函数指针（同 S2ADirect），不用 DllImport——
    /// 安卓的 DirectPInvoke 会把 DllImport 静态链进单库，缺符号就链不过。取不到（安卓 / 单测 / 别的宿主）就不记。
    /// </remarks>
    internal static unsafe class S2AAudLate
    {
        private static readonly delegate* unmanaged<long, void> _note = Resolve();

        private static delegate* unmanaged<long, void> Resolve()
        {
            try
            {
                return NativeLibrary.TryGetExport(NativeLibrary.GetMainProgramHandle(), "s2a_aud_late_note", out nint f)
                    ? (delegate* unmanaged<long, void>)f
                    : null;
            }
            catch (Exception)
            {
                return null;
            }
        }

        internal static void Note(long lateNs)
        {
            if (_note != null)
            {
                _note(lateNs);
            }
        }
    }
}
