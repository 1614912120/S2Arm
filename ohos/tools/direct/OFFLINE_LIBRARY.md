# 鸿蒙离线程序库：M1/M2

从**同一游戏/程序目录、同一编译器 closure、同一设备 profile** 已经跑过的私有缓存导出，是不改 native 的最短路径。它免除已覆盖程序的现场翻译，不是 Vulkan 管线缓存，也不能保证未走过场景零编译。

## 运行时合同（56ba3203b）

- `graphics.v1.json`：OHOS 放在 ready.json 的 moduleDirectory 根。`profiles` 与 `files` 必须同为空或同非空；最多8个profile，每个声明profile必须有文件。空库不编造 `offline-target:` profile。
- `provider_vk.c` Prepare 依据实际设备caps与编译器合成live profile，`s2a_graphics_has_profile`精确匹配。Mate90/Pura X **不默认共用库**；只有完整profile相同且closure一致才可能复用，不能改目录名绕过检查。
- 查找路径：`<S2A_SHADER_REVISION_ROOT>/shaders/vulkan/direct/<directABI>/<profileHash>/<identity>.program`。`provider_vk.c:460` 将该root设为game_data_dir，OHOS实际是 `games/<key>/game`，**不是moduleDirectory**。描述文件仍放moduleDirectory。Pura X M3已用miss日志验证这个分离；把两者一起放程序目录会全miss。`debug.s2a.offline_root`可作诊断覆盖，但不能绕过描述文件profile声明。
- identity 是运行时 S2AI1 内容身份，包含ABI/profile/closure、完整源摘要和图形/纹理事实，不是stage-key短ID。仅凭compile request（已剥离图形头）不能重算它；导出工具保留cache文件名/头内identity，拒绝二者不符。
- `.program` 与私有缓存同为 S2APC1 v2：88字节头，magic8、version/header各u32、identity32、payload SHA256 32、payload长度u64，后接原始program JSON。全部小端。
- envelope为`s2a-direct-program-v1`；contentHash覆盖**嵌入content的原始字节**；stage SPIR-V也有摘要。不能通过重新序列化payload来“整理格式”。
- 描述文件 `files` 的 sha256 是整个容器摘要（不带sha256-前缀），size是整个文件长度。`gameContentRoot/moduleSetDigest`从该OHOS程序目录描述文件原样继承；它们不是Android pack index的算法，不能拿Android describe命令替代。
- 来源顺序：内存 → 离线 → 私有缓存 → 现场编译。offline fetch验证容器，`nvn_vk_first_draw_program_valid`进一步验证可消费性，成功后才增offline_adopt；缺文件/profile不匹配是miss，坏条目是reject并回退。库读取不回写私有缓存。
- `library.v1.json`是上游产库索引，不是native查找的必需项。缓存导出不伪造缺失的requestSha256，不生成该索引；直接列所有program。复用上游 `verify_descriptor_files`/`verify_program_files`，接受无索引库的同一合同。

源码入口：`android/tools/direct_library.py`、`native/direct/{graphics,offline_library,program_cache,provider_vk}.c`、`native/nvn/nvn_vk_draw.c`（native路径均在platforms/android下）。`graphics/tools/direct/lib_pack.py` 实际打包的是Metal的metallib/S2ALIB分片，不能给Vulkan直接用；Android direct_library的capture request/result是另一产库入口。本工具选择已跑过缓存，不调用编译器、不新增前端。

## 使用

先停游戏取得一致的缓存快照；导出整个指定closure缓存目录。不要混合不同title或不同profile缓存。目标HAP的closure须从**该包实际链接的**编译器身份取，不能从另一工作树的旧obj文件猜。

```powershell
python ohos/tools/direct/make_graphics_descriptor.py --game-root <game-root> --closure <linked-closure>
python ohos/tools/direct/make_offline_library.py build --cache <exported-cache-dir> --descriptor <module-root>/graphics.v1.json --profile <live-profile-hash> --closure <linked-closure> --out <new-overlay-dir>
python ohos/tools/direct/make_offline_library.py verify <new-overlay-dir>
python -m unittest discover -s ohos/tests -p test_offline_library.py -v
```

产物是独立暂存目录：根下graphics.v1.json，shaders下program；不含游戏文件。部署时将graphics.v1.json送到moduleDirectory，将shaders送到 `games/<key>/game/shaders`，不要把整个暂存目录复制到moduleDirectory。输入只读，拒绝覆盖已有输出、拒绝混合身份，不会静默跳过坏条目。descriptor原有离线清单由本次明确指定的缓存集合替换；不是增量合并命令。工具不自动推送/安装/改ready.json。

信任边界：缓存缺少title和完整identity原像，容器摘要只能证明一致性，**不能证明缓存属于给定游戏或证明程序计算正确**；调用者须提供同一会话来源。profile/closure匹配不等于着色器可在GPU执行。合成主机测试只验证格式/拒绝行为，M3真机仍需进行。

## M3验收口径与打包接点（打包未实施）

Pura X拿锁后先确认已有资源和程序目录；没有资源须先问用户，不能自行搬游戏。确认当前包closure/live profile，导出已热跑的缓存并生成库。保留原描述文件备份，库文件复制到game数据目录的shaders树；验证摘要后**最后切换程序目录中的描述文件**。恢复时还原描述文件，保留库/历史缓存。

公平冷启动对比无需删除缓存：两组均用 `DEBUG_S2A_NO_DISK_CACHE=1`；无库组另设 `DEBUG_S2A_NO_OFFLINE=1`，有库组关闭NO_OFFLINE。OHOS属性桥按大写/下划线映射这两个变量，Pura X上已验证私有采用为0、离线开关能改变来源。每组重启进程，固定存档/场景/温度/充电条件，至少3次，记录读档触发→第一世界画面、offline_adopt/miss/reject、compile_attempt/success及温度。不能以private_adopt代替offline_adopt，不能拿热缓存对照冷库。结束清空debug-env、停S2Arm、放锁。

真实缓存覆盖须多次冷启动复核：Pura X同存档多轮仍会产生新内容身份，不能以“一局已经进世界”推断库完整。新增identity即使SPIR-V或contentHash与旧条目相同，也不能直接复制改名：完整规范输入包含源摘要、图形状态和纹理事实，而私有缓存没有该输入原像。补库应从运行时实际生成的容器汇总；固定库再复测，报告每轮补编数。

真正打包需ToG交付后协调：描述文件进入moduleDirectory，shaders进入game数据目录；manifest/hash包含新文件，closure与HAP配套。`S2A_SHADER_REVISION_ROOT`保持指向game数据目录。不改 `pack/targets/ohos/cli.py`，不把库提交Git或发布到latest。


## 新身份库的纹理用量种子（ToC-4）

`e3f22be42`先按stage key查纹理用量，再构造程序身份。只复制.program不能复现首次启动查找；必须配套同一次停止会话导出的`tex-use.v1`。原生格式是12字节追加记录（8字节stage key、小端uint32 mask），重复键最后一条生效，全1表示保守回退，不能当作冗余删除。

```powershell
python ohos/tools/direct/make_offline_library.py build --cache <stopped-session-export> --descriptor <capture-descriptor> --profile <Pura-live-profile> --closure <linked-closure> --require-tex-use --out <new-overlay>
python ohos/tools/direct/make_offline_library.py verify <new-overlay>
python ohos/tools/direct/make_offline_library.py install-seed <new-overlay> --cache <target-private-cache> --target-descriptor <target-revision-descriptor> --profile <target-live-profile> --session-stopped
```

工具将种子去重后与`offline-seed.v1.json`放在overlay根目录，清单绑定descriptor原文字节SHA、closure、profile及种子字节数/SHA/记录数。它们不放入graphics.files（原生该清单仅允许program/library index），也不改原生格式。读取种子只接受完整记录且最多16384个不同stage key，错误不会静默丢记录。

`install-seed`是**启动前的本地部署步骤**：核对目标title/revision/closure/live profile及缓存目录名，将库种子与目标已有记录合并，已有记录优先（尤其保留运行时学到的全1回退）。旧文件先按内容摘要备份，写临时文件后原子替换，未改变则不写；不删除program、不清应用数据、不联系手机。调用者必须先停止目标进程并保持停止。源缓存、overlay、descriptor只读。

手机部署需要在持锁期间把真实目标tex-use及descriptor读到本机，按同名cache目录准备合并结果；将旧tex-use原样备份并检查未被并发改写，再送合并文件。新机没有tex-use时直接用已验证种子。必须在首次游戏启动前完成此步；不能只复制shaders然后声称新机已可用。当前未改应用导入器/pack CLI，不会自动随普通资源导入执行此步骤；接入自动打包/导入时应复用同一校验和合并语义。

本机主机测试验证格式、绑定、首装与合并，不证明真机采用率。`--require-tex-use`保证配套文件存在，不证明.program集合都来自新身份会话；仍须采用明确记录的同会话捕获集。不能给历史全量身份容器改名伪造新身份，也不能把Mate90种子/库充当Pura profile实测。


### 不把历史缓存误称为新库

新身份代码没有改变closure目录名，缓存中可能同时有历史全量身份和新身份。`build --program-identities <capture-identities.txt>`显式选择本轮捕获的完整identity（每行64位小写hex，不重复）；缺文件、非法ID均失败，不默默扩大成全目录。未提供该参数的历史build行为不变。

无清数据的捕获办法：在停止会话时建立时间标记，以`NO_DISK_CACHE=1、NO_OFFLINE=1`做一次当前版本的完整走动采集，收集此后实际写出的.program身份，再导出同会话tex-use；多轮清单取并集（去重后保存），记录标记和实际文件摘要。旧文件保留；首次全槽回退形成的条目可能仍在本轮清单中，它们是当前版本实际产物，不靠改名裁剪。随后固定库，打开离线、保持NO_DISK_CACHE=1做采用率验收。`dump_prog_dir`仅有512项、按32位前缀去重，不能当完整程序清单。
