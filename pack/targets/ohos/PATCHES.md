# Windows 出包补丁与程序复用

在原始 exeFS 的独立副本上打补丁，再做 OHOS 指令改写、代码载体生成与签名。原始游戏与旧版程序目录保留。游戏包、社区补丁、密钥和派生代码均放仓外；本目录只包含工具。

本地配置可添加：

```json
{
  "patchSources": ["D:/my-patches/60fps/INDEX.tsv", "D:/my-patches/wide/INDEX.tsv"],
  "patchOptions": {"enabled": true, "fps": 60, "aspect": "native"}
}
```

`INDEX.tsv` 使用提供合集的列：`title_id, build_id, source, path, in_pack, dup_of, sha256`；帧率索引另有 `type, target_fps`，比例索引另有 `kind, aspect, ui_fix, license`。路径相对索引所在目录。社区索引可以和自研索引并列配置，来源信息一同写入报告。

```powershell
python pack/targets/ohos/cli.py --config D:/private/ohos.json patches my-game
python pack/targets/ohos/cli.py --config D:/private/ohos.json prepare --key my-game --source D:/games/my-game.nsp
python pack/targets/ohos/cli.py --config D:/private/ohos.json oneclick --key my-game --source D:/games/my-game.nsp
```

`patches` 只核对本地原始 Title ID、模块 Build ID 和补丁哈希，不改游戏、不操作手机。`--prepare-copy` 可生成独立 NSO 候选供检查，仍不会改写、签名或装机。

`prepare` 与 `prepare-extracted` 自动选择版本匹配的静态补丁；支持十六进制 PCHTXT、IPS/IPS32（含 RLE）。`--fps native` 关闭帧率补丁；`--aspect 21:9` 只请求这个比例，其他比例不代替；`--no-patches` 关闭补丁。重叠且内容不同的代码补丁全部拒绝，原因逐项写入任务日志中的 `patch-plan.json`。

`oneclick` 完成准备、签名壳构建和分离资源包，输出 `oneclick-manifest.json`。显式加 `--install` 才执行覆盖安装和资源导入，操作前请在游戏内保存退出。已有同版资源只传新增的程序目录，核原始 main 的 SHA256 后最后切换 `ready.json`，不删除旧程序或存档。此增量安装路径仍需真机验收。

改写复用键包含原始模块内容、补丁内容、OHOS 目标、改写器和载体生成器。完成产物必须逐项哈希一致才能复用，不能只凭 `.patched.bin` 文件存在。新版本目录为 `ohos-<指纹>`。同 Build ID 的不同代码补丁变体使用同名签名库，工具禁止把它们同时装进一个壳，以免后复制的覆盖前一个。

直接导入以下格式会明确跳过：版本不符、压缩包在精简包中缺失、FPSLocker YAML、需要运行时写入的作弊码、romfs/HUD 资源适配。FPSLocker 的动态速度、过场限帧与注入逻辑不能用静态写字节替代。通过静态检查也不等于真机满60帧，画面比例/HUD/过场仍需游玩验收。未经匹配验证，保留原始画面比例与帧率。

CPU 检查：`python -m unittest discover -s pack/targets/ohos/tests -v`。其中 CLI 编排检查明确使用替身命令，不代表真实改写、编译或真机安装通过。

## 显式配方与精确屏幕比例

`patchRecipes` 或重复的 `--patch-recipe <本地JSON>` 接受独立补丁层的配方。工具源码不内置游戏身份、地址或资源。配方必须含 `schema: s2a.ohos.patch-recipe.v1`、`titleId`、至少16字节的 `buildId`、整个原始 main NSO 的 `originalSha256`、`kind`、来源和许可证；匹配失败整项拒绝，版本字符串不参与猜配。

画幅配方的 `kind` 为 `aspect`；每个 `sites` 元素包含 `offset`（映像偏移字符串）、`original`（原始A64字的8位十六进制）、`register`（目标浮点寄存器）。可选 `guards` 包含 `offset` 和原始字节 `hex`，用于保护邻接代码；`minAspect`、`maxAspect` 限制实际审过的比例范围。`--aspect 2848:1320` 或 `--aspect 19.5:9` 计算单精度宽高比，生成独立 `code-patches.tsv`。

改写器通过 `S2A_CODE_PATCH_TSV` 接收此表。每处只把一个指令替成分支；新分配的只读代码跳板加载浮点常数并回到原指令下一条，不挪用猜测的空白、不覆盖相邻函数、不修改通用层游戏地址。任一旧字不符就不输出映像。原始常量是否真为宽高比仍须先审数据流；全屏拉伸、投影增加视野、HUD/视频修正是不同验收项。

原始 PCHTXT/IPS 仍可用，但工具会拒绝连续覆盖越过已有 RET 后真实指令的情况。这类修改必须先独立审查并使用安全跳板。原始补丁“有匹配 Build ID”不是代码正确性的充分条件。

## 60帧运行表契约

`kind: fps` 配方还须包含 `fps: 60`、`requiresRuntime: s2a.ohos.fps.v1`、相对路径 `table` 和 `tableSha256`。直接执行 FPSLocker YAML 不受支持；须先核对实际版本指令与数据流，把所需事实表达为本工具支持的通用运行表。

`fps.tsv` 使用 iOS 的 `c word/adrp_slot/ldr_slot/bl_rec`、`slot`、`speed`、`present30 if slot`、直接 `w` 数据写入语义，并增加强制 `abi s2a.ohos.fps.v1`、`target 60`。`build` 必须是主程序16字节构建号。v1仅支持 main、32位整型或有限小数、32处直接数据写入；不执行任意脚本、指针追踪或未知行。所有改写点、槽初值、数据区范围先整组核验，未知或不完整契约直接失败。

OHOS逻辑键页固定16KiB，与物理页大小无关。线程键占低端，既有宽屏槽到2031；FPS只允许2032–2047。动态步长使用真实客体提交帧的单调时间间隔除以1/30秒，60帧时为0.5、30帧时为1；暂停、后台或超过1秒的间隔不作为游戏帧。过场标志可把呈现目标改回30。数据写入最多每100ms随真实提交执行，不新增后台轮询线程。

CLI把 `S2A_FPS_TSV`、`S2A_CODE_PATCH_TSV` 限定在这次改写调用范围，结束后恢复环境。原始 NSO 不改，配表随版本化代码目录进入资源包。签名 `main.fixups.tsv` 记录 FPS ABI 与表摘要；运行时必须验证缺失/错配，失败拒启，不能只开锁帧而跳过动态步长。含FPS载体的壳构建前会核引擎导出 `s2a_ohos_fps_abi_v1`。关闭帧率补丁需要重新选择对应原生帧率载体；不能靠运行时 `S2A_FPS=30` 忽略已经签入的代码修改。

资源元数据增加 `requiredRuntimeAbis`、`patchTables`、`presentationAspect`，但始终保留 `patchesGameplayVerified: false`，直到真机游玩验收。拥有60帧目标和完整动态步长契约仍不能证明手机达到60帧。

## 离线着色器 v2

`shaders` 已调用 `shader_package.build` 发布带stage256绑定和反射校验的v2库；旧v1产物必须重新翻译，不能换标签。资源消费位置约定为 `<游戏根>/shaders/vulkan`，其中保存 `shaders.index.json` 与它引用的不可变数据文件。此批只完成生成接口接线，不自动扫描全部游戏或传到手机，也不把可消费变体数当成直连整体就绪。

本轮可复现实验还包含实际改写器的合成输入正/负样本、缺省Apple产物逐字节对照，以及实际 `fps_ohos.c` 的Windows CPU步长/解析/摘要测试和官方OHOS ARM语法检查。真实游戏离线候选与游戏资料放仓外；不随本工具分发。手机画面、输入、物理、HUD和帧率仍需集中试玩。
