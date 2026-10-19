# v0.10 — 多窗口

**状态**：进行中（2026-10-19 立项）｜ 前置：v0.9.0 已发布（2026-10-19，详见 [V09_PLAN.md](V09_PLAN.md)）

## 一句话

v0.9 把「成文的那一半」补齐了。v0.10 动的是**架构**：一间书房，可以开几张桌子——同时开两篇稿子对着写，是写长文的人最先要的东西，也是产品文档里挂了最久的「未立项」。

## 现状（立项前核实）

- `DocumentStore` + `WorkspaceStore` 在 `wtmdApp.init` 里各建一份，全应用共用：第二个窗口只能显示同一篇文档
- 菜单 / ⌘K 面板直接引用这两个 store，没有「哪扇窗」的概念
- `Session` 是单份 JSON blob：谁最后落盘谁赢
- 草稿只有一份 `draft.md`：两扇窗各写各的未命名稿，会互相覆盖

## alpha — ⌘N 开出真正独立的第二个窗口

- `WindowModel`：一扇窗口 = 自己的 `Session` + `DocumentStore` + `WorkspaceStore`（`fileEvents` 接线不变，每窗一条）
- `SharedAppEnvironment`：应用级一份。主题 / 打字机与专注 / 版式 / 打印 / 更新检查 / 快捷键改派 / 字数账本 / 最近文件 / 冲突库——设置是应用的，不是窗口的
- 场景：`WindowGroup(id:)` 主窗口 + `WindowGroup(id:for:)` 第二扇窗；`openWindow` 由窗口里的隐藏视图捕获进 `WindowCoordinator`
- 菜单与命令作用于**前台窗口**：`@FocusedValue(\.windowModel)` 取当前窗口，取不到用 `NSApp.keyWindow` 认窗口，再取不到回退主窗口
- ⌘N 改为「另起一桌」：新窗口使用 `Session(persist: false)` 的临时会话，空白页起步，不覆盖主窗口的记录
- 新窗口接着用当前窗口的文件夹（同一间书房，另一张桌子），但打开的是自己的稿子
- 新窗口的草稿落在 `…/wtmd/windows/<id>/draft.md`：两份 `draft.md` 写在一处，谁最后落盘谁赢
- 第二扇窗在退出时不留记录（系统的窗口恢复也关掉）：按窗口记账是 beta 的事
- 关窗即结束：监听停掉，模型从窗口表里划掉；主窗口不在此列（它的会话要留给下次启动）

## beta — 会话与草稿按窗口记账

- `Session` 支持多份记录（按窗口 id），重启恢复**每一扇**窗口（含位置）
- 窗口关闭即结束该窗口的会话记录
- 「在访达中打开」「打开文件夹」等针对工作区的命令明确作用于当前窗口
- 临时窗口的草稿归属：恢复时把未命名稿放回它那扇窗，而不是全堆到主窗口
## rc — 收尾

- 拖出分栏预览成独立窗口？或先不做（评估）
- 冲突副本 / 字数统计在多窗口下的口径（净增账本按窗口合并）
- 界面英文化补全 + 文档 + 发布

## 边界（这一版不做）

- 同一篇文档在多扇窗口里同时编辑（没有协同层，只会互相盖）
- 逐屏布局记忆：只记窗口外框，拔掉外接屏后挪回可见区，不按屏幕分别记
- 标签页（Tab）式窗口

## 验收（alpha）

- [x] ⌘N 开出第二个窗口，两边是独立文档，互不串内容
- [x] 菜单 / ⌘K 命令作用于前台窗口（FocusedValue → keyWindow → 主窗口 三级回退）
- [x] 两扇窗各写自己的草稿目录，注销后不会互相覆盖
- [x] 两扇窗打开同一文件夹里的不同文件，各开各的，侧栏与文档互不串线
- [x] 退出再开，主窗口恢复上次的会话
- [x] 关掉第二扇窗，模型与目录监听一起结束；主窗口的会话不受影响

## 验收（beta）

- [x] 两扇窗各开一篇，退出再开，两扇都在、各是各的稿子
- [x] 恢复的窗口带着工作区、当前文件、光标位置
- [x] 窗口位置按账本摆回；记下的位置已不在屏幕上时挪回可见区
- [x] 关掉第二扇窗 → 账本与它那条会话记录都没了
- [x] 关掉一扇只有无名稿的窗 → 下次启动回来；再关一次才消失
- [x] 主窗口的记录不受任何窗口开关影响

## 进度

| 阶段 | 内容 | 估时 | 状态 |
| --- | --- | --- | --- |
| v0.10.0-alpha | ⌘N 开独立窗口，偏好共享，命令按窗口路由 | 1 个工作日 | ✅ 完成（2026-10-19） |
| v0.10.0-beta | 会话与草稿按窗口记账，重启恢复每一扇窗 | 1 个工作日 | ✅ 完成（2026-10-19） |
| v0.10.0-rc | 收尾、英文化、文档、发布 | 半个工作日 | 待开工 |

## 落地记录（alpha，2026-10-19）

- 新增 `WindowModel` / `SharedAppEnvironment` / `WindowCoordinator`（`Sources/wtmd/WindowModel.swift`）与 `WindowRoot`（`Sources/wtmd/WindowRoot.swift`）
- `Session` 增加 `persist` 档：不读也不写；`DocumentStore` 的 `themeManager` / `recentFiles` 改为注入，窗口之间共用一份
- 菜单整体搬进 `AppMenus: Commands`，靠 `@FocusedValue` 找前台窗口
- 顺手修掉一个真 bug：`writeDraft` 不建目录——第二扇窗的草稿目录尚不存在时，`try?` 把失败咽了下去（静默丢字）
- 探针实测（`WTMD_WINDOW_PROBE`，已删）：`openWindow` 捕获成功、第二扇窗 `restorable=false`、与主窗错开 32pt、关窗后窗口表从 2 回到 1
- 测试 583 → **596**（新增 `MultiWindowTests` 13 条）

## 落地记录（beta，2026-10-19）

- `Session` 支持按窗口记账：主窗口沿用 `wtmd.session`，其余各存 `wtmd.session.window.<id>`；`endRecord()` 删键并**封口**（关窗时退出观察者还会记一次位置，不封口就等于刚删又写回一条空记录，下次启动多出一扇幽灵窗）
- 新增 `WindowLedger`（`Sources/wtmd/WindowLedger.swift`）：窗口 id + 外框 + `parked`，JSON 存在 `wtmd.windows.v1`；重复 id 在读取时收敛，整本坏掉就当没有
- 恢复在 `WindowCoordinator.restoreWindows()`：`openWindow` 到手（窗口里的隐藏视图报到）后，按账本逐扇造模型再开窗；幂等，重复报到不会重复开
- 恢复的窗从**自己那条记录**起来，不被白纸盖掉：`startsBlank` 只给 ⌘N；什么都没留下的窗给白纸而不是欢迎页
- 窗口位置：恢复时照账本摆回，`Frame.fits(in:)` 要求与某块屏幕有 ≥120×80 的重叠，拔了外接屏就退回错开摆法；拖动/缩放停下来 0.4s 记一次
- 关窗即结束：`endRecord()` + 账本删除 + 草稿目录删除；**例外**是还欠着一篇无名稿的窗——第一次只留 `parked`，下次启动放回原处，再关一次才真删
- 开窗通道从 `OpenWindowAction` 改成 `((UUID) -> Void)` 闭包：`OpenWindowAction` 没有公开构造器，测试没法造一个假通道
- 探针实测（`WTMD_RESTORE_PROBE`，跑完已删；先备份真实 defaults，收尾原样放回）：seed 开两扇窗写草稿并记位置 → 重启后 `visibleWindows=3 models=3`，两扇副窗帧 `(160,220,900,700)` / `(240,220,900,700)`，文字各是各的，`PROBE cleaned` 后 defaults 里只剩 `wtmd.session`
- 测试 596 → **613**（`WindowLedgerTests` 8 条 + `WindowRestoreTests` 9 条）
- 反向验证五组全红：恢复也起白纸（7 处）/ 所有窗共用一条会话（9 处）/ 关窗不留一手（3 处）/ 不检查位置是否在屏幕上（3 处）/ 重复报到重复开窗（1 处）
