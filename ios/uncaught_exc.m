// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 未捕获的 ObjC 异常：记下异常名、原因、userInfo 与调用栈符号，再交给原先的处理（之后照常 abort → 崩溃现场）。
//   11-14 #5eac3f：苹果 GameController 在主队列回调里抛了 NSException（终止原因 FOUNDATION 0x1），我们没装这个处理，
//   诊断里只剩「主队列 → GameController」几帧偏移，异常名和原因都丢了，判不了是哪一步用法触发的
#import <Foundation/Foundation.h>
#include "../runtime/src/native.h"

static NSUncaughtExceptionHandler *g_prev;
static void s2a_uncaught(NSException *e) {
    LOG("【红】未捕获的 ObjC 异常：%s：%s", e.name.UTF8String ?: "?", e.reason.UTF8String ?: "（无原因）");
    if (e.userInfo.count) LOG("  异常 userInfo：%s", e.userInfo.description.UTF8String ?: "");
    NSArray<NSString *> *st = e.callStackSymbols;
    for (NSUInteger i = 0; i < st.count && i < 32; i++) LOG("  异常栈 %s", st[i].UTF8String ?: "");
    if (g_prev) g_prev(e);
}
__attribute__((constructor)) static void s2a_uncaught_install(void) {
    g_prev = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(s2a_uncaught);
}
