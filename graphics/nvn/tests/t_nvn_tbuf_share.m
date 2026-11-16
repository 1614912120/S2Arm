// 缓冲纹理（TARGET_BUFFER）按存储共用一个视图（上游参考实现 0929dd69，MIT）。生产 nvn_mtl.m（包含）+ 真 Metal 设备。
// NVN 语义（与被测实现无关）：贴图对象只是描述符；同一池、同一偏移、同一描述的对象指同一段字节。Unreal 每帧在同一段上重建缓冲纹理对象、用完就 Finalize，
//   原先每个对象各建一个纹素缓冲视图并各加进驻留集一次（上游一条路线 72,541 次驻留提交、提交线程 293 ms）。
// 期望（按上面的语义手写）：池偏移 0x1000 上 16 个 R32F
//   ① 两个活对象（序号不同、描述相同）解析到同一个 Metal 视图
//   ② 带 IMAGE 的对象解析到同一个视图，视图带写用法（共用的视图按能有的全部用法建，IMAGE 对象不触发重建）；升级次数 +0
//   ③ 同一段上新建 64 个对象、各解析一次再 Finalize：64 / 64 是同一个视图，驻留集对象数 +0
//   ④ 同一段换宽度（32 个）是另一个视图，宽 32
//   ⑤ 偏移 0x2000 的 BGRA8：视图非空、不带写用法（Metal 不建可写的 BGRA8 纹素缓冲）；同段带 IMAGE 的对象解析到它、升级次数 +0
//   ⑥ 偏移 0x3000 的 R32I：视图不声明原子（原子只在真有原生原子调用的绑定上升级，t_nvn_image_atomic 管）
//   ⑦ 已 Finalize 对象的快照解析到共用视图，GPU 核从它读到池里的字节（第 i 个 = 100 + i）
//   ⑧ 池 Finalize：视图出共享表
// 反证（修前，同一单测编改前的 nvn_mtl.m）：① ② ③ 红（每个对象各一个视图、③ 驻留集 +64）
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, fails;
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "FAIL setup %s:%d %s\n", __FILE__, __LINE__, #x); exit(2); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) fails++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
enum { POOL_SIZE = 1 << 20, W = 16 };
static pool_t g_pool;
static tex_t make(uint32_t fmt, uint32_t width, int64_t off, uint32_t flags) {   // Initialize 过的活对象
    tex_t t; memset(&t, 0, sizeof t); t.magic = MAGIC('T', 'E', 'X', 0); t.serial = nvn_new_serial();
    t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_BUFFER, .format = fmt, .width = width, .height = 1, .depth = 1, .levels = 1, .flags = flags};
    t.pool = &g_pool; t.off = off; t.mem = g_pool.mem + off; nvn_tex_layout(&t.d, &t.L);
    nvn_be_tex_init(&t);
    return t;
}
static NSUInteger res_n(void) { pthread_mutex_lock(&g_res_mu); NSUInteger n = g_res_objects.allObjects.count; pthread_mutex_unlock(&g_res_mu); return n; }
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    mtl_init();
    uint8_t *mem = NULL; REQUIRE(!posix_memalign((void **)&mem, 65536, POOL_SIZE)); memset(mem, 0, POOL_SIZE);
    g_pool = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = mem, .size = POOL_SIZE};
    nvn_be_pool_add(mem, POOL_SIZE);
    float *src = (float *)(mem + 0x1000); for (int i = 0; i < W; i++) src[i] = 100.0f + (float)i;
    nvn_be_sub_begin();
    tex_t a = make(NVN_FORMAT_R32F, W, 0x1000, 0), b = make(NVN_FORMAT_R32F, W, 0x1000, 0);
    id<MTLTexture> view = tex_mtl(&a); REQUIRE(view && view.textureType == MTLTextureTypeTextureBuffer);
    VERIFY(tex_mtl(&b) == view, "① 两个活对象同一段：同一个视图");
    uint64_t ups = g_pfv_upgrades;
    tex_t c = make(NVN_FORMAT_R32F, W, 0x1000, NVN_TEXTURE_FLAGS_IMAGE);
    id<MTLTexture> cv = tex_mtl(&c);
    VERIFY(cv == view && (view.usage & MTLTextureUsageShaderWrite) && g_pfv_upgrades == ups, "② IMAGE 对象：%s、视图%s写用法、升级 +%llu（期望同一个、带、+0）",
           cv == view ? "同一个视图" : "另一个视图", (view.usage & MTLTextureUsageShaderWrite) ? "带" : "不带", (unsigned long long)(g_pfv_upgrades - ups));
    NSUInteger r0 = res_n(); int same = 0; tex_t snap = a;
    for (int i = 0; i < 64; i++) { tex_t t = make(NVN_FORMAT_R32F, W, 0x1000, 0); same += tex_mtl(&t) == view; if (i == 63) snap = t; nvn_be_tex_release(&t); }
    NSUInteger r1 = res_n();
    VERIFY(same == 64 && r1 == r0, "③ 64 个每帧重建的对象：同一个视图 %d / 64、驻留集 +%ld（期望 64、+0）", same, (long)r1 - (long)r0);
    tex_t w2 = make(NVN_FORMAT_R32F, 2 * W, 0x1000, 0); id<MTLTexture> wv = tex_mtl(&w2);
    VERIFY(wv && wv != view && wv.width == 2 * W && tex_mtl(&a) == view, "④ 换宽度：另一个视图（宽 %lu，期望 %d），原视图不变", (unsigned long)wv.width, 2 * W);
    ups = g_pfv_upgrades;
    tex_t g = make(NVN_FORMAT_BGRA8, W, 0x2000, 0), gi = make(NVN_FORMAT_BGRA8, W, 0x2000, NVN_TEXTURE_FLAGS_IMAGE);
    id<MTLTexture> gv = tex_mtl(&g), giv = tex_mtl(&gi);
    VERIFY(gv && !(gv.usage & MTLTextureUsageShaderWrite) && giv == gv && g_pfv_upgrades == ups, "⑤ BGRA8：视图%s、%s写用法、IMAGE 对象%s、升级 +%llu",
           gv ? "非空" : "为空", gv && (gv.usage & MTLTextureUsageShaderWrite) ? "带" : "不带", giv == gv ? "同一个" : "另一个", (unsigned long long)(g_pfv_upgrades - ups));
    tex_t ai = make(NVN_FORMAT_R32I, W, 0x3000, 0); id<MTLTexture> av = tex_mtl(&ai);
    VERIFY(av && !tex_atomic_usage(av) && (av.usage & MTLTextureUsageShaderWrite), "⑥ R32I：视图带写用法、不声明原子");
    id<MTLTexture> sv = tex_mtl(&snap);
    VERIFY(sv == view, "⑦ 已 Finalize 对象的快照：解析到共用视图");
    uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
    {   // ⑦ GPU 从共用视图读池里的字节
        NSError *err = nil;
        const char *msl = "#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void get(texture_buffer<float> t [[texture(0)]], device float *o [[buffer(0)]], uint i [[thread_position_in_grid]]) { o[i] = t.read(i).x; }\n";
        id<MTLLibrary> lib = [g_dev newLibraryWithSource:@(msl) options:nil error:&err]; REQUIRE(lib);
        id<MTLComputePipelineState> ps = [g_dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"get"] error:&err]; REQUIRE(ps);
        id<MTLCommandQueue> q = [g_dev newCommandQueue]; id<MTLBuffer> out = [g_dev newBufferWithLength:W * 4 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        [e setComputePipelineState:ps]; [e setTexture:sv atIndex:0]; [e setBuffer:out offset:0 atIndex:0]; [e useResource:sv.buffer usage:MTLResourceUsageRead];
        [e dispatchThreads:MTLSizeMake(W, 1, 1) threadsPerThreadgroup:MTLSizeMake(W, 1, 1)]; [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
        int bad = -1; const float *o = out.contents; for (int i = 0; i < W; i++) if (o[i] != 100.0f + (float)i) { bad = i; break; }
        VERIFY(cb.status == MTLCommandBufferStatusCompleted && bad < 0, "⑦ GPU 从共用视图读到池里的字节（%d 个；第一处不符 %d）", W, bad);
    }
    nvn_be_alias_drop_pool(&g_pool);
    VERIFY(!alias_has(view) && !alias_has(gv), "⑧ 池 Finalize：视图出共享表");
    printf("%s t_nvn_tbuf_share：%u 项，%u 项失败\n", fails ? "✗" : "✓", checks, fails);
    return fails != 0;
} }
