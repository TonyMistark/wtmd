# wtmd v0.5 规划 — 从来回切换，到原地继续

> v0.4 让 wtmd 写得出更厚的文档；v0.5 要解决的是「写厚文档时被打断」——`⌘/` 一次按键，视线与光标都回到文首，
> 于是写作者不再切、只敢待在一边。本版把「位置」还给写作者：切换无损，对照可分栏。

**状态**：进行中（开工 2026-10-17）｜ 前置：v0.4.0 已发布（2026-10-17，详见 [V04_PLAN.md](V04_PLAN.md)）

## 版本主题

| 特性 | 哲学落点 |
|---|---|
| 双视图无损切换 | 写作即排版——源码与预览是同一份文本的两面，来回看它不该付出代价 |
| 分栏对照 | 极简无干扰——需要对照时给两扇窗，不需要时仍是一扇 |
| 会话恢复（P1） | 本地优先——关掉再打开，书桌还是原样摆在眼前 |

依据：[WYSIWYG_EVAL.md](WYSIWYG_EVAL.md) 的结论——**不做完整 WYSIWYG**，先把「位置丢失」修掉；
WYSIWYG 的其余诉求（表格/图片的结构化编辑）继续等触发信号。

## P0 — 核心特性（本版本必做）

### 1. 双视图无损切换

**用户故事**：作为长文写作者，我在第 40 段按 `⌘/` 看效果，看完按回来，应该还在第 40 段，而不是从头翻。

现状（代码事实，v0.4.0）：

- `ContentView.detail` 用 `switch store.mode` 分别构造 `EditorTextView` 与 `PreviewView`
  → 两者是不同视图身份，切换即**销毁重建**（`ContentView.swift:230-276`）
- `PreviewView.makeNSView` → `Coordinator.reload()` → `loadHTMLString` 整页重载
  （`PreviewView.swift:20-24, 112-125`）→ 滚动位置必然归零
- 编辑器侧重建 → `selectedRange` 与滚动偏移一并丢失

**方案：显式记账，切回时回填**（不改成常驻双视图）

- 状态载体：`ViewStateKeeper`（新文件，`@MainActor final class`，存于 `DocumentStore` 或 Environment）
  - 预览：`(blockIndex, intraBlockOffset)` —— **不用 `scrollY`**。锚点取视口顶部第一个顶层块的下标
    （`#wtmd-content` 顶层子元素数 == 顶层块数，这条不变式已有测试守着）+ 该块顶部到视口顶部的像素差
  - 编辑器：`selectedRange` + `scrollOrigin`（`scrollView.contentView.bounds.origin`）
- 采集时机：切换**之前**（视图仍在）——`⌘/` 走同一条命令路径，在 toggle mode 前抓
- 回填时机：
  - 预览：`didFinish` 之后（DOM 就绪才有元素可量），用 `getBoundingClientRect()` 反算滚动
  - 编辑器：`makeNSView` 首次 layout 之后（`viewDidMoveToWindow` / 下一次 runloop），
    且**必须在打字机模式夹取生效之后**——否则会被 `constrainBoundsRect` 改回中部
- 边界：`generation` 变化（换文档）时**必须清空**锚点，否则新文档被滚到旧文档的位置
- 已知取舍：预览是整页重载，「回来」的那一帧会有一次白闪；本版不优化（真要快就走常驻，
  代价是 WKWebView 常驻内存 + 隐藏时的定时器节流，不划算）

### 2. 分栏对照

**用户故事**：作为要边写边看的人，我不想来回复按 `⌘/`，希望左边写、右边实时成文。

- 第三种模式：`ViewMode.split`（现有 `.edit` / `.preview` 之外）
  → 左侧 `EditorTextView`、右侧 `PreviewView`，中间可拖动分隔条（`HSplitView`）
- 预览复用现有增量渲染：`diff` + `generation` 已经在 `DocumentStore` 里，分栏只是让预览常驻可见，
  **渲染链路零改动**
- 窄窗口自适应：内容宽度 < 640pt（两栏各不足 320pt）时退回**源码单栏**——这是写作工具，
  先保住能写字的那一边，想看结果按 `⌘/` 一次就到；宽度恢复后自动回到分栏。
  阈值收在 `SplitLayout.showsTwoPanes(contentWidth:)`，纯函数、可测
- 命令与菜单：命令面板「分栏」+ `⌘⇧\`；大纲跳转同时驱动两侧（预览滚动 + 编辑器滚动到对应行，后者现有 `jump` 已支持）
- 风险：大文档输入时每键 250ms 防抖 → 预览增量替换的 JS 调用可能抖主线程。**必须实测**：
  用 5000 行文档在分栏下连续输入，记录 `evaluateJavaScript` 往返（超 16ms 记为一次掉帧）；
  劣化明显则给分栏加「预览延迟」档（例如 600ms），仍不引入后台线程渲染

## P1 — 会话恢复（本版一并做，用户已确认）

v0.3 起遗留的缺口，与 P0-1 的「位置记忆」同源——同一个账本，只是要落盘：

- 上次的工作区路径重启后自动恢复（`WorkspaceStore` 原本完全不持久化）
- 上次打开的文件 + 每文件的光标 / 滚动锚点（按 URL 存 `UserDefaults`，条目数上限 20，LRU）
- 文件被外部删除/修改的冲突处理：`mtime` 变化则提示「文件已在外部修改，重新载入？」，
  **不静默覆盖**
- 工作量：M ｜ 拆成两步：**alpha = 记住与恢复**，**beta = 冲突处理**

## P2 候选（开工时挑 1 项进 rc，其余继续顺延）

- ✅ 导出 Word（.docx）——本版 rc 已做：自研 OOXML + ZIP，零依赖
- 自定义快捷键（`CommandCatalog` 已有注册表，只需加一层用户覆盖 + KeyRecorder 视图）
- 主题社区页（README 收录社区主题链接 + `.wttheme` 目录索引）

## 基建与收尾

1. 发布链沿用 v0.3 定稿的 `make-app.sh` / `make-dmg.sh`（布局直接写 `.DS_Store`，背景图提示已中英双语）
2. **本版无新增内嵌资源**，`make-app.sh` 的资源包硬校验不变
3. 版本号照旧走 git tag → `make-dmg.sh`（`WTMD_LAYOUT_PY` 指向带 ds_store 的 Python）

## 里程碑

| 阶段 | 内容 | 预估 | 状态 |
|---|---|---|---|
| v0.5.0-alpha | 双视图无损切换 | 1 个工作日 | ✅ 完成（2026-10-17，#55 / PR #56） |
| v0.5.0-beta | 分栏对照（含性能实测） | 1–1.5 个工作日 | ✅ 完成（2026-10-17，#57 / PR #58） |
| v0.5.0-rc | P2 选定项：导出 Word | 半个工作日 | ✅ 完成（2026-10-17，#60 / PR #59） |
| P1-alpha | 会话恢复：工作区 / 上次文件 / 每文件位置 | 0.5 个工作日 | ✅ 完成（2026-10-17，#61 / PR #62） |
| P1-beta | 会话恢复：外部修改与删除的冲突处理 | 0.5 个工作日 | ✅ 完成（2026-10-17，#63 / PR #64） |
| v0.5.0 | 发布（tag + DMG + GitHub Release） | 半个工作日 | ✅ 完成（2026-10-17，tag `v0.5.0`） |

## 验收标准（v0.5.0 出口）

- [x] `⌘/` 来回切换后，预览停在原来的段落、编辑器停在原来的光标与滚动位置；换文档不串位置
- [x] 重开应用回到上次的工作区、上次那篇、上次那一段；文件在别处被改过/删掉时自动保存停下来等读者决定
- [x] 分栏模式下输入即时反映到右侧，分隔条可拖动，窄窗口自动降级且恢复后回到分栏
- [x] 分栏下 5000 行文档连续输入无明显掉帧（`SplitBenchmarkTests`：2520 块增量往返中位 3.0ms / 最慢 61.8ms）
- [x] 导出的 .docx 能被标准消费者打开：标题样式、列表编号、表格、图片、超链接关系齐全
- [x] 无损切换与分栏均**不得破坏**既有不变式：预览顶层子节点数、IME 组合、增量 diff、导出 HTML（Mermaid / 数学 / TOC 三套端到端用例全绿）
- [x] 单元测试全过（**254 项**），CI 双系统绿
- [x] README / PRODUCT / 本文档同步

## 进度日志

- 2026-10-17 启动：本文档创建。v0.4.0 已于同日发布（[TOC] + KaTeX + 更新检查 + WYSIWYG 评估）；
  本版 P0 直接取自 [WYSIWYG_EVAL.md](WYSIWYG_EVAL.md) 第 5 节的建议（先修「位置丢失」，再谈 WYSIWYG）
- 2026-10-17 **v0.5.0-alpha 完成**（#55 / PR #56）：双视图无损切换——
  - 新增 `PositionMemory`（`Sources/wtmd/PositionMemory.swift`）：视图之外的记账本，
    `generation` 换代即清空。**故意不加 `@MainActor`**——两个 coordinator 本来就在主线程，
    加隔离只会把 AppKit 的 delegate 回调逼成 async 跳转
  - **预览记「顶层块下标 + 块内偏移」，不记 `scrollY`**：reload 后布局可能位移，
    像素值没有意义；块下标依托「`#wtmd-content` 子元素数 == 顶层块数」这条既有不变式
  - 锚点回报与大纲同步**分成两条通道**：大纲要扫全部标题（120ms 防抖），锚点用 rAF 每帧新鲜
    （读者可能刚滚完就按 ⌘/）；原生侧按 body 里的 `anchor` / `slug` 键分派
  - 编辑器记「选区 + clip view 原点」，靠覆写 `TypewriterClipView.setBoundsOrigin` / `scroll(to:)` 回报；
    回填排到下一次 runloop（`updateNSView` 时视图还没布局，零高度会把滚动夹成 0）
  - **两个坑**：① 回填期间必须关掉居中动画（`isRestoring`）——建视图那一拍窗口不稳，
    动画代理会踩空；② 只有 `window.isVisible` 才允许动画，离屏窗口上跑 `animator()` 会在
    窗口先销毁时留下悬空图层引用，让 AppKit 在后续帧里 SIGSEGV（测试进程实测踩到）
  - 测试 189 → **200**（PositionMemory 4 + 预览锚点 E2E 4 + 编辑器回填 3）；
    反向验证三组：停用 `__wtmdRestoreAnchor` → 锚点用例 2 处红；停用 `applyStoredPosition` →
    2 条红；`startSession` 不清位置 → 2 条红
- 2026-10-17 **v0.5.0-beta 完成**（#57 / PR #58）：分栏对照——
  - `ViewMode` 增加 `.split`；`⌘/` 仍只在思绪⇄成文之间走（从对照按下去回**思绪**），
    `⌘⇧\` 进出对照。命令进 `CommandCatalog`（菜单与面板同源），`isOn` 报 `mode == .split`
  - `ContentView` 拆出 `editorPane` / `previewPane` / `splitPane` 三个视图：分栏用 `HSplitView`，
    两侧同一批绑定与 `PositionMemory`，渲染链路零改动（预览本来就靠 `diff` + `generation`）
  - 大纲跳转在对照下**同时驱动两侧**；大纲高亮在对照下跟光标（源码是当下的注意力所在）
  - 窄窗口（内容 < 640pt）退回源码单栏：写作工具先保写作，看结果按 `⌘/` 一次就到。
    **推翻了本文档初稿的「保留预览」**——那样窄窗口下根本没法打字
  - **性能实测**：`SplitBenchmarkTests` 在真实 WKWebView 里跑 20 次增量（2520 块），
    JS 往返中位 **3.0ms** / 最慢 61.8ms。分栏不新增渲染路径，与预览模式同价；
    该用例定位是「复杂度退化警报网」（全量重排会让中位跳到几百毫秒），CI 上的绝对耗时不作性能口径
  - 测试 200 → **211**（模式规则 7 + 窄窗判据 2 + 分栏增量基准 1，另含 1 条光标归位）
- 2026-10-17 **v0.5.0-rc 完成**（#60 / PR #59）：导出 Word（用户在 P2 候选中选定）
  - **零依赖 OOXML**：`ZipWriter`（stored，固定时间戳 → 输出可复现）+ `DocxExporter`
    （`[Content_Types].xml` / `_rels/.rels` / `word/document.xml` / `styles.xml` / `numbering.xml` / `docProps/*`）
  - **覆盖**：标题 1–6（真样式，Word 导航窗格可跳）、段落、粗体/斜体/删除线/行内代码、链接（外部关系）、
    本地图片（内嵌 media，超过版心 451pt 自动缩放）、无序/有序列表（numbering 定义 + 任务项勾选框）、
    引用、围栏代码块（等宽 + 底纹 + 保留换行）、表格（边框/表头底纹/列对齐）、分隔线
  - **明确不做**：`$…$` 数学与 Mermaid 输出为原文（Word 里那是域或图片）、`[^1]` 脚注保留原文
    （解析器的脚注定义未暴露）、`[TOC]` 不生成（Word 目录应当是域，写死一份反而误导）
  - **内联自带子集解析**（`DocxInline`）：不复用 HTML 渲染器——那条路径产出 HTML 字符串，
    反解回 run 更脆（`<input>` 之类不是合法 XML）；反斜杠转义按「奇数个反斜杠 = 转义」判定
  - **两个小坑**：① 解析器把缩进列表项拍平成同级（预览也如此），导出刻意与预览一致，不额外造嵌套；
    ② `unzip -p` 会把 `[Content_Types].xml` 的方括号当通配符——测试改用 `ditto -x -k` 解包
  - **外部验证**（不只自测）：`textutil` 能读出全部文本与行内格式；`python-docx` 确认
    `Heading 1/2` 样式、`numId=1/2`、表格单元格内容全部正确（textutil 把 ol 显示成 ul 是它自己的映射粗糙）
  - **反向验证的重点在「转义」**：去掉 `escape()` 后只有新加的 `paragraphTextIsXMLEscaped`
    会红（XML 解析器报 `xmlParseEntityRef: no name`）——原有 docx 用例的样例文本里没有
    `& < >`，守不住这条。少转一个字符，整份 `document.xml` 就不再是合法 XML
  - 测试 211 → **226**（docx 14 + 命令注册 1）
- 2026-10-17 **P1-alpha 完成**（#61 / PR #62）：会话恢复——工作区、上次文件、每篇文档的位置
  - `Session`（`Sources/wtmd/Session.swift`）把整份会话存成**一个 JSON blob**：
    workspace 路径 / 展开的目录 / 当前文件 / 每篇的 `Position`（选区 + 滚动 + 块锚点 + mtime）。
    散成一堆 key 的话「没有会话」「旧版本写的会话」这两件事没有一处可以集中判断
  - **上限 20 + LRU**：打开过一个几百篇的文件夹之后，记录不能无限长；重新读过的一篇要提到最前，
    否则常看的那几篇会先被淘汰（FIFO 就会）
  - `Session` 注入 `UserDefaults` 与时钟，`DocumentStore` / `WorkspaceStore` 的 `session` 参数默认
    `nil`——**测试绝不可能碰用户真实的会话**，也就不会出现「跑一遍测试，下次启动落到临时目录」
  - **位置靠「种子」穿过 `startSession` 的清空**：视图只在建起来时调 `startSession`，而它换代就
    清空账本。`PositionMemory.seed(_:for:)` 把要回填的位置挂在那一代上，`startSession` 认领后即用；
    种子属于别的代数就丢弃（两代之间可能连换两篇文档）
  - **顺带修好一处「回填只做一次」**：`restorePositionIfNeeded` 原本一辈子只跑一次，于是从树里
    点开另一篇永远落在文首。改成按代数各跑一次，切回已读过的文件就回到当时那一段
  - 落盘只走既有四条路径（切文档 / 新建 / 关窗 / 退出），**不写进滚动回调**：每帧写
    `UserDefaults` 既没必要，长文档里还会拖慢滚轮
  - **一个坑**：`WorkspaceStore.open` 会先 `close`（顺手清空并落盘展开状态），恢复时必须
    **先把展开集合取出来再 open**，否则读到的永远是刚被清掉的那份
  - 测试 226 → **244**（会话 7 + 恢复 9 + 编辑器 2）；反向验证三组：停用种子认领 → 2 条红、
    回填退回一次性 → 1 条红、`flush` 停用 → 会话 4 处红
- 2026-10-17 **P1-beta 完成**（#63 / PR #64）：外部修改与删除的冲突处理
  - 问题不是「打开时文件变了」（那只是读到新内容），而是**自动保存在替读者写盘**：
    同步盘回写、另一个编辑器、`git checkout` 之后，下一次防抖落盘就把别人的版本盖了
  - 判定放在**真正要写盘的那一刻**（`persist` / `save`），不是每次按键：早查会在读者
    犹豫的时候反复报同一个冲突
  - 冲突期间 `externalChange` 非空，自动保存一律不写；**⌘S 也走同一条路**——
    它同样是写盘，同样不该静默盖掉别人刚写的版本
  - 界面是**非模态横幅**（`safeAreaInset(edge: .top)`）：写作工具最不该做的事是在句子
    中间抢走焦点，弹窗恰好会。修改 →「载入磁盘版本 / 保留我的修改」；删除 →「留作草稿 / 另存为…」
  - 冲突没解决就关窗/退出：磁盘不动，本地版本写进草稿并解除 openFile —— 下次启动以未命名
    文档出现，总比随窗口一起蒸发好
  - **`URL.resourceValues` 会缓存资源值**：写完再 stat 拿到旧的 mtime，于是「自己刚写的」
    和「被别人改过」永远分不清（实测同一路径两次读到相同值，还出现过 6ms 漂移）。
    改用 `FileManager.attributesOfItem(atPath:)`
  - **反向的守门用例**：`anOrdinaryAutosaveRaisesNoConflict` 守住「写完刷新基线」——
    忘了刷新的话每一次自动保存都会被判成冲突，横幅再也关不掉，比不检测还糟
  - 测试 244 → **252**（冲突 8）；反向验证：去掉 `persist` 里的写前检查 →
    `autosaveRefusesToOverwriteAnExternalEdit` 在「磁盘还是别人的版本」这条断言上变红
  - 已知边界：冲突未解决时**切换文档**，本地版本会被丢弃（只有退出路径做了保全）
- 2026-10-17 冲突横幅收尾：抽成独立视图 `ConflictBanner`，并用 `ImageRenderer` 渲染成
  位图做快照用例（尺寸、颜色层次），PNG 留在 `/tmp` 供人眼复核——断言「有这两个按钮」
  证明不了「看起来像条横幅」。测试 252 → **254**
