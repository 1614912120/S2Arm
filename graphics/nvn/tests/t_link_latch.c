// 显示链路回调晚锁存的等待上界（graphics/nvn/gfx/nvn/nvn_link_latch.h；用例取自 nxnative 60284e79 dm/gfx/tests/t_link_latch.c，MIT）。纯函数：不连 Metal、不读时钟。
// 期望值按规则手推：等到 targetTimestamp 前八分之一周期、且不晚于下一次回调前八分之一周期；连续 LINK_LATCH_GIVE_UP 次超时后只在每第 LINK_LATCH_PROBE 次唤醒回调探测，排空收尾不受放弃限制。
// 例：cb=100、targetTimestamp=cb+16.5 ms、60 Hz → until = cb+16.5−2.083 = cb+14.417 ms，cap = cb+16.667−2.083 = cb+14.583 ms，取小 → 等 14.417 ms
#include "nvn_link_latch.h"
#include <math.h>
#include <stdio.h>

static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; printf("FAIL: %s\n", label); } } while (0)
#define NEAR(a, b) (fabs((a) - (b)) < 1e-9)

int main(void) {
    const double T60 = 1.0 / 60, T120 = 1.0 / 120, cb = 100;
    CHECK(NEAR(nvn_link_latch_wait(cb, cb + 0.0165, T60, 0, 1, 0), 0.0165 - T60 / 8), "a whole period to targetTimestamp (a ProMotion screen at 60 Hz): up to an eighth of a period before it (14.4 ms)");
    CHECK(NEAR(nvn_link_latch_wait(cb, cb + 0.020, T120, 0, 1, 0), T120 - T120 / 8), "room past the next callback (frame latency 2): no further than an eighth of a period before it (7.3 ms of an 8.3 ms period)");
    CHECK(NEAR(nvn_link_latch_wait(cb, cb + 0.020, T60, 0, 1, 0), T60 - T60 / 8), "and of a 60 Hz period (14.6 ms)");
    CHECK(NEAR(nvn_link_latch_wait(cb, cb + 0.005, T60, 0, 1, 0), 0.005 - T60 / 8), "near targetTimestamp: an eighth of a period before it");
    CHECK(nvn_link_latch_wait(cb, cb + T60 / 8, T60, 0, 1, 0) == 0, "no room before targetTimestamp: no wait");
    CHECK(nvn_link_latch_wait(cb, cb - 0.001, T60, 0, 1, 0) == 0, "a callback past its targetTimestamp: no wait");
    CHECK(nvn_link_latch_wait(cb, cb + 0.020, 0, 0, 1, 0) == 0, "no period: no wait");
    CHECK(nvn_link_latch_wait(cb, cb + 0.020, T60, LINK_LATCH_GIVE_UP - 1, 1, 0) > 0, "a few timeouts in a row: still waits");
    CHECK(nvn_link_latch_wait(cb, cb + 0.020, T60, LINK_LATCH_GIVE_UP, 1, 0) == 0, "too many in a row: stops waiting");
    CHECK(nvn_link_latch_wait(cb, cb + 0.020, T60, LINK_LATCH_GIVE_UP, LINK_LATCH_PROBE * 3, 0) > 0, "but tries again on every LINK_LATCH_PROBE-th woken callback");
    int probes = 0; for (uint64_t w = 1; w <= 2 * LINK_LATCH_PROBE; w++) probes += nvn_link_latch_wait(cb, cb + 0.020, T60, LINK_LATCH_GIVE_UP, w, 0) > 0;
    CHECK(probes == 2, "counted in woken callbacks, not ticks: two probes in 2 x LINK_LATCH_PROBE woken callbacks, whatever ticks each acquire waits");
    CHECK(nvn_link_latch_wait(cb, cb + 0.020, T60, LINK_LATCH_GIVE_UP, 1, 1) > 0, "the end of a drain into the latch waits through a give-up");
    printf("%s t_link_latch：%d 项，没过 %d\n", failed ? "✗" : "✓", checks, failed);
    return failed != 0;
}
