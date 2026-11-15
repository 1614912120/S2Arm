# Mac 启动器界面规范

首页的深色画布、Manrope 字体和暖白色操作是整套界面的基准。工具窗口使用系统毛玻璃，卡片只增加轻微的明暗分层，保留首页背景的颜色与层次。

## 唯一入口

`Sources/NXLauncher/LauncherTheme.swift` 管理间距、字号、颜色、圆角、窗口尺寸与通用组件。`LauncherStyles.swift`、`LauncherCard.swift` 和 `LauncherDropdown.swift` 消费同一套 token。页面不再自行选择胶囊或矩形下拉框，也不在共享控件外叠加另一套宽度。

| 用途 | 规范 |
|---|---|
| 设置窗口 | 首选 820 × 700 pt，按当前屏幕可用空间收缩 |
| 表单 / 简短确认 | 首选 680 / 560 pt 宽，高度按内容或页面用途确定 |
| 页面左右边距 | 32 pt |
| 分组间距 | 24 pt |
| 卡片内边距 / 圆角 | 20 / 16 pt |
| 普通控件高度 / 圆角 | 36 / 10 pt |
| 设置行的操作列 | 220 pt，两个短按钮共用一列 |
| 摇杆组合操作列 | 40 pt 说明、40 pt 开关、124 pt 下拉框，间距共 16 pt |
| 主要出包操作 | 48 pt 高，使用同一按钮样式的突出尺寸 |
| 页标题 | 26 pt heavy |
| 弹出面板标题 | 18 pt bold |
| 分组 / 正文 | 14 pt，分组使用 semibold |
| 说明 / 按钮 | 13 pt，按钮使用 semibold |
| 补充文字 | 12 pt |
| 图标与文字 | 18 pt 图标槽，8 pt 间距，整体垂直居中 |

游戏封面、手柄示意图、品牌徽标和首页的主操作保留各自的内容比例，不套用普通设置控件的尺寸。

## 布局与交互

- 页头、滚动内容、底部操作栏分层；内容滚动时完成、取消、保存仍可操作
- 分组标题、设置行和分隔线沿用相同的卡片内边距，无状态图标时不保留空列
- 说明区允许换行，路径单行从中间省略，完整路径与选项可通过悬停或辅助功能读取
- 普通按钮和主要按钮共用高度、圆角、字号及图标间距，通过颜色表达主次
- 下拉列表由当前窗口持有，选择后关闭，不能出现在后面的主窗口
- 开关保留标准辅助功能语义；滑块支持鼠标、键盘、手柄和系统辅助功能调整
- 键位录入与清除是两个独立按钮，清除后只移除当前按键的绑定
- 首页搜索在控制栏内以 0.24 秒动画展开和收起，遵循减少动态效果设置；收起保留查询，清除后继续输入，Escape 或手柄 B 收起
- 首页窄于 1000 pt 时分组使用 40 pt 图标按钮并保留悬停与辅助功能名称，避免展开搜索后文字换行
- 首页按全部、已就绪、最近和收藏顺序切换游戏列表，已就绪只展示可在 Mac 直接启动的游戏
- 搜索框提供清除入口与可读的占位文字，输入框显示焦点边框
- 首次签名引导按步骤排版，Team ID 单独成区；填过 Team ID 后仍可收起引导
- 签名子区只缩进左侧，身份选择框和引导卡片的右边缘与父选项对齐
- 打开引导项目失败时在该操作旁显示原因，避免把错误写进其他窗口
- 确认页和升级列表使用有最小可见高度的滚动阅读区，短内容按实际高度排版，长内容不挤走操作按钮
- 手柄焦点按窗口和下拉菜单隔离；方向导航先将下一项完整滚入视口，再绘制焦点框，滚动或缩放后按实际裁剪边界更新
- A 操作当前焦点；弹窗底栏直接显示快捷键：Menu / Options 完成或确认、B 取消或返回、X / Y 执行标出的辅助动作，禁用按钮不响应快捷键
- 按键图标跟随最近操作的系统手柄；屏幕键盘 B 放弃输入，Menu / Options 提交，返回后恢复原控件焦点

## 材质

`launcherSheet()` 使用系统 `regularMaterial` 与弹层材质，主窗口使用 `LauncherWindowMaterial`，并清除原有不透明窗口底色。卡片使用 `launcherPanel()` 的轻微填充与边框，不在每行叠加模糊层。系统材质负责响应减少透明度和增强对比度。

这与 Apple 对[窗口内容材质](https://developer.apple.com/design/human-interface-guidelines/materials)及[自定义玻璃控件](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)的分层建议一致。

## 文案

说明用一句简洁的话表达，末尾不加中文或英文句号。必要的步骤使用编号，不把长段说明、输入框与多个操作挤在同一行。共享说明修改 `../../shared/experience.v1.json` 或 `../../shared/game_settings.v1.json` 的实际来源；Mac 私有文案修改 `l10n/zh.json` 和 `l10n/en.json`。

作业层返回的说明在展示时去掉末尾句号，原始数据与日志保留原文。文件路径、版本和技术标识按原样显示。

## 验证

在仓库根目录运行：

```sh
swift test --disable-sandbox --package-path launchers/macos/frontend --filter SettingsLayoutTests
bash launchers/macos/test_controller.sh
bash launchers/macos/test.sh
python3 launchers/macos/prepare_build.py
build/venv/bin/python3 launchers/macos/build_app.py
bash tools/contrib_check.sh --base origin/main
```

`SettingsLayoutTests` 使用原创、无游戏资源的夹具，检查中英文页面尺寸、操作边界、下拉选择、键位清除与保存、滑块调整、签名引导和文案规则。首页搜索还检查输入框属于原窗口、展开不新增窗口、查询保留、清除后保持展开，以及四种宽度下控制栏不越界或换行；签名布局在两种宽度下核对父子右边缘。前端测试已接入 `launchers/macos/test.sh`，独立核对发现数与完成数。设置 `S2A_SETTINGS_SHOTS` 可输出真实 SwiftUI 窗口截图；截图不代替交互测试。新增页面或变体时一并检查禁用、加载、失败、长名称与滚动状态。
