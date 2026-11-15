// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#import "sgrade_line.h"
#import "s2a_l10n.h"

int s2a_sgrade_version_cmp(NSString *a, NSString *b) {
    NSArray<NSString *> *x = [a componentsSeparatedByString:@"."], *y = [b componentsSeparatedByString:@"."];
    for (NSUInteger i = 0; i < MAX(x.count, y.count); i++) {
        NSInteger p = i < x.count ? x[i].integerValue : 0, q = i < y.count ? y[i].integerValue : 0;
        if (p != q) return p < q ? -1 : 1;
    }
    return 0;
}

static NSString *str(id v) { return [v isKindOfClass:NSString.class] ? v : @""; }

NSString *s2a_sgrade_line(NSString *cat, NSDictionary *s, NSString *catName, NSInteger fpsTarget,
                          NSString *(^date)(NSDate *when)) {
    if (![s isKindOfClass:NSDictionary.class]) return nil;
    NSString *state = str(s[@"state"]);
    if ([state isEqual:@"on"]) {
        if ([cat isEqual:@"fps"]) return fpsTarget > 0 ? [NSString stringWithFormat:S2AL(@"sgrade.state.on.fps"), [@(fpsTarget) stringValue]] : nil;
        if (![cat isEqual:@"widescreen"]) return nil;
        NSString *active = str(s[@"active"]);
        if ([str(s[@"source"]) isEqual:@"own"] || [active isEqual:@"own"]) return S2AL(@"sgrade.state.on.own");
        return [active isEqual:@"fixed"] ? S2AL(@"sgrade.state.on.fixed") : S2AL(@"sgrade.state.on.adaptive");
    }
    if ([state isEqual:@"ineffective"]) { NSString *r = str(s[@"lastRun"]); return r.length ? r : nil; }   // 原句本身就写「没生效：…」，不再套一层
    if ([state isEqual:@"off_user"]) return S2AL(@"sgrade.state.off_user");
    if ([state isEqual:@"off_auto"]) {
        NSDictionary *off = [s[@"autoOff"] isKindOfClass:NSDictionary.class] ? s[@"autoOff"] : nil;
        NSNumber *at = [off[@"at"] isKindOfClass:NSNumber.class] ? off[@"at"] : nil;
        NSString *when = at.doubleValue > 0 ? date([NSDate dateWithTimeIntervalSince1970:at.doubleValue]) : @"";
        return [NSString stringWithFormat:([str(off[@"cause"]) isEqual:@"stall"] ? S2AL(@"sgrade.state.off_auto.stall") : S2AL(@"sgrade.state.off_auto.crash")), when];
    }
    if ([state isEqual:@"version"]) {
        // 维护者 11-15 定：写离玩家最近、且比它新的那个版本；全是旧版本写「只有旧版本 X 的」，不劝降级
        NSDictionary *v = [s[@"versions"] isKindOfClass:NSDictionary.class] ? s[@"versions"] : @{};
        NSString *mine = str(v[@"mine"]); NSMutableArray<NSString *> *all = [NSMutableArray array];
        for (id x in [v[@"available"] isKindOfClass:NSArray.class] ? v[@"available"] : @[]) if ([x isKindOfClass:NSString.class]) [all addObject:x];
        if (!all.count) return nil;
        [all sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) { return (NSComparisonResult)s2a_sgrade_version_cmp(a, b); }];
        NSString *newer = nil; for (NSString *x in all) if (s2a_sgrade_version_cmp(x, mine) > 0) { newer = x; break; }
        NSString *text = newer ? [NSString stringWithFormat:S2AL(@"sgrade.state.version.newer"), newer, mine]
                               : [NSString stringWithFormat:S2AL(@"sgrade.state.version.older"), all.lastObject];
        if ([cat isEqual:@"widescreen"] && [str(v[@"port"]) isEqual:@"failed"]) text = [text stringByAppendingString:S2AL(@"sgrade.state.version.port_failed")];
        return text;
    }
    if ([state isEqual:@"none"]) return [NSString stringWithFormat:S2AL(@"sgrade.state.none"), catName];
    if ([state isEqual:@"opted_out"]) return S2AL(@"sgrade.state.opted_out");
    if ([state isEqual:@"pending"]) return S2AL(@"sgrade.state.pending.ios");   // iPhone 补不上：要回电脑点「S 级优化升级」（Mac 下次起局自动补，不说）
    if ([state isEqual:@"mac_only"]) return S2AL(@"sgrade.state.mac_only");
    return nil;
}
