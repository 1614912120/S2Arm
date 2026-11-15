// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// S 级优化每一类此刻的那一句（iPhone 设置页；同 Mac launchers/macos/frontend/Sources/NX2Apple/SGradeStateText.swift、
//   三端状态与文案对照定稿）。纯 Foundation，宿主单测 runtime/tests/t_sgrade_line.m 直接调
#pragma once
#import <Foundation/Foundation.h>

// 版本号按段比较（1.10 > 1.9；段数不同短的补 0）：-1 / 0 / 1
int s2a_sgrade_version_cmp(NSString *a, NSString *b);
// cat = widescreen / fps；s = s2a_ios_sgrade_state 里这一类；catName = 这一类给玩家看的名字；fpsTarget = 帧率补丁的最高档（0 = 不写档）；
//   date = 自动关日期的写法；文案走 S2AL（S2ArmHost 表）。→ 那一句；没有可说的 = nil（pending / unknown / 没这一类）
NSString *s2a_sgrade_line(NSString *cat, NSDictionary *s, NSString *catName, NSInteger fpsTarget, NSString *(^date)(NSDate *when));
