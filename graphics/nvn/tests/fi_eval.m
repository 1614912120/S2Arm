// 补帧画质客观评测（工具，不是门禁单测；tools/fi_eval.sh 编译并调用）。
// 用一段 60 帧游戏的连续真帧 f_<n>.png（S2A_DIRECT_REC 存的），把偶数帧当成 30 帧游戏交的帧，喂给生产的补帧代码（本文件直接包含 nvn_mtl.m，
//   走 fi_get / fi_job 同一套：MetalFX 帧插值 + 我们喂的矢量 / 深度 / 历史重置），补出的中间帧与真的奇数帧逐像素比：
//   整体、静止区（前后两帧不变的像素：界面层与静止物体）、运动边缘区（前后两帧亮度差 > 8 且真帧有边缘）各算 PSNR（RGB）与 SSIM（亮度，11×11 高斯）。
// 用法：fi_eval <帧目录> <输出 tsv> [存图目录 存图间隔]
//   FI_EVAL_MODE = fi（缺省：生产补帧，开关照 DM_PRESENT_FI_* 环境变量）| copy（补出帧 = 后一帧真帧，即「复制真帧」）| blend（前后两帧逐像素平均）
//   FI_EVAL_FROM / FI_EVAL_TO：只评这一段帧号（含两端）；FI_EVAL_LATE_EVERY=N：每 N 个游戏帧模拟一次超预算跳过（那一格按真帧记分），看跳过对后面几帧的连带影响
// 输出 tsv 每个补出帧一行：真帧号、镜头运动量（前后两帧亮度平均绝对差）、整体 / 静止 / 运动边缘的 PSNR 与 SSIM、静止与边缘像素数、补帧 GPU 毫秒（MetalFX 那条命令缓冲，含矢量计算）、整个补帧作业墙钟毫秒（含等硬件运动估计）
#ifndef FI_EVAL_SOURCE
#define FI_EVAL_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include FI_EVAL_SOURCE
#include <ImageIO/ImageIO.h>

@interface FiEvalLayer : CAMetalLayer
@end
@implementation FiEvalLayer
- (id<CAMetalDrawable>)nextDrawable { return nil; }   // 只要补出的帧，不上屏
@end

typedef struct { int n; char path[1024]; } fiev_frame;
static int fiev_cmp(const void *a, const void *b) { return ((const fiev_frame *)a)->n - ((const fiev_frame *)b)->n; }

// PNG → BGRA8（按图自带色彩空间画，不做色彩转换）
static uint8_t *fiev_load(const char *path, int *w, int *h) {
    CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    CGImageSourceRef s = u ? CGImageSourceCreateWithURL(u, NULL) : NULL; if (u) CFRelease(u);
    CGImageRef im = s ? CGImageSourceCreateImageAtIndex(s, 0, NULL) : NULL; if (s) CFRelease(s);
    if (!im) return NULL;
    *w = (int)CGImageGetWidth(im); *h = (int)CGImageGetHeight(im);
    uint8_t *p = calloc((size_t)*w * *h, 4);
    CGColorSpaceRef cs = CGImageGetColorSpace(im); if (!cs || CGColorSpaceGetModel(cs) != kCGColorSpaceModelRGB) cs = NULL;
    CGColorSpaceRef own = cs ? NULL : CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(p, (size_t)*w, (size_t)*h, 8, (size_t)*w * 4, cs ? cs : own, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextSetBlendMode(c, kCGBlendModeCopy); CGContextDrawImage(c, CGRectMake(0, 0, *w, *h), im);
    CGContextRelease(c); CGImageRelease(im); if (own) CGColorSpaceRelease(own);
    return p;
}
static void fiev_save(const char *path, const uint8_t *p, int w, int h) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate((void *)p, (size_t)w, (size_t)h, 8, (size_t)w * 4, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGImageRef im = CGBitmapContextCreateImage(c);
    CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    CGImageDestinationRef d = CGImageDestinationCreateWithURL(u, CFSTR("public.png"), 1, NULL);
    if (d) { CGImageDestinationAddImage(d, im, NULL); CGImageDestinationFinalize(d); CFRelease(d); }
    CFRelease(u); CGImageRelease(im); CGContextRelease(c); CGColorSpaceRelease(cs);
}

static inline float fiev_y(const uint8_t *q) { return 0.114f * q[0] + 0.587f * q[1] + 0.299f * q[2]; }   // BGRA
// 11×11 高斯（σ 1.5）可分离卷积，边缘按夹紧
static void fiev_blur(const float *in, float *out, float *tmp, int w, int h) {
    static float k[11]; static int init; if (!init) { float s = 0; for (int i = 0; i < 11; i++) { k[i] = expf(-(i - 5) * (i - 5) / (2 * 1.5f * 1.5f)); s += k[i]; } for (int i = 0; i < 11; i++) k[i] /= s; init = 1; }
    dispatch_apply((size_t)h, DISPATCH_APPLY_AUTO, ^(size_t y) { for (int x = 0; x < w; x++) { float a = 0; for (int i = -5; i <= 5; i++) { int xx = x + i < 0 ? 0 : x + i >= w ? w - 1 : x + i; a += k[i + 5] * in[y * w + xx]; } tmp[y * w + x] = a; } });
    dispatch_apply((size_t)h, DISPATCH_APPLY_AUTO, ^(size_t y) { for (int x = 0; x < w; x++) { float a = 0; for (int i = -5; i <= 5; i++) { int yy = (int)y + i < 0 ? 0 : (int)y + i >= h ? h - 1 : (int)y + i; a += k[i + 5] * tmp[yy * w + x]; } out[y * w + x] = a; } });
}
typedef struct { double se, ss; long n; } fiev_acc;   // 平方误差和（RGB 三通道）、SSIM 和、像素数
static double fiev_psnr(fiev_acc a) { if (!a.n) return NAN; double mse = a.se / (a.n * 3.0); return mse <= 1e-10 ? 99 : 10 * log10(255.0 * 255.0 / mse); }
static double fiev_ssim(fiev_acc a) { return a.n ? a.ss / a.n : NAN; }

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3) { fprintf(stderr, "用法：fi_eval <帧目录> <输出 tsv> [存图目录 存图间隔]\n"); return 2; }
    const char *dir = argv[1], *out = argv[2], *save_dir = argc > 4 ? argv[3] : NULL; int save_every = argc > 4 ? atoi(argv[4]) : 0;
    const char *mode = getenv("FI_EVAL_MODE") ?: "fi"; int from = getenv("FI_EVAL_FROM") ? atoi(getenv("FI_EVAL_FROM")) : INT_MIN, to = getenv("FI_EVAL_TO") ? atoi(getenv("FI_EVAL_TO")) : INT_MAX;
    int use_fi = !strcmp(mode, "fi"), use_copy = !strcmp(mode, "copy"), use_blend = !strcmp(mode, "blend");
    if (!use_fi && !use_copy && !use_blend) { fprintf(stderr, "FI_EVAL_MODE=%s 不认（fi / copy / blend）\n", mode); return 2; }
    // 帧表：f_<n>.png，按帧号排；要求连续
    DIR *d = opendir(dir); if (!d) { fprintf(stderr, "打不开 %s\n", dir); return 2; }
    fiev_frame *fr = NULL; int nf = 0, cap = 0; struct dirent *e;
    while ((e = readdir(d))) { int n; char tail[8]; if (sscanf(e->d_name, "f_%d.%7s", &n, tail) == 2 && !strcmp(tail, "png") && n >= from && n <= to) {
        if (nf == cap) { cap = cap ? cap * 2 : 1024; fr = realloc(fr, sizeof *fr * (size_t)cap); }
        fr[nf].n = n; snprintf(fr[nf].path, sizeof fr[nf].path, "%s/%s", dir, e->d_name); nf++; } }
    closedir(d); qsort(fr, (size_t)nf, sizeof *fr, fiev_cmp);
    if (nf < 3) { fprintf(stderr, "%s 里 f_<n>.png 不到 3 张\n", dir); return 2; }
    for (int i = 1; i < nf; i++) if (fr[i].n != fr[i - 1].n + 1) { fprintf(stderr, "帧号不连续：%d 之后是 %d（评测要连续真帧）\n", fr[i - 1].n, fr[i].n); return 2; }
    int w = 0, h = 0; uint8_t *probe = fiev_load(fr[0].path, &w, &h); if (!probe) { fprintf(stderr, "读不了 %s\n", fr[0].path); return 2; } free(probe);
    size_t np = (size_t)w * h;

    setenv("DM_PSO_MANIFEST", "off", 1); setenv("DM_PSO_ARCHIVE", "0", 1);
    NvPresentFI *f = nil; FiEvalLayer *layer = nil; id<MTLTexture> stage = nil; id<MTLBuffer> rb = nil;
    if (use_fi) {
        mtl_init();
        if (@available(macOS 26.0, *)) {} else { fprintf(stderr, "补帧要 macOS 26\n"); return 2; }
        g_fi_budget_ms = 10000;   // 评测不按预算跳过：每一对都等 MetalFX 做完（耗时照记）
        layer = [FiEvalLayer new]; layer.device = g_dev; layer.pixelFormat = MTLPixelFormatBGRA8Unorm; layer.drawableSize = CGSizeMake(w, h);
        if (@available(macOS 26.0, *)) f = fi_get(layer, (NSUInteger)w, (NSUInteger)h);
        if (!f) { fprintf(stderr, "补帧建不起来（见上方日志）\n"); return 1; }
        if (f->w != w || f->h != h) { fprintf(stderr, "补帧输入 %dx%d 与帧 %dx%d 不同（帧高超过 DM_PRESENT_FI_MAXH？）\n", f->w, f->h, w, h); return 2; }
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:(NSUInteger)w height:(NSUInteger)h mipmapped:NO];
        td.storageMode = MTLStorageModeShared; stage = [g_dev newTextureWithDescriptor:td];
        rb = [g_dev newBufferWithLength:np * 4 options:MTLResourceStorageModeShared];
    }
    FILE *o = fopen(out, "w"); if (!o) { fprintf(stderr, "写不了 %s\n", out); return 2; }
    fprintf(o, "frame\tmotion\tpsnr\tssim\tpsnr_static\tssim_static\tpsnr_edge\tssim_edge\tn_static\tn_edge\tgpu_ms\tjob_ms\tpsnr_hud\tssim_hud\n");
    float *yt = malloc(np * 4), *ye = malloc(np * 4), *b[6]; for (int i = 0; i < 6; i++) b[i] = malloc(np * 4);
    uint8_t *est = malloc(np * 4), *prev = NULL, *cur = NULL; uint8_t *mstat = malloc(np), *medge = malloc(np), *mhud = calloc(np, 1);
    {   // 常驻界面区：整段里相邻两张游戏帧（偶数帧）每通道差 ≤ 2 的对数占 ≥ 90% 的像素（血条、图标、小地图、对话框文字这类一直不动的层；镜头在动时景物达不到）
        uint16_t *cnt = calloc(np, 2); uint8_t *a = NULL, *bb = NULL; int pairs_all = 0, tw, th;
        for (int j = 0; 2 * j < nf; j++) { free(a); a = bb; bb = fiev_load(fr[2 * j].path, &tw, &th); if (!bb) { fprintf(stderr, "读不了 %s\n", fr[2 * j].path); return 1; } if (!a) continue;
            pairs_all++; dispatch_apply((size_t)h, DISPATCH_APPLY_AUTO, ^(size_t y) { for (size_t i = y * w; i < (y + 1) * w; i++) { const uint8_t *p = a + 4 * i, *q = bb + 4 * i;
                cnt[i] += abs(p[0] - q[0]) <= 2 && abs(p[1] - q[1]) <= 2 && abs(p[2] - q[2]) <= 2; } }); }
        long nh = 0; for (size_t i = 0; i < np; i++) { mhud[i] = pairs_all && cnt[i] >= 0.9 * pairs_all; nh += mhud[i]; }
        free(a); free(bb); free(cnt); fprintf(stderr, "常驻界面区 %ld 像素（%.2f%%），按 %d 对游戏帧判\n", nh, 100.0 * nh / np, pairs_all);
    }
    int pairs = 0; double gpu_prev = 0;
    for (int j = 0; 2 * j < nf; j++) {   // 第 j 个「游戏帧」= 第 2j 张；补出帧对的是第 2j−1 张
        free(prev); prev = cur; cur = fiev_load(fr[2 * j].path, &w, &h); if (!cur) { fprintf(stderr, "读不了 %s\n", fr[2 * j].path); return 1; }
        double gms = 0, jms = 0;
        if (use_fi) {
            int k = j % 3;
            [stage replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)w, (NSUInteger)h) mipmapLevel:0 withBytes:cur bytesPerRow:(NSUInteger)w * 4];
            id<MTLCommandBuffer> c = [f->mq commandBuffer]; id<MTLBlitCommandEncoder> be = [c blitCommandEncoder];
            [be copyFromTexture:stage toTexture:f->in_tex[k]]; [be endEncoding]; [c commit]; [c waitUntilCompleted];
            fi_inflight_add(1); fi_crop cr = {0}; uint64_t made0 = f->made;
            int late = getenv("FI_EVAL_LATE_EVERY") && j % atoi(getenv("FI_EVAL_LATE_EVERY")) == 0; g_fi_budget_ms = late ? 0 : 10000;   // 模拟超预算：这一次不等，上屏的是真帧（下面按复制真帧记分）
            double tj = CACurrentMediaTime(); if (@available(macOS 26.0, *)) fi_job(f, layer, nil, cr, NO, k, (uint64_t)j, 1.0 / 30, (uint64_t)j + 1, 1, 1); jms = (CACurrentMediaTime() - tj) * 1000;
            gms = f->gpu_sum - gpu_prev; gpu_prev = f->gpu_sum;   // fi_job 只把预算内做完的计进 gpu_sum；每 300 次清零一次（下面按差值取，清零那次差值为负则记 NaN）
            if (gms < 0) { gms = NAN; gpu_prev = f->gpu_sum; }
            if (j == 0) continue;
            if (getenv("FI_EVAL_MVSTAT")) {   // 诊断：矢量图统计（均值 / 非零占比 / 按行打几格）
                NSUInteger mw = f->motion.width, mh = f->motion.height; id<MTLBuffer> mb = [g_dev newBufferWithLength:mw * mh * 4 options:MTLResourceStorageModeShared];
                c = [f->mq commandBuffer]; be = [c blitCommandEncoder];
                [be copyFromTexture:f->motion sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(mw, mh, 1) toBuffer:mb destinationOffset:0 destinationBytesPerRow:mw * 4 destinationBytesPerImage:mw * mh * 4];
                [be endEncoding]; [c commit]; [c waitUntilCompleted];
                const __fp16 *v = mb.contents; double sx = 0, sy = 0; long nz = 0;
                for (NSUInteger i = 0; i < mw * mh; i++) { sx += v[2 * i]; sy += v[2 * i + 1]; nz += v[2 * i] != 0 || v[2 * i + 1] != 0; }
                fprintf(stderr, "mv %d: %lux%lu mean (%.2f, %.2f) nonzero %.2f; row mid:", fr[2 * j - 1].n, (unsigned long)mw, (unsigned long)mh, sx / (mw * mh), sy / (mw * mh), (double)nz / (mw * mh));
                for (NSUInteger x = 0; x < mw; x += mw / 8) fprintf(stderr, " (%.1f,%.1f)", (float)v[2 * (mh / 2 * mw + x)], (float)v[2 * (mh / 2 * mw + x) + 1]); fprintf(stderr, "\n");
            }
            c = [f->mq commandBuffer]; be = [c blitCommandEncoder];
            [be copyFromTexture:fi_mid_shown(f) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake((NSUInteger)w, (NSUInteger)h, 1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:(NSUInteger)w * 4 destinationBytesPerImage:np * 4];
            [be endEncoding]; [c commit]; [c waitUntilCompleted];
            memcpy(est, rb.contents, np * 4);
            if (f->made == made0) memcpy(est, cur, np * 4);   // 这一对没补成（超预算跳过）：屏上这一格还是真帧
        } else if (j == 0) continue;
        else if (use_copy) memcpy(est, cur, np * 4);
        else for (size_t i = 0; i < np * 4; i++) est[i] = (uint8_t)((prev[i] + cur[i] + 1) / 2);
        if (2 * j - 1 >= nf) break;
        int tw, th; uint8_t *tru = fiev_load(fr[2 * j - 1].path, &tw, &th); if (!tru || tw != w || th != h) { fprintf(stderr, "读不了 %s\n", fr[2 * j - 1].path); return 1; }
        // 区域：静止 = 前后两帧每通道差 ≤ 2；运动边缘 = 前后两帧亮度差 > 8 且真帧亮度 Sobel 梯度 > 0.1（按 0..1 亮度、单位台阶 = 1）
        double mot = 0;
        for (size_t i = 0; i < np; i++) {
            const uint8_t *p = prev + 4 * i, *q = cur + 4 * i;
            int dm = abs(p[0] - q[0]); if (abs(p[1] - q[1]) > dm) dm = abs(p[1] - q[1]); if (abs(p[2] - q[2]) > dm) dm = abs(p[2] - q[2]);
            float dy = fabsf(fiev_y(p) - fiev_y(q)); mot += dy;
            mstat[i] = dm <= 2; medge[i] = dy > 8;
            yt[i] = fiev_y(tru + 4 * i); ye[i] = fiev_y(est + 4 * i);
        }
        mot /= (double)np;
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) { size_t i = (size_t)y * w + x; if (!medge[i]) continue;
            if (x == 0 || y == 0 || x == w - 1 || y == h - 1) { medge[i] = 0; continue; }
            #define T(dx, dy) yt[(size_t)(y + (dy)) * w + x + (dx)]
            float gx = T(1, -1) + 2 * T(1, 0) + T(1, 1) - T(-1, -1) - 2 * T(-1, 0) - T(-1, 1), gy = T(-1, 1) + 2 * T(0, 1) + T(1, 1) - T(-1, -1) - 2 * T(0, -1) - T(1, -1);
            #undef T
            medge[i] = sqrtf(gx * gx + gy * gy) / (4 * 255.f) > 0.1f; }
        // SSIM 图（亮度 0..255，C1 = (0.01·255)²，C2 = (0.03·255)²）
        float *mx = b[0], *my = b[1], *sxx = b[2], *syy = b[3], *sxy = b[4], *tmp = b[5];
        fiev_blur(yt, mx, tmp, w, h); fiev_blur(ye, my, tmp, w, h);
        float *pp = malloc(np * 4); for (size_t i = 0; i < np; i++) pp[i] = yt[i] * yt[i]; fiev_blur(pp, sxx, tmp, w, h);
        for (size_t i = 0; i < np; i++) pp[i] = ye[i] * ye[i]; fiev_blur(pp, syy, tmp, w, h);
        for (size_t i = 0; i < np; i++) pp[i] = yt[i] * ye[i]; fiev_blur(pp, sxy, tmp, w, h); free(pp);
        const float C1 = 6.5025f, C2 = 58.5225f; fiev_acc all = {0}, st = {0}, ed = {0}, hu = {0};
        for (size_t i = 0; i < np; i++) {
            float vx = sxx[i] - mx[i] * mx[i], vy = syy[i] - my[i] * my[i], cv = sxy[i] - mx[i] * my[i];
            float s = ((2 * mx[i] * my[i] + C1) * (2 * cv + C2)) / ((mx[i] * mx[i] + my[i] * my[i] + C1) * (vx + vy + C2));
            const uint8_t *t = tru + 4 * i, *q = est + 4 * i; double se = 0; for (int c = 0; c < 3; c++) { double dd = (double)t[c] - q[c]; se += dd * dd; }
            all.se += se; all.ss += s; all.n++;
            if (mstat[i]) { st.se += se; st.ss += s; st.n++; }
            if (medge[i]) { ed.se += se; ed.ss += s; ed.n++; }
            if (mhud[i]) { hu.se += se; hu.ss += s; hu.n++; }
        }
        fprintf(o, "%d\t%.3f\t%.3f\t%.5f\t%.3f\t%.5f\t%.3f\t%.5f\t%lld\t%lld\t%.3f\t%.3f\t%.3f\t%.5f\n", fr[2 * j - 1].n, mot, fiev_psnr(all), fiev_ssim(all), fiev_psnr(st), fiev_ssim(st), fiev_psnr(ed), fiev_ssim(ed), (long long)st.n, (long long)ed.n, gms, jms, fiev_psnr(hu), fiev_ssim(hu));
        if (save_dir && save_every > 0 && pairs % save_every == 0) { char sp[1200]; snprintf(sp, sizeof sp, "%s/%s_%d.png", save_dir, mode, fr[2 * j - 1].n); fiev_save(sp, est, w, h); }
        free(tru); pairs++;
    }
    fclose(o);
    fprintf(stderr, "fi_eval：模式 %s，帧 %d–%d（%d 张），补出 %d 帧 → %s\n", mode, fr[0].n, fr[nf - 1].n, nf, pairs, out);
    return pairs ? 0 : 1;
} }
