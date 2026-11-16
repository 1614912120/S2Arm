// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// iPhone 与 Apple TV 共用宿主界面里只差一个系统常量的地方（11-15 Apple TV 版）：tvOS 没有 System*Material 模糊样式与 Bar 进度条，
//   换成电视上最接近的；iOS 取原来的常量，编出来逐字节不变
#pragma once
#import <UIKit/UIKit.h>
#if TARGET_OS_TV
#define S2A_BLUR_MATERIAL_DARK UIBlurEffectStyleDark
#define S2A_BLUR_ULTRATHIN_DARK UIBlurEffectStyleDark
#define S2A_PROGRESS_BAR UIProgressViewStyleDefault
#else
#define S2A_BLUR_MATERIAL_DARK UIBlurEffectStyleSystemMaterialDark
#define S2A_BLUR_ULTRATHIN_DARK UIBlurEffectStyleSystemUltraThinMaterialDark
#define S2A_PROGRESS_BAR UIProgressViewStyleBar
#endif
