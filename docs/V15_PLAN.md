# v0.15 — 一处门：功能中心

**状态**：已发布（v0.15.2，2026-10-20）｜ 前置：v0.14.1 已发布（2026-10-20，详见 [V14_PLAN.md](V14_PLAN.md)）

## 一句话

写作日历、版本历史、设置、检查更新、报告问题都只活在菜单栏里，主界面散着主题和导出两个菜单。
想改一下写作目标，得先知道它在「设置 › 主题 › 写作」里——先猜位置，再找路径。

v0.15 把「应用级」的东西收到一处：**工具栏右侧一颗「功能中心」，点开一块浮面，
写作、外观、设置都在里面，行尾还把状态写出来**——今天写了多少、存了几个版本、
现在是哪个主题，不必点进去才知道。

## 现状（立项前核实）

- 写作日历只有菜单（⌘⇧Y）和状态栏那条目标徽标两个入口
- 版本历史只有菜单（⌘Y）；设置只有 App 菜单的 ⌘,
- 工具栏上有主题菜单、导出菜单——主题属于「换完就走」的偏好，占着常驻位置
- ⌘K 能搜到一部分（日历、历史、主题、更新、报告问题），但**没有设置**，
  而且命令面板不给状态——搜「日历」不知道今天写了多少

## 形态

工具栏最右一颗按钮（`slider.horizontal.3`），点开一块浮面（不是 sheet——
点一下就收，不打断正在写的那一段），从工具栏按钮下方摊开：

```
┌ 功能中心 ──────────────────────┐
│ 写作、外观、设置——都在这扇窗里 │
├────────────────────────────────┤
│ 写作                           │
│  📅 写作日历…   今日 +320 · 目标 1,000   ⇧⌘Y │
│  🕘 版本历史…   12 个版本                ⌘Y  │
│  ◎ 每日目标…   每天 1,000 字              │
│ 外观                           │
│  🎨 主题        wtmd 默认              ›   │
│  ☰ 阅读版式…   版心 680 · 17 px           │
│  🖨 打印设置…  页边距 18 mm · 页码开      │
│ 应用与帮助                      │
│  ⚙ 设置…                                ⌘,  │
│  ⌨ 快捷键…     出厂设置                   │
│  ↻ 检查更新…   v0.14.1 已是最新          │
│  💬 报告问题…                             │
│  💓 崩溃报告文件夹  还没有报告             │
└────────────────────────────────┘
```

## 口径

- **不新增存储**：日历、历史、更新的状态全部从现有对象读
- **每行一条既有命令**：面板不另立一套——`ControlCenterCatalog` 把
  `CommandCatalog` 的命令拷进行里，动作走同一条 `CommandRuntime`，
  标题、图标、快捷键只此一份，与菜单、⌘K 不可能说岔
- **工具栏减负**：主题菜单收进面板（`paintpalette` 不再出现在工具栏）；
  导出留在原地——它属于文档操作，不属于应用偏好
- **设置窗口保留**，但可直达对应标签页：`SettingsTab` 记在 defaults
  （`wtmd.settings.tab`），「阅读版式」「每日目标」「打印设置」先翻页再开窗
- **空态说人话**：没有文档时版本历史灰着；没记账时写「今天还没写」，
  不显示一个莫名的「+0」

## alpha — 目录与面板

- `ControlCenter.swift`：
  - `SettingsTab`（theme / shortcuts）+ `SettingsWindow`（先写 tab 再
    `showSettingsWindow:`，macOS 13 之前的名字也留着一条退路）
  - `ControlCenterRow`（action + 标题 + 副标题 + 图标 + 快捷键 + 可用性）
    与 `ControlCenterContext`（面板要显示的状态快照）
  - `ControlCenterCatalog.sections(_:)`：纯函数——给定状态与命令表，
    输出固定结构。副标题的每一句话都在这里，可以断言
- `ControlCenterPanel.swift`：视图只负责摆。行是两行式（标题一行、
  状态一行），悬停亮底、按下变暗

## beta — 装配与主题行

- 工具栏：功能中心按钮 + `controlCenterVisible` 浮层（透明挡板接住
  「点别处」，右上角摊开，阴影 + 圆角）
- 动作执行**先收面板、下一拍再跑**：日历、历史、崩溃都是 sheet，
  面板还挂在那儿的时候弹不出来
- 主题行是就地展开的列表（当前主题打勾，下面「打开主题文件夹…
  / 重新扫描主题」），不是 `Menu`——

  > **教训**：`Menu` 的 label 不吃自定义宽度（`frame(maxWidth:)`
  > 不生效），还会把支持多色的 SF Symbol 画成彩色，副标题整个丢掉。
  > 探针渲染两张 PNG 对比才确认：展开列表反而是面板自己的语言。
  > `ControlRowLabel` 里的 `symbolRenderingMode(.monochrome)` 同理，
  > 是给 Menu 时代留的保险

- ⌘K 补上「设置…」（`app.settings`，⌘,）：设置窗口从此也是一条命令

## 测试（23 条新增，总计 748）

- `ControlCenterTests`：分组与顺序、id 唯一、命令行的标题/图标/快捷键
  与命令表同源、副标题全部文案（今日/还没写/负数减号/版本数/目标/版式/
  打印/快捷键改派/更新四态）、无文档时历史灰着、检查中更新点不动、
  主题行不是命令、命令表缺一条时留灰行不崩面板
- `ControlCenterAssemblyTests`：读源码装配断言——工具栏上有功能中心
  按钮、`paintpalette` 已从工具栏消失、浮层里是 `ControlCenterPanel`、
  窗口注入了 `printing`、设置窗口记住了标签页
- 探针（临时，不入库）：`NSHostingView` 渲染面板 PNG + 真窗
  `CGWindowListCreateImage` 整窗截图，核对收起态与主题展开态

## 反向验证

- 历史行禁用去掉 → 「没有文档时版本历史灰着」红
- `openSettings` 从命令表删掉 → 「设置…进了命令表」与
  「引用的每一条命令都真的登记过」双红
- 行 id 去掉 key → 「每行的 id 唯一」红（三个设置入口撞车，实测撞过）

## 发布（v0.15.0，2026-10-20）

- issue [#139](https://github.com/TonyMistark/wtmd/issues/139) → PR
  [#140](https://github.com/TonyMistark/wtmd/pull/140)（CI 双绿一次过）→ tag `v0.15.0`。
- README：徽章 v0.14.1 → v0.15.0、测试 725 → 748、特性列表补「功能中心」、
  路线图补 v0.15。
- 面板每行都是 `CommandRuntime` 上的一条既有命令——这一版**没有新增任何能力**，
  新增的是「找得到」：11 行，三组，行尾写状态。
- 两次视觉验证各两轮（面板 `NSHostingView` 渲染 + 真窗 `CGWindowListCreateImage`），
  途中推翻过一版 `Menu` 主题行（label 不吃宽度、彩色符号、丢副标题）。

## 补丁（v0.15.1，2026-10-20）

发布当天读者报了两个问题：**面板里点「设置…」没反应**（`⌘,` 却正常），
以及**「关于」也该收进面板**（[#142](https://github.com/TonyMistark/wtmd/issues/142)）。

### 点了没反应

- 症状：功能中心点「设置…」什么都不发生；`⌘,` 能开。
- 根因：`SettingsWindow.open(_:)` 用的是 `NSApp.sendAction(Selector(("showSettingsWindow:")))`。
  这条 selector 在 SwiftUI 生命周期里并不可靠——**动作发出去了，没人接**。
  `⌘,` 之所以好使，是因为那是 SwiftUI 给 Settings 场景配的默认命令，
  跟我们的代码没有关系；之前没暴露，是因为从来没人从代码里开过设置。
- 修法：改用官方的 `@Environment(\.openSettings)`。命令层与面板拿不到环境值，
  所以由 `ContentView` 出现时把动作挂到 `SettingsWindow.install(_:)`，
  菜单、⌘K、面板三处共用同一个入口；AppKit 那条路留作没有环境时的回退。
- 顺带一处：面板的「阅读版式」「每日目标」「打印设置」原本是 `close()` 之后
  同步开窗。浮层正在拆的时候环境动作找不到落点——和 `.command` 一条规矩，
  改成下一拍。

### 关于也收进来

- 新命令 `app.about`（`CommandKind.about`）：打开系统标准 About 面板，
  图标、名字、版本由 AppKit 从 Info.plist 取，credits 写一句这是什么 +
  可点的仓库地址。
- 面板「应用与帮助」第一行是它；App 菜单的「关于 wtmd」换成同一条命令
  （`CommandGroup(replacing: .appInfo)`）——三处同源，⌘K 也搜得到。
- 「应用与帮助」从五行变六行：关于、设置、快捷键、检查更新、报告问题、
  崩溃报告文件夹。

### 测试

748 → **757**（+9：`SettingsWindowTests` 4 条 + 结构 2 条 + 装配 3 条）。

- `SettingsWindowTests`：opener 被调用且标签页写进 defaults；不指定页时用记住的那页；
  记住的值坏掉时落回主题页；没有 opener 时不崩（测试进程里 `NSApp` 是隐式解包的
  可选——原来那行 `NSApp.activate` 直接在这里炸了，顺手修掉）。
- 反向验证三组全红：去掉 opener 分支（三条测试红）、面板删掉关于行（两条红）、
  删掉根视图的 `install`（装配断言红）。

### 教训

**「点了没反应」比报错难查，因为它不留痕。** 从代码里开系统窗口，别赌 AppKit 的
私有 selector —— SwiftUI 提供了环境动作就用环境动作，拿不到就由根视图转交。

- issue [#142](https://github.com/TonyMistark/wtmd/issues/142) → PR
  [#144](https://github.com/TonyMistark/wtmd/pull/144)（CI 双绿一次过）→ tag `v0.15.1`。
  README 徽章 → v0.15.1、测试计数 → 757。

## 补丁（v0.15.2，2026-10-20）

读者接着报：**「每日目标」「阅读版式」「打印设置」点了也看不到效果**（[#146](https://github.com/TonyMistark/wtmd/issues/146)）。

这次窗口其实开了——问题是这三块设置本来就挤在「主题」页的下半截，点完停在最上面，
不往下滚什么都看不见。「设置…」和「每日目标…」打开的是同一页，看起来自然像没反应。

## 修法：一页一件事

设置窗口从两页拆成五页：

- **主题** — 选主题、来源 / 作者 / 外观、打开主题文件夹、重新扫描
- **写作** — 打字机、专注、每日字数目标（`SettingsTab.writing`）
- **版式** — 版心宽度、正文字号、行距、恢复默认（`SettingsTab.layout`）
- **打印** — 页边距、页码、第一页印文档名（`SettingsTab.printing`）
- **快捷键** — 原样不动

功能中心的三行各自指向对应的那一页，「设置…」仍打开上次停留的那一页。
五页统一尺寸（480×520，`SettingsPage`），切页不跳窗；拆页只搬控件，
默认值与行为一个都没动。

## 测试

757 → **758**。

- `settingsRowsPointAtTheirOwnPage`：三行（连同快捷键）各进各的页——谁再把它
  们改回 `.theme` 这条就红
- `settingsTabRawValuesAreStable` 补上新页的 rawValue（`wtmd.settings.tab` 键不动，
  老用户的选择照旧）
- 装配断言改为遍历 `SettingsTab.allCases`：设置窗口少任何一页都红
- 真机探针（临时，已删）：`SettingsWindow.open(.layout)` → defaults `tab=layout`，
  窗口 title `Layout`；`.printing` 同理——「点了落对页」这次有窗口级证据
- 反向验证两组全红：三行退回 `.theme`、窗口删掉写作页
- `NSHostingView` 渲染核对版式页：三个滑块 + 恢复默认，留白干净

- issue [#146](https://github.com/TonyMistark/wtmd/issues/146) → PR
  [#148](https://github.com/TonyMistark/wtmd/pull/148)（CI 双绿一次过）→ tag `v0.15.2`。
  README 徽章 → v0.15.2、测试计数 → 758。

## 补丁（v0.15.3，2026-10-20）

这一版把三件事叠在一起：两个读者报的问题，一次入口改版。

### 预览空白处右键弹「重新载入」

- 现象：预览区空白处点右键，弹出一个只有「Reload」一项的菜单。
- 查证：WKWebView **不走** `NSView.menu(for:)`——子类覆写返回 `nil` 的写法实测
  从未被调用（探针取证过），它自己维护一份内部菜单，只能在弹出之后拦。
- 修法：`PreviewContextMenu` 只装一次 `NSMenu.didBeginTrackingNotification`；
  判据是「非分隔项只有 1 项、没有子菜单、action 是 `forwardContextMenuAction:`」；
  命中就 `cancelTracking()`，而且**必须下一拍**——当拍撤销无效，菜单照样留在屏上。
- 选中文字时的完整菜单（拷贝、查询、服务…）照常弹出，判据不会命中。

### 别人喊停，不算崩溃

- 现象：一天里 8 份 `kind: terminated`，全是启动同一秒就「死掉」。
- 根因：`killall` / `pkill` 发的是 SIGTERM，走系统默认处理：`atexit` 与
  `willTerminateNotification` 都不执行，`.inflight-<pid>-<ts>.raw` 留在盘上；
  下次启动把它收成「上次没有正常退出」——报告里那句「没抓到现场」是字面意思。
- 修法三处：SIGTERM / SIGINT / SIGHUP 单独接住（处理器里只 `unlink` 预存的 C 路径，
  再 `SIG_DFL` + `raise`，进程照样当场结束）；收割前用 `isLiveSibling`
  （pid 活着 + 不是自己 + `proc_pidpath` 路径一致）跳过活着的兄弟实例；
  `.terminated` 的标题从 `[崩溃]` 改成 `[退出]`。
- 真正的崩溃路径一个字没动：`kill -9`、断电、签名异常照样上报。
- 真机对照（`CFFIXED_USER_HOME` 隔离 `Application Support`）：修复前 `kill -TERM`
  留 1 份现场、下次启动出 `kind: terminated`；修复后 0 份现场、0 份报告。
  两份实例并排跑也不再有误报。

### 功能中心 → 设置窗口

`ControlCenterPanel`、`ControlCenterCatalog` 与工具栏那颗滑块按钮一起退休：
360 pt 的浮层里摊三组十二行，再往里加东西就得滚，行数一多「点进去落在哪一页」
也越来越难猜。

- 新外壳 `SettingsShell`：左边一列功能、右边是选中的那一页，窗口固定 780×560，
  切页不跳窗。左侧顶部是**账户区**（头像 + 昵称），下面「写作 / 外观 / 应用与帮助」
  三组共六页——写作、主题、版式、打印、快捷键，加上新写的「应用」（版本、系统、
  立即检查更新、关于、崩溃报告文件夹）。
- 侧栏**不用 `List`**：macOS 26 的 sidebar 样式会把选中高亮涂到分组标题上（截图实证），
  改成自绘行，与旧浮层同一套按钮语言。
- 个人信息（只存本地）：`ProfileStore`——昵称进 `UserDefaults`
  （`wtmd.profile.nickname`），头像缩到 512 px 存
  `Application Support/wtmd/profile/avatar.png`。没设头像时画默认头像
  （昵称首字，再没有人像符号）。工具栏入口就是这枚圆头像，有昵称就并排写上；
  点它打开设置并落在「个人信息」页。
- 头像缩放走 `NSBitmapImageRep` 而不是 `lockFocus`：后者按屏幕 scale 出图，
  Retina 上 512 pt 会落成 1024 px，「存小一点」就白做了。
- 「关于」抽成 `AboutPanel.show()`，App 菜单、⌘K、设置页三处同一个实现。
- 各页去掉写死的 480×520，改成铺满右侧内容区。

### 测试

770 → **758**（`ControlCenterTests` 29 条随浮层一起退休，新增
`SettingsShellTests` 12 条 + `ProfileStoreTests` 5 条）。

- `SettingsShellTests`：分类顺序、每页各出现一次、`rawValue` 稳定、更新状态四句话；
  装配断言——自绘侧栏、七页齐全、设置场景用 `SettingsShell`、工具栏头像开 `.profile`、
  旧浮层与滑块图标已清。
- `ProfileStoreTests`：昵称读写与修剪、首字、头像存取删、坏文件不动旧值。
- 反向验证：判据恒 false → 红；去掉活体过滤 → 红；工具栏改回旧状态 → 红；
  设置场景不注入 profile → 红；头像不落盘 → 3 条断言红。
- issue [#150](https://github.com/TonyMistark/wtmd/issues/150) →
  PR [#151](https://github.com/TonyMistark/wtmd/pull/151)；
  [#143](https://github.com/TonyMistark/wtmd/issues/143) →
  [#152](https://github.com/TonyMistark/wtmd/pull/152)；
  [#153](https://github.com/TonyMistark/wtmd/issues/153) →
  [#154](https://github.com/TonyMistark/wtmd/pull/154)。三份 PR 各自 CI 双绿。
- tag `v0.15.3`。README 徽章 → v0.15.3，特性列表「功能中心」换成「设置窗口」，
  路线图补这三个补丁。

### 教训

**macOS 26 上 `CGWindowListCreateImage` 传自己的 windowNumber，拍到的是整块屏幕。**
系统会给玻璃效果的窗口配一块全屏背景窗，标题与尺寸都不属于「我的窗」。
真机取证改用「窗口框架落盘」（`NSApp.windows` 的 title / frame / toolbar 项数），
以后别再拿它当「截自己的窗」用。

## 补丁（v0.15.4，2026-10-21）

两个都不算功能，一个是反复被撞见的怪毛病，一个是打包链上的错位。

### 点 Dock 图标，窗口不上来

- 现象：点 Dock 上的图标，窗口不到最前面；有时点一下主窗口也一样。**「有时候又是好的」**。
- 根因：全仓没有一行激活相关代码——`NSApp.activate`、`applicationShouldHandleReopen`、
  `activationPolicy` 零命中，全靠系统默认。而系统只举「它记得的那扇窗」：那扇窗可能已经
  被 ⌘W 关掉（窗口没了、模型还在）、缩在 Dock 里（要 `deminiaturize` 才出得来）、是一张
  sheet（挂在别人身上，自己拿不出手）、或记着的位置落在屏幕外（拔过外接屏、改过分辨率）。
  关掉的设置窗还会留一扇 `isVisible = false` 的「wtmd Settings」。任何一条成立，点 Dock 的
  结果都是「菜单栏换了名字，屏幕上一个像素没动」——也正因为依赖状态，才会时好时坏。
- 修法：新增 `AppActivation`，把「举哪一扇」写成纯函数。优先级：最近一次成为 key 的那扇
  （且仍可见）→ 看得见的普通窗口 → 看得见的面板 → 缩着的（先 `deminiaturize`）；sheet 与
  `canBecomeKey == false` 的一律不参与。挑到就 `activate()` + `makeKeyAndOrderFront`，
  整个在屏幕外先 `center()`；一扇都挑不出来就走 `openWindow(id:)` 开回主窗——不把这件事
  留给系统。`AppDelegate` 由 `@NSApplicationDelegateAdaptor` 装进来，开窗闭包走
  `OpenWindowBridge`（与设置窗口同一条：场景环境只有视图拿得到）。
- 顺带两处：`applicationDidBecomeActive` 里若前台没有 key 窗，把看得见的那扇认作主窗——
  否则键盘焦点在别处，点哪儿都像「没到最前面」；`revealDocument`（跳到别窗里已有的稿子）
  原来只 `makeKeyAndOrderFront`，应用在后台时窗口只在自己层里往前提，人看到的还是别的
  App——改用同一套 `bringToFront`。
- 取证边界：本机沙箱里启动的 GUI 进程 `NSApp.isActive` 恒 false，`activate()` 也不生效，
  **激活本身只能由用户在自己的机器上确认**。留了一行轨迹
  `CrashBreadcrumbs.note("reopen hasVisible=… raised=…")`：这个毛病只在特定状态之后复发，
  下次看 `breadcrumbs.log` 就知道走到哪一步。

### 构建产物冒充「装好的应用」

- 现象：「Apps」（Spotlight 驱动）里搜 wtmd 出现两个条目——`/Applications` 里装的那个，
  和仓库里的 `dist/wtmd.app`。
- 根因：`make-dmg.sh` 用 `./make-app.sh dist` 把 app 拼在 `dist/` 下、做完不删；家目录下
  任何 `.app` 都会被 Spotlight 当成一份装好的应用（`mdfind "kMDItemFSName == 'wtmd.app'"`
  同时返回两条）。`lsregister -dump` 里还挂着一串历史残留：`dist/dmg-staging/`、
  `/Volumes/wtmd 1..3`、垃圾桶里十来个旧 staging 目录。
- 修法：打包改成在 `mktemp -d` 里拼装（`trap … EXIT` 收尾），`dist/` 只留最终的 dmg；
  `dist/` 与 `make-app.sh` 输出目录各放一个 `.metadata_never_index` 兜底——以后就算有人
  把 `.app` 丢回家目录，Spotlight 也整棵跳过。
- 对照实验：去掉标记再把 `.app` 放进 `dist/`，5 秒内就被收录；放回标记后同样的 `.app`
  等 20 秒也不收录。冒烟测试也随之改成「挂载 dmg → 跑卷内那份 app」。

### 测试

771（702 + 69）全绿。这一版没有改 Swift 的行为契约以外的模型：新增
`AppActivationTests` 13 条（挑窗规则 8 条、屏幕外判定 1 条、装配 4 条），其余不变。

- 反向验证：`lastKey` 不判可见 → 红；根视图不交接 `openMain` → 红；delegate 卸掉 → 红。
- issue [#156](https://github.com/TonyMistark/wtmd/issues/156) →
  PR [#157](https://github.com/TonyMistark/wtmd/pull/157)；
  [#158](https://github.com/TonyMistark/wtmd/issues/158) →
  [#159](https://github.com/TonyMistark/wtmd/pull/159)。两份 PR 各自 CI 双绿。
- tag `v0.15.4`。README 徽章 → v0.15.4，测试数 758 → 771，路线图补这两个补丁。

### 教训

**仓库里不留可启动的 `.app`。** 只要它躺在用户的家目录里，Spotlight 就会把它当成一份
装好的应用，「应用」列表里于是出现重名条目——而且删掉文件之后，`lsregister` 里的旧注册
还会残留很久。构建产物应该有「临时」的样子：临时目录、退出即清。

## 补丁（v0.15.5，2026-10-21）

### 关掉窗口之后，右键 Dock 图标没有入口

- 现象：主窗口按 ⌘W 关掉，应用还在（Dock 图标亮着），但点 Dock 图标不开窗；
  右键 Dock 图标只有系统那几项，没有任何能新建的东西。
- 两件事分开看：**点 Dock 图标不开窗**是 v0.15.4 修的（`AppActivation` 挑一扇
  可见的举起，全关光就走 `openWindow(id:)` 开主窗）；**右键没有入口**是这一版补的。
- 修法：`AppDelegate.applicationDockMenu(_:)` 给两条——「新建窗口」（显示 ⌘N）与
  「设置…」。前者走与 ⌘N 同一条路（`coordinator.openNewWindow(inheriting:)`：
  新会话、接着用当前窗口的文件夹），不是把旧窗举起来；两条动作都先 `activate`，
  否则 Dock 菜单选完焦点还在别处，新窗口会开在后台。
- 通道照旧由根视图（`OpenWindowBridge`）交给 `AppActivation.newWindow`——与
  `openMain` 同一条机制，因为 `openWindow` 只在场景环境里读得到。

### 测试

702 → 707（+69），新增 `AppDockMenuTests` 5 条：菜单两项与 ⌘N、每项都有
target/action、「新建窗口」调到新窗通道、通道没装上时退回主窗、「设置…」开设置、
根视图把通道交出去。反向验证：`applicationDockMenu` 返回 nil → 3 条红；
新建窗口不调通道 → 1 条红。

真机探针（临时，已删）：`NSApp.delegate=AppDelegate`、菜单两项；关掉全部窗口之后
点「新建窗口」→ 新窗口 `visible=true`。

### 教训

**`#require` 不要和同名局部变量放在一起。** `let menu = try #require(menu())`
在 CI 那套工具链上被解析成「`menu` 是个 NSMenu，不能调用」，本机新编译器的
解析顺序不同，所以本地全绿、CI 直接编译失败。测试里这类同名遮蔽对编译器版本太敏感，
辅助函数一律换个名字（`makeMenu()`）。

## v0.15.6（2026-10-21）——一个框搜全部

### ⌘K 升级成一个框（#170）

面板一次搜三类东西，三段结果、两级呈现：

- **命令**照旧（分组、模糊匹配、快捷键、别名）；
- **文件**段来自工作区树摊平，文件名命中永远高于只在路径里命中（评分减半），
  复用命令那套子序列评分——`c3`、`排版` 三个字就该把文件顶上来；
- **正文**段与 ⌘⇧F 同一台 `WorkspaceSearch` 引擎，但只摆 5 条、防抖 220ms、
  打字即取消；一行命中 + `文件:行号`。结果还有没摆下的，末尾一行
  「在工作区中查看全部」回车把词带进 ⌘⇧F 完整面板——完整面板没删，
  它是「展开后的样子」，不是另一个页面。

配套：

- 前缀收窄 `>` 命令、`@` 文件、`#` 正文；输入框右侧三颗小胶囊是同一件事的
  鼠标写法（点击即改写前缀，两者永远一致）。
- 空查询是「浏览」：命令按原本的分组摆，顶部「最近使用」、底部「最近搜索」
  （选中即填回）。两者**执行过的才记**（只打字不算），写 UserDefaults。
- `.wtmdignore`：工作区根目录的忽略清单——`#` 注释、`*`、`?`、`**`
  （`**/` 允许零层）、结尾 `/` 表示目录；不带斜杠的规则匹配任意层级。
  **枚举时剪枝**：被忽略的目录不读盘也不往下走。⌘⇧F 与面板正文段共用。
- 顺手修：面板卡片此前撑满整扇窗（`LazyVStack` 报不出理想高度，
  `ScrollView` 贪婪吃掉提议高度）——改普通 `VStack` + `fixedSize(vertical: true)`，
  卡片贴合内容。

### 入口补全（#164、#166）

- 设置 → 「写作」页新增「写作日历」一节（说明 + 「打开日历…」按钮）。
  日历是写作窗口上的 sheet，设置窗口是独立场景没有那份 store——入口反向走：
  `CalendarRequest`（present / pending / consume），窗口在当场摊开、不在先
  叫回来再兑现，同一次请求只弹一遍；另有一条 2 秒轻量轮询兜底。
- 工具栏主操作区最前面补一枚放大镜，点开就是命令面板；⌘K 由 toggle 改成
  「只开不关」——两个入口不互相打断，关它只有 Esc 和点空白处。
  占位文案改成「搜索命令、文件、正文…」。

### Dock 神灯动画（#168）

最小化收进 Dock 有动画、点 Dock 回来「啪」地出现：reopen 自己
`deminiaturize` 之后又 `makeKeyAndOrderFront`，把还没跑完的动画拽到终点。
修法：能当主的窗口**全缩着**时 reopen 返回 `false` 交回系统（只有系统那条
恢复路径带神灯动画）；半秒后仍无可见窗口就兜底自己举（系统只认「它记得的
那扇」）。自己动手的两处去掉多余的 `makeKeyAndOrderFront`。

### 测试

789 → 829（+40）：前缀解析 6、文件匹配 5、拼表 8、历史 5、忽略规则 12、
正文段异步 4，外加入口与神灯的装配断言。反向验证照例全红后复绿。
面板三段排版与卡片贴合用临时快照探针复核（用完即删）。

### 教训

- **`@State` 预填必须走 `State(initialValue:)`**：手写 init 里装好初值，
  `onAppear` 里赋值赶不上第一次触发的搜索。
- **探针等 MainActor 上的 Task 别用 `RunLoop.run`**——它不恢复挂起的任务；
  用 `try await Task.sleep`。

## v0.15.7（2026-10-22）——更新一步到位

### 一键更新（#173）

查出新版本之后，原先只能「跳去发布页，自己挂 dmg 拖进去」。现在点徽标
（或设置 →「应用与帮助」里的「现在更新…」）就把整条路走完：

- **挑包**：`UpdateChecker` 解析 release 的 assets，挑 version 对得上的 `.dmg`；
  字段缺失的 asset 直接跳过（GitHub 的 assets 字段并非全部必填）。
- **装**：`UpdateInstaller` 下载（256 KB 一块，1% 一步的进度）→
  `hdiutil attach -readonly -nobrowse` → 在 `/Applications` 旁边暂存
  `wtmd.app.update-<uuid>` → `xattr -cr` 摘掉 quarantine → 核对 bundle 版本
  （下错包就当失败，不拿错的东西顶替）→ 旧版进废纸篓（进不去就改名让路）→
  改名上位。
- 全程可注入（`Steps` / `Locations`）：测试不碰真的 `/Applications`，也不真下载；
  `run` 有重入保护，正在装的时候再点不会开第二条流水线。
- 装完先拉起新的一份再 `NSApp.terminate`——人看到的是「它自己重启了」。
- 零依赖：不引 Sparkle。

### 写作日历摊在哪扇窗（#175）

设置里点「打开写作日历」，会先冒出一扇**新的主界面**，日历还摊在新窗上。
根因是挑窗那一步用了 `window.isVisible`——而 **`NSWindow.isVisible` 对缩进
Dock 的窗返回 `false`**：主窗收在 Dock 里时被判成「没有窗」，兜底逻辑于是
开出重复的主窗（同一个 `primary` 模型），日历就落在新窗上。

修法：`AppActivation.calendarHost(primary:candidates:info:)` —— 缩着的窗也算数
（`isVisible || isMiniaturized`），主窗优先，主窗窗体不在（⌘W 关过）才从剩下的
窗里挑；sheet 与不能当主的窗不算（与 `pick` 同口径）。叫醒缩着的窗交给
`bringToFront`（它本来就会 `deminiaturize`，顺路仍是神灯）。日历记在**选中的
那扇窗**的账上，不再永远记主窗。

### 测试

829 → 851（+22）：一键更新 17 条（挑包、下载、挂载、装配、版本核对、
旧版让路、失败降级、重入保护）、日历挑窗 5 条（含「主窗缩在 Dock 里也算数」
的回归用例与装配断言）。反向验证照例全红后复绿。

### 教训

- **判「窗在不在」别用 `isVisible` 一个人**：它把「缩着」和「关了」混成一种
  状态。要按 `AppActivation.pick` 的口径——`isVisible || isMiniaturized`，
  再排掉 sheet 与 `canBecomeKey == false`。
- 兜底路径（`openMain`）会**开新窗**，所以「该不该走兜底」的判据必须准：
  判错一次，人看到的就是一扇凭空多出来的主界面。

### v0.15.8（2026-10-22）— 日历自己一扇窗

#### 从设置打开写作日历，设置窗被顶到后面（#178）

上一版只修了「另开一扇主窗」，但层次仍然不对：从设置点开日历，顺序变成
**日历 → 主窗 → 设置**。根子不在挑窗，在**容器**——日历是主窗上的 sheet，
而 sheet 挂在谁身上谁就跟着往前提，这是 macOS 的规矩。挑得再准，
「主窗被举到设置前面」也躲不掉。

修法：**日历独立成窗**（`CalendarWindow`，780×420，与面板尺寸一致）。

- 开它谁都不碰：不举主窗、不动设置。从设置点开，天然是「日历 → 设置 → 主窗」；
  从主窗 ⌘⇧Y 点开，主窗也不动。
- 只留一扇：再点一次把同一扇提到前面并刷新数据；Esc 可收；`setFrameAutosaveName`
  记住位置。
- 机器大扫除：`CalendarRequest` 的 pending/consume/等窗回来/openMain 兜底全拆，
  只留 `weak var coordinator`（`wtmdApp` 启动时装）+ `show()` 直读主窗那本字数账；
  #176 的 `calendarHost` 一并退休。
- 新隐患随手堵上：日历成了普通窗后可能被当成「主窗」举起来——`WindowInfo` 新增
  `isAuxiliary`（按 `window.identifier` 认），`pick` / `defersToSystem` 跳过它，
  Dock 图标永远举写作窗口。

#### 测试

851 → 847（-4，+7/-11）：`CalendarWindowTests` 3 条（单窗复用、**z-order 断言**、
附属窗身份）+ `CalendarRequestTests` 重写 3 条；sheet 账目与旧挑窗用例退休。

#### 教训

- **sheet 会强拖宿主窗到前面**：「从 A 窗打开的东西不该重排 A 之外的窗」这类需求，
  别用 sheet——独立小窗才是对的容器。
- **层次断言用 `NSApp.orderedWindows` 可写**，但先拿探针证伪（把主窗提到前面，
  断言立刻红）再信它测的是真层次。

### v0.15.9（2026-10-22）— 徽标一出现就闪退（#181）

装着 0.15.7 的人等来新版本，徽标「vX 可用」一渲染，应用直接 SIGTRAP。
轨迹里启动（11:09）与崩溃（12:46）隔着一小时三十七分——这本身就是线索：
崩的不是启动，是**徽标出现的那个瞬间**。

根因：`ContentView` 声明了 `@EnvironmentObject var installer`，但 `installer`
只注进了 **Settings 场景**；两个 WindowGroup 走的 `WindowRoot` 漏了它。
更刁的是它不崩在装上那天——徽标只在 `status == .available` 时才读
`installer.phase`，装 0.15.7 时 GitHub 最新还是 0.15.7（「已是最新」），
等下一个版本发布、状态一变，徽标一出现就崩。SwiftUI 对取不到的
EnvironmentObject 是 `assertionFailure` 级别的硬崩，没有软着陆。

修法两层：

- `WindowRoot` 补注 `.environmentObject(model.shared.installer)`；
- **装配守卫**（`WindowEnvironmentTests`，2 条）：从源码抓事实，`ContentView`
  声明的每个 `@EnvironmentObject`，`WindowRoot` 必须注入；反向也守——注入的
  必须是真读的。这类「声明 ⇒ 注入」的漂移，靠人记必挂，靠测试钉死。

顺手修了排查路上被带偏的半小时：崩溃报告的 `time:` 一直是**启动**时刻——
现场文件是启动时预建的，`harvest` 拿文件创建时间当崩溃时间。现在信号处理器
当场写一行 `t <unix秒>`（`gettimeofday` + 定长栈缓冲，零分配），`harvest`
优先信它，旧格式回退创建时间。

#### 测试

847 → 851（+4）：装配守卫 2（先在未修代码上红、点名 `["installer"]`）
+ harvest 时间戳 2。

#### 教训

- **EnvironmentObject 缺失不是警告，是 SIGTRAP**；而且「仅某分支才读」的依赖
  平时看不出来——装配守卫必须扫源码全量比对，不能靠哪次手气好没踩到。
- 崩溃报告里的时间字段要信轨迹别信单点：`time` 与「轨迹尾 - id 时刻」对不上时，
  先怀疑记录机制本身。

### v0.15.10（2026-10-22）— 开发版的现场不混进读者的账本（#147）

面板里出现「[Crash] wtmd did not shut down normally · vdev」：那是 `swift run`
出来的开发版，开发时被 `kill -9`、被重编译挤掉都是常态。隔离目录复现确认——
dev 二进制硬杀一次，下次启动就积一份「没有正常退出」。读者看到的是一行像
崩溃的记录，还会一路提交成 issue。真实机器上 15 份报告 9 份是 `dev`。

修法：

- 版本号是 `dev` 时账本落在 `crashes-dev/`，正式版仍是 `crashes/`
  （`CrashStore.directoryName(forVersion:)` 一个纯函数定规矩）。
- 正式版的面板不列 `version: dev` 的报告——文件留着，只是不显示，存量垃圾
  升级后自动从视野里消失。
- 开发版自己跑起来时过滤是关的（`hidesDevelopmentReports` 跟
  `CrashEnvironment.isDevelopmentBuild` 走），自己看得见自己的现场。

测试 851 → 855。反向验证：把目录名改回恒 `crashes`、去掉 reload 过滤，
两条用例当场红；端到端用真 dev 二进制硬杀后重启，报告确实落在 `crashes-dev/`。

#### 教训

- **开发产物和读者的数据必须分账**：dev 的崩溃、日志、临时状态混进正式目录，
  迟早会被当成「应用的 bug」。分账只要一个纯函数，比事后过滤便宜得多。

### v0.15.11（2026-10-22）— ⌘S 没反应（#186）

读者写稿按 ⌘S，什么都不发生；最后是在 ⌘K 面板里搜到「保存」执行，才把草稿写到磁盘上。
这类「一个入口好、另一个入口死」的 bug，代码读一遍是看不出来的——**得把真实菜单打出来看**。

探针（启动后 dump `NSApp.mainMenu`，用完即删）给的是这个：

```
DUMP [File] 4 items
  New Document | key=n
  ---
  Close | key=w
  Close All | key=⇧w
DUMP performKeyEquivalent(⌘S) = false
```

File 菜单里根本没有 Save，连同「打开…」「打开文件夹…」「版本历史…」「导出 HTML」
「打印」全都不在——不是禁用，是**不存在**。

根因：这一组挂在 `CommandGroup(replacing: .saveItem)` 上。`.saveItem` 只在文档型应用
（`DocumentGroup`）里由系统提供；wtmd 是手写窗口，`replacing` 一个**不存在的分组**，
SwiftUI 不警告、不报错，整组内容静默蒸发。同一个文件里 `.appInfo` / `.newItem` /
`.pasteboard` / `.sidebar` / `.help` 都真实存在，所以别的菜单一直好好的。

修法：换成 `CommandGroup(after: .newItem)`。File 菜单 4 项 → 13 项，
`⌘S` `⌘O` `⇧⌘O` `⌘Y` `⇧⌘E` `⌘P` 一起复活（`performKeyEquivalent(⌘S)` 从 false 变 true，
真的弹出保存面板）。

守卫（`MenuPlacementTests`，2 条）：源码里不许再出现 `.saveItem`，File 那一组必须列全
七条文件命令；菜单点名的每条命令都得在目录里查得到。

#### 测试

855 → 857（+2）。

#### 教训

- **「菜单里有这行代码」不等于「菜单里有这一项」**：`CommandGroup(replacing:)` 对不存在
  的分组是静默丢弃。凡是靠菜单承载的快捷键（`⌘S`/`⌘O`/`⌘P`…），都得有一次「把真实菜单
  打出来」的实测，不能只信 SwiftUI 不吭声。
- **守卫要判代码、不判注释**：第一版 `!app.contains(".saveItem")` 被我随后补的一行
  「别用 .saveItem」注释绊红，本地跑在加注释之前所以没发现（CI 抓到的）。现在先剥注释再判。
- 面板与菜单共用一个 `CommandRuntime`，只覆盖了「面板能跑」，**没有覆盖「键盘能到」**——
  这正是它能活到用户按下去才被发现的原因。

### v0.15.12（2026-10-22）— 改派的快捷键按不动（#189）

在「设置 › 快捷键」里给侧栏派了 `⌃L`：录入成功、列表显示 `⌃L`，按下去毫无反应。
两个根因叠在一起，都只有把真实菜单打出来才看得见。

**一、命令没有菜单项承载。** AppKit 的快捷键只由菜单项的 key equivalent 派发——
`toggleSidebar` 在目录里（⌘K 搜得到、点了能开合），却从没被摆进任何菜单。
同一个洞里还掉着 `toggleMode`（⌘/）、`closeWorkspace`、`openThemesFolder`、`rescanThemes`：
**⌘/ 切「思绪 ⇄ 成文」一直是哑的**。而设置页把目录里所有命令都列出来让人改派，
包括这五条根本没进菜单的。

**二、改完菜单不重建。** 补上菜单项之后 `⌃L` 还是不动。探针让它运行时改派、改完再 dump：

```
PHASE 1  Sidebar | key=- mask=0
ASSIGN   result=assigned stored=["view.toggleSidebar": ... "control"]
PHASE 2  Sidebar | key=- mask=0
```

SwiftUI 的命令菜单**只在启动时建一次**。两条路都试过、都不重建：`Commands` 里加
`@ObservedObject`；让 `wtmdApp` 自己 `@StateObject` 观察改派表（body 确实重算了）。
于是界面上那句「立即生效」是假的——得重启。

修法：

- 五条命令进菜单（视图三条、wtmd 菜单两条），顺手去掉 View 菜单开头孤立的分隔线；
- 新 `ShortcutMenuSync`：改派落盘时自己改 `NSMenuItem.keyEquivalent`。认命令项靠两条
  同时成立——action 是 SwiftUI 的 `menuAction:`、标题与目录逐字相同；系统项一个字不碰；
- 「设置 › 快捷键」只列**有菜单项承载**的命令（`CommandCatalog.menuCarriedKinds`），
  `assign` 也拒掉其余命令。`openSettings` 记进 `systemOwnedKinds`：App 菜单那一项由系统
  `Settings` 场景摆，⌘, 归它（试过 `replacing: .appSettings`，系统项照样在，变成两条并排）。

探针复测：`PHASE 2 Sidebar | key=l mask=262144`（control），`performKeyEquivalent = true`。

#### 测试

857 → 863（+6）：`MenuPlacementTests` 补一条「目录里每条命令都有菜单项承载」；
新 `ShortcutMenuSyncTests` 5 条（改派落到菜单项、恢复出厂、不碰别人的项、子菜单也到、
`persist()` 里确实调了写回）。反向验证各拆一次，都当场红。

#### 教训

- **快捷键 = 菜单项的 key equivalent**。命令写在目录里、面板里能执行，都不代表键位有人接。
  给命令加「可改派」之前，先确认它在菜单里。
- **SwiftUI 的命令菜单是一次性的**：改了快捷键相关的状态，菜单不会跟着重建
  （`@ObservedObject` 与 `@StateObject` 都不行）。要「立即生效」只能自己改 `NSMenuItem`。
- 界面文案承诺「立即生效」之前，先亲手验一次——这次那句文案骗了整整两个版本。

### v0.15.13（2026-10-22）— 侧栏开关按了像没按（#192）

用户把侧栏改派成 `⌥S`（之前是 `⌃L`）：键位录进了、菜单里也显示，按下去画面毫无反应。
「改派写回菜单」（#189）明明修过了，怎么又哑了？

#### 排查

给开发版挂上环境变量探针，把**真实菜单**摊开、用合成事件走完整派发链：

```
DUMP overrides={"view.toggleSidebar": {"key": "s", "modifiers": ["option"]}}
DUMP start    sidebar key="s" mask=[opt] state=1 enabled=true target=MenuItemCallback
DUMP handled=true
DUMP RUN view.toggleSidebar
```

菜单项带着 ⌥S、`performKeyEquivalent` 命中、`CommandRuntime.run` 真的执行了，
侧栏也真的收放了（前后两张截图对比可见）。快捷键那一环是好的。

真正的洞在 `ContentView` 的分栏绑定上：

```swift
get: { store.sidebarVisible ? .automatic : .detailOnly }
```

`sidebarVisible` 默认 true，而 `.automatic` 在窗口不够宽时让**系统**折叠侧栏——
状态却还是 true（菜单打着勾，探针里 `state=1` 而画面上侧栏是收着的，脱节实锤）。
于是按快捷键：true→false（`.detailOnly`，画面本来就没侧栏）；false→true
（`.automatic`，系统又把它折回去）。**怎么按都看不见变化**。
⌃L 修好哑键之后用户仍报无效，根子在这里——#189 修的是「键位没人接」，
这次是「接了也白接」。

#### 修复

```swift
get: { store.sidebarVisible ? .all : .detailOnly }
```

状态是唯一事实来源：开就显式展开（`.all`），关才收起。窄窗下侧栏不再被系统
悄悄折走；快捷键、工具栏按钮、菜单三项同一条路，全部即按即见效。

#### 测试

863 → 864（+1）：新 `SidebarVisibilityTests` 扫源码钉死「columnVisibility 别用
`.automatic`、必须是显式两态」（先剥 `//` 注释再判，沿用 MenuPlacementTests 的
教训）。反向验证：把 `.all` 拆回 `.automatic`，守卫当场红 2 条；恢复即绿。

#### 教训

- **「按了没反应」不一定是键位的问题**：先确认事件到没到（`run` 有没有执行）、
  再确认执行了画面动没动。这次两层各验一次，根因在第三层——状态与画面脱节。
- **`NavigationSplitView` 的 `.automatic` 不是「跟随状态」，是「系统说了算」**：
  想让布尔状态当事实来源，就写显式的 `.all` / `.detailOnly`。
- 截图是最好的判据：`state` 是谁的 state、画面上到底有没有侧栏，一对就知道谁撒谎。

### v0.15.14（2026-10-22）— 更新装完，人没回来（#195）

用户第一次用一键更新（0.15.12 → 0.15.13）：检查、下载、安装全部正常，应用也按要求退出——
**然后再也没打开**，得自己去 Launchpad 里点。

#### 排查

同 bundle id、同路径的小 app 复现「重启」那一步：

```
pid=3161 launch
pid=3161 openApplication returned pid=3161 error=nil
```

`NSWorkspace.openApplication` 的回调里拿到的 pid **就是自己**，日志里也只有一条 `launch`。
原因：新版本装的是同一个路径、同一个 bundle id，LaunchServices 认为这个 app 已经在运行，
于是只「激活」那个正在退场的实例，一个新进程都没起。而旧实现先 `openApplication`、
`sleep 0.5s`、再 `terminate`，正好把重启压在旧进程还活着的那个空档里。

#### 修复

把「等我们退干净，再开新版」交给一个**不 wait 的 `/bin/sh`**（父进程退出后被 launchd 收养）：

```sh
i=0; while kill -0 <pid> 2>/dev/null && [ $i -lt 75 ]; do sleep 0.2; i=$((i+1)); done
exec /usr/bin/open -n '<新路径>'
```

- `kill -0` 只探活不杀；pid 消失（我们真退干净了）才 `open`；
- 15 秒上限 + `-n`：旧进程卡着不退（冲突弹窗挡住退出）也强制起新实例；
- 路径单引号包裹，`~/Applications` 带空格也不会被拆成两个参数；
- 派生子进程被拒（沙箱）时退回 `createsNewApplicationInstance = true` 的 `openApplication`，
  宁可两个实例短暂并存，也不给用户一片空桌面。

探针复测（`new` 模式）：日志出现**新 pid 的 launch**（3161 退出 → 3236 → 3242 依次启动）。

#### 测试

864 → 868（+4）：新 `UpdateRelaunchTests`——脚本确实等旧 pid、等待有上限、路径含空格 /
单引号转义得住、`relaunch` 走派生重启器并留了强制新实例的退路。反向验证：把 `relaunch`
换回旧实现，守卫当场红。

#### 教训

- **「启动自己」不能用「打开这个 app」表达**：同路径同 bundle id 时，LaunchServices
  把它读成「已经开着」，你要的是一个新进程。要新进程就得在旧进程死透之后、
  或者显式 `-n` / `createsNewApplicationInstance`。
- 更新这种「自己替换自己再复活」的动作，测试里全是注入闭包，真实现从没跑过——
  注入是为了不碰真环境，但不能因此没人验；关键实现至少要有一条结构守卫 + 一次真机探针。

### v0.15.15（2026-10-22）— 翻译框架：语言成为数据（#198）

界面文案一直走 `t("English", "中文")` 双参函数，约 500 处调用。双语这件事
写在**函数签名**里——想加日语，就得改签名再动 500 个调用点。

#### 设计

把语言从签名里拆出来，变成数据：

- **英文即键**：调用点写 `t("Open")`。键是英文原文，英语本身不占翻译表，
  「翻不出来」的兜底就是英文——永远不会出现空白；
- **翻译表按语言一个文件**：`Translations+zh.swift` 一份
  `[String: String]`（330+ 条，由迁移脚本对账生成）；新增语言 = 加一个
  `Language` case + 建一个表文件 + 在 `tables` 里登记一行，调用点零改动；
- **插值走 `{}` 模板**：`t("Downloading {}%", fraction)`。查表发生在替换
  之前，各语言可以自行调整措辞语序；
- **context 拆同词异译**：`Source` 在编辑模式是「思绪」、主题页是「来源」，
  用 `t("Source", context: "mode" / "theme")` 拆成两个键，界面上英文不变；
- **设置 › 应用新增「界面语言」**：跟随系统 / English / 简体中文
  （`wtmd.language`）。菜单文案随 SwiftUI 命令在启动时构建（#189 的教训），
  标注「下次启动完整生效」。

#### 迁移

脚本机械改写 **390 处**（342 纯字面量 + 48 对称插值——插值表达式两参逐对
核对才转模板），人工收尾 **7 处**。顺手修了一个旧文案 bug：冲突归档的提示
中文带文件名、英文却没有——现在两边都带（模板补上 `{}`）。

迁移脚本自己也踩了一脚：无插值的 `"a" + "b"` 拼接串被错误用 `{}` 连接，
4 处英文键里混进假占位符（显示会是 `…outside {}(force quit…`）。已修，
并让覆盖守卫从此盯住这一类形态。

#### 守卫

新 `L10nCoverageTests`：一个懂代码 / 字符串 / 插值 / 注释的小状态机扫源码，

- 每张翻译表必须覆盖源码全部字面量键——新语言漏翻、调用点漏登记当场红；
- 旧双参 `t("…", "…")` 回潮、`+` 拼接键、键内插值（插值先求值，查表永远
  落空）一律红。

反向验证：删一条翻译 → 红；塞一处旧 API → 红；恢复 → 绿。

#### 测试

868 → 874（+6）：`L10nTests` 重写 5 条（解析顺序 override > 用户偏好 >
测试钉中文 > 系统、模板填充、context、查表先于替换）+ 覆盖守卫 1 条；
三处钉旧文案的源码守卫测试同步更新。开发版冒烟干净
（含 `-wtmd.language en` 强制英文启动）。

#### 教训

- **语言是数据，不是签名**：双语写在函数签名里，加一种语言就是一次全库
  改写。键值对表 + 覆盖测试，才能让「新增语言」退化成「新增一份文件」。
- **插值文案的键必须是模板**：Swift 字符串插值在调用点先求值，
  `t("Found \(n) items")` 的键是 `Found 3 items`，查表永远落空。
  模板（`{}` + 变参）把查表挪到替换之前，问题才成立。
- 守卫测试会被守卫对象绊倒（注释、字面量内部的 `+`）——扫描器必须真的
  懂这门语言，正则糊不上。

### v0.15.16（2026-10-22）— ⌥S 按第一次管用，之后 ß 进正文（#201）

用户把侧栏改派成 ⌥S：第一次按有效，之后每次都往正文里输入一个 `ß`，
命令不再执行。#189（改派写回菜单）、#192（侧栏绑定脱节）都修过了，
这次是第三层：**菜单派发对 Option-only 组合根本靠不住**。

#### 排查

上一回（#192）的探针直接调 `main.performKeyEquivalent`，显示「命中」——
所以这次把合成事件走**真实派发路径**（`NSApp.sendEvent`），并且聚焦正文：

```
DUMP focused textView=true
DUMP round1 textContainsSharpS=true  textLen=541→542  sidebar 不变
DUMP round2 textContainsSharpS=true  textLen=542→543  sidebar 不变
```

`ß` 直接进了正文，命令一次没跑。不聚焦正文时，同一事件时灵时不灵——
「第一次有效」就是这么来的。

#### 根因

带 ⌘ 的组合，菜单按 `charactersIgnoringModifiers` 匹配（"s"），稳定；
Option-only 的组合，某些派发路径拿**产出字符**（ABC 布局上 ⌥S 就是 "ß"）
去比——"s" 比不过 "ß"，事件落进文本视图 `insertText("ß")`。
文本视图在不在响应链上，决定了走哪条路。

#### 修复

不再指望菜单派发。新 `ShortcutKeyInterceptor`：启动时装**本地 keyDown
事件监视器**，事件进派发之前查改派表——

- 只接**改派过**的 Option 系组合（可带 ⇧）；⌘/⌃ 系菜单一直可靠，
  出厂没改派的 ⌥S = 打 ß，一个都不碰；
- 命中 → `CommandRuntime` 执行命令、吞掉事件（与菜单键等价语义一致）；
- 匹配的是**有效键位**（出厂值套改派），与菜单/⌘K 面板同源。

复测：聚焦正文连发两次 ⌥S——`textLen` 不变，侧栏两轮都切换。

#### 测试

874 → 882（+8）：新 `ShortcutKeyInterceptorTests`（改派 ⌥S 命中、⌘/⌃ 放行、
未改派放行、⌥⇧S 不冒充 ⌥S、大写锁定忽略、大小写同键、多键位各归各、
启动装载守卫）。反向验证：拆掉 `install` 当场红。

#### 教训

- **「改派无效」到此查全了三层**：键位没人接（#189）→ 接了状态不动（#192）→
  派发本身不可靠（这次）。三层一起才会「第一次有效、之后打 ß」这种鬼现象。
- 探针的调用路径要贴住真实路径：`performKeyEquivalent` 直接调菜单会「命中」，
  `NSApp.sendEvent` 才是用户按键的走法——上一回的探针差点把这一层漏掉。
- Option-only 组合想当快捷键，别指望菜单：事件监视器在派发前接，
  是唯一稳的姿势。

### v0.15.17（2026-10-22）— 界面语言默认中文（#204）

v0.15.15 把翻译框架落地时，出厂值是「跟随系统」。系统语言是英文的机器
第一次打开 wtmd 看到英文——可这套文案本来就是按中文写的，作者与绝大多数
读者也用中文。**默认值是产品决定，不该交给系统语言猜。**

#### 改法

解析链去掉测试特判后只剩三段：

```
override（测试钉值）> 用户偏好 > 出厂值中文
```

用户偏好必须再分两态，混在一起「跟随系统」就会失效：

| `wtmd.language` | 含义 | 结果 |
| --- | --- | --- |
| 键不存在（nil） | 从没选过 | 出厂值中文 |
| `"zh"` / `"en"` | 显式选了一种 | 听用户的 |
| `""` | 设置里选了「跟随系统」 | 按 `Locale.preferredLanguages` 解析 |
| 其它脏值 | 旧版本遗留 / 手改 plist | 退回出厂值中文 |

设置 › 应用 › 界面语言的 `@AppStorage` 默认值同步改成 `zh`，首次打开时
选中项显示「简体中文」，与实际生效值一致；「跟随系统」保留，仍然有效。

#### 顺手删掉的测试特判

原来靠嗅探 `XCTestCase` / `swiftpm-testing-helper` 把测试进程钉成中文，
好让断言不随 CI 机器的 locale 漂。默认值变成中文之后这层探测没有意义了：
`userPreference == nil` 就是中文，CI 机器是英文也一样。

判断同时收进纯函数 `resolve(preference:systemLanguage:)`——不读
`UserDefaults`、不读 `Locale`。全局状态只有一份，几个套件并行跑时互相污染
是 flake 的温床；纯函数让各种组合直接从参数喂进来。

#### 测试

882 → 884（+2）：`preferenceResolutionKeepsDefaultAndFollowSystemApart`
（nil / "en" / "zh" / 空串 / 脏值 五种组合，含「系统是英文也默认中文」）、
`localeDetectionMatchesTheSystemPreference`（系统语言检测接线）。
反向验证：把 `defaultLanguage` 临时改成 `.english`，`L10nTests` 9 条断言
当场变红，恢复即绿。

#### 教训

- **默认值是产品决策**：能用系统语言的地方不等于该用。用户没表达偏好时，
  给一个确定的、与产品语气一致的值，比「猜」更尊重人。
- **`nil` 与 `""` 是两种语义**：一个是「没选过」，一个是「明确选了跟随」。
  存储层把它们当同一件事，功能就会悄悄失灵——这种区分要在解析函数里
  写清楚，并用测试钉住。

### v0.15.18（2026-10-23）— 「打开方式」里终于有 wtmd（#208）

读者问：对着 `.md` 右键 › 打开方式，列表里没有 wtmd，是不是要注册点什么？

是。而且**两层都要**：注册（系统知道它能开）+ 接住（收到文件后真的打开）。

#### 根因

| 缺什么 | 表现 |
| --- | --- |
| `Info.plist` 没有 `CFBundleDocumentTypes` | LaunchServices 不知道 wtmd 能开 `.md`，菜单里不列它 |
| 没有 `application(_:open:)` | 就算列进去了，系统送来文件也只是激活一个空窗 |

#### 注册

- `CFBundleDocumentTypes`：`CFBundleTypeRole = Editor`、`LSHandlerRank = Alternate`
  ——出现在菜单里，但不抢别人已经认领的默认程序；
- `LSItemContentTypes` 同时列 `net.daringfireball.markdown`（系统已有的 Markdown
  类型，Xcode 声明的那份）和自 export 的 `cn.wtmd.markdown`；
- `UTExportedTypeDeclarations` 声明 `cn.wtmd.markdown`：conforms
  `public.plain-text`，tags `.md` / `.markdown` / `.mdown` / `.mkd` /
  `text/markdown`——没装 Xcode 的机器上，扩展名映射靠这份；
- `CFBundleTypeExtensions` 留着兼容只看扩展名的旧路径。

#### 接住

`AppDelegate.application(_:open:)` → `OpenRequest.open(_:)`。判断收成纯函数
`plan(index:sameDocumentAlreadyOpen:currentWindowIsUntouched:owner:)`：

| 情况 | 落在哪 |
| --- | --- |
| 这篇在别的窗开着 | 把那扇窗带到前面，不再开第二份 |
| 前台窗就是这篇 | 什么都不做 |
| 前台窗还是欢迎页/空白 | 装进当前窗 |
| 前台窗正在写别的 | 另开一扇（多选时第二篇起都是这条） |
| 目录 / 失效路径 | 直接筛掉 |

两个坑，都是真机探针才发现的：

- **欢迎页的文案存在 `text` 里**。只看 `text.isEmpty`，刚起来的窗会被判成
  「有未保存的稿子」，于是每打开一个文件都多开一扇空窗。新加
  `DocumentStore.isUntouched`：`fileURL == nil && !hasStartedWriting` 且正文
  是空的或就是 `welcomeMarkdown`。
- **`raiseFrontWindow()` 返回 false 不等于没有窗**。刚启动时主窗已建好、只是
  还没露脸，这时候 `openWindow(id:)` 会新增一个 `WindowGroup` 实例：屏幕上
  一扇空欢迎页、一扇有稿子。改成「一扇能当主的窗都没有」才开新窗。

#### 怎么验证「打开方式」里真的有它

`NSWorkspace.shared.urlsForApplications(toOpen:)` 就是 Finder 那个菜单用的
API，一个十行脚本就能把候选列表打出来：

```swift
let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
```

顺带查出位置这件事：**同样的 bundle 注册在 `/tmp` 下不进列表**，放到
`~/Applications` 立刻出现。LaunchServices 只把常规位置当候选。装到「应用程序」
之后若菜单还没刷新，`lsregister -f /Applications/wtmd.app` 一次即可。

#### 测试

884 → 891（+7）：`OpenRequestTests` 6 条（空窗复用、有稿另开、多选各开一扇、
已在别窗则跳转、同篇不动、目录筛掉）+ `DocumentStore.isUntouched` 1 条。
真机复测：干净草稿下 `open -a wtmd file.md` 只留一扇窗，轨迹是
`open route=reuseCurrent` → `doc file.md`。

#### 教训

- **「打开方式」是一个两段式功能**：声明类型只解决「看得见」，事件处理才解决
  「打得开」。只做前一半，用户点一下会发现「菜单里有、点了没反应」。
- 判断「有没有窗口」不能用「看得见」：启动早期窗口存在但还没露脸，
  按「看得见」判就会多开一扇。这类「存在 ≠ 可见」的区分在 #175 也踩过。

### v0.15.19 — 文件地址看得见、Finder 一步到（#211）

打开一篇 `.md` 之后，除了状态栏右下角一个文件名，应用里没有任何地方能告诉
你这份文件存在哪里；想在 Finder 里改名、发送、挪位置，只能自己翻文件夹。
这次把「地址」变成随时可看、可复制、一步可到：

- **状态栏文件名活了**：悬停显示完整路径（`~` 缩写），点击即在 Finder 中
  **选中**该文件（`activateFileViewerSelecting`——开文件夹自己不算数，
  焦点得落在文件上）。
- **File 菜单两条命令**：「在 Finder 中显示」（⇧⌘R）、「复制文件路径」。
  后者复制的是机器认的完整 POSIX 路径——tooltip 里给 `~` 缩写是给人看的，
  进终端、进脚本的全路径一个字符都不能省。
- **草稿的边界**：没落盘的文档没有路径，两条命令灰掉、状态栏仍是
  「草稿」。无处可寻、无路可抄，不给假动作。
- `CommandCatalog` 单点注册：⌘K 搜「Finder / 路径 / folder / path」都到得了，
  快捷键设置里也能改派。

#### 测试

891 → 893（+2）：行为一条（欢迎页/草稿灰掉 → 打开后可用 → 剪贴板里是
全路径；「显示」会拽 Finder 到前台，测试不真按）+ 注册一条（File 分组、
出厂键位存在、中英文关键词可达）。`MenuPlacementTests` 的 File 菜单守卫
从七条扩到九条。

反向验证：把「草稿灰掉」判定临时改成恒真，2 条断言当场变红，恢复即绿。

#### 教训

- **同一份信息有两种受众**：人看 `~/Documents/…`，机器吃
  `/Users/ice/Documents/…`。展示与复制分开实现，别拿缩写去喂脚本。
- 菜单命令的可用性边界跟着**数据是否存在**走，不跟着按钮走——
  `isEnabled` 是唯一裁判，⌘K、菜单、状态栏三处入口自动一致。

### v0.15.20 — 编辑器跟随主题（#214）

主题 CSS 只喂了预览的 WebView。写作区是 `NSTextView`，底色/字色钉死在系统
语义色、字体固定系统等宽——**编辑器从未跟随过主题**。split 模式下预览半边
换肤、写作半边不动，纸墨主题下尤其扎眼；用户报的是 split，实际是全模式通病。

#### 方案

- `EditorThemeStyle` 从主题变量层拆出 `--bg`/`--fg`/`--font-mono`（明暗两套），
  只存原始数据（id、字族、hex 字符串）——SwiftUI 每次刷新都重新求值这个
  结构体，拿 NSColor 做相等比较会让编辑器每敲一个键都重铺高亮。
- 颜色用 `NSColor(name:dynamicProvider:)` 动态供应商：绘制时按 appearance
  自己挑明/暗那套，系统切深浅色不需要任何人通知。
- `EditorFonts` 派生加粗与标题字号；`highlight(_:fonts:textColor:)` 让语法
  高亮的正文属性跟随 textView 当前字体/字色，旧调用点回落系统。
- 换主题 → `updateNSView` 检测 style 变化 → 重铺四件套 + 整串高亮。

#### 真机/测试挖出的三个坑

- **`NSFont(name:)` 对没装的字族不返回 nil**，悄悄给替代字体——「回落系统
  等宽」必须先对 `availableFontFamilies`（**字族名**清单）把关；
  `availableFonts` 是 PostScript 名清单（`Menlo-Regular`），拿它查
  "Menlo" 永远落空。
- **系统等宽的隐藏字体名（`.` 开头）不能喂 `NSFont(name:)`**，会产出错误
  字重；标题行走 NSFontManager `toSize` + bold，隐藏名直接
  `monospacedSystemFont(ofSize:weight:.bold)`。
- **`NSTextView.font`/`textColor` 的 getter 跟着选区属性走**——选区停在
  标题行时读到标题字体和 controlAccentColor。断言要看 `coordinator.fonts`
  与 textStorage 属性，别碰选区敏感的 getter。

#### 测试

893 → 902（+9，`EditorThemeTests`）：变量解析、hex 全长度取色与坏值、
字族栈解析、明暗借用（终端这类只有暗色变体的主题）、真视图应用（底色
解析值/正文字色/光标/字族）、高亮跟随主题字体、清主题回落、字族不存在
回落。反向验证：拆掉字体应用，3 条断言当场变红。

### v0.15.21 — 点 Dock 图标，回来的是原来那扇窗（#217）

把主窗缩进 Dock 再点 Dock 图标，出来的是一扇**新的默认页面**，缩着的原窗
纹丝不动。这条是 v0.15.4「自己举窗」留下的暗坑：当时为了要系统的神灯动画，
在「所有能当主的窗口都缩着」时把 reopen 交回系统——但那是 AppKit 应用
的老规矩；SwiftUI WindowGroup 应用里系统接手 reopen 开的是**一扇新窗**，
不是把缩着的放出来。半秒后的兜底一看「有看得见的窗」（新开的那扇），
便以为自己错了手。

第二层坑在挑窗的纯函数里：候选窗要求 `isVisible`，而缩着的窗 `isVisible`
返回 false（#175 踩过、记了账，却没改到 `pick`）——就算不走交给系统的
捷径，自举路径也一样举不出缩着的窗，掉进「举不出 → 开新的」。

#### 方案

- `pick` 把 `isMiniaturized` 的窗也当「还在」（`isVisible || isMiniaturized`）：
  可见普通窗 > 可见面板 > 缩着的普通窗 > 缩着的面板，按顺序取第一扇；
  lastKey 缩着也算数——人把它收进 Dock 又点了图标，多半就是要它回来。
- reopen 不再交给系统，一律自己举；缩着的自己 `deminiaturize`（没有神灯
  动画，但出来的就是那扇窗）。真的一扇都没有，才 `openMain` 开新空白页。
- 移除 `defersToSystem` 与 0.5s 兜底计时器——留着只会骗过下一次排查。

#### 代价与取舍

从 Dock 放出窗口丢了神灯动画（自己 deminiaturize 是「直接出现」）。
收起来有动画、放出来没有，不对称还在；但「点图标出来一扇陌生的空白页」
比「出来时没有动画」严重得多，正确性优先。

#### 测试

902 不变（换血）：`pick` 新增「lastKey 缩着仍被选中」「多扇全缩按顺序取
第一扇」两条；测试 helper 贴近真实 `NSWindow`——缩着的窗一律
`isVisible == false`（旧 helper 让它俩并存，等于在假数据上测真逻辑）；
`DockGenieTests` 重写为 `DockReopenTests`，装配守卫反向钉住——
`defersToSystem` 与兜底计时器**不得再现于源码**。

### v0.15.22 — 检查更新双源：GitHub 主源 + Gitee 备源（#220）

GitHub 直连在国内不稳，DMG 下载慢。Gitee（`gitee.com/Micestark/wtmd`）作为
备份发布源：**开发全流程不动**（全在 GitHub），只在发布链末尾同步一次
release；应用内检查更新查双源，用户自己挑从哪儿下载。

#### 方案

- **双源并发检查**：`UpdateChecker.Configuration.sources` 每源一个查询
  endpoint（GitHub API 与 Gitee API v5 同构）。检查时并发查全部、都等到
  结果再比，取**版本更高**者；单源失败回退另一个，全失败才报「检查失败」。
  返回的源序按配置序——并发完成顺序不定，不能让它决定「首选源是谁」。
- **宽容解码**：Gitee 的 release JSON 缺 `html_url`/`draft`/`prerelease`，
  一律宽容（缺省 false）；release 页缺了从源配置的模板拼
  （`https://gitee.com/…/releases/tag/{}`）。
- **换源下载**：`UpdateStatus.available` 改带 `[UpdateSource]`（名称 + dmg
  直链 + release 页）。状态栏徽标点一下 = 首选源一键装，长按出菜单换源；
  设置页给「换个下载源…」入口。失败降级打开对应源的 release 页。
- **发布同步**（`sync-gitee-release.sh`）：推 tag 快照 → 用 GitHub 的标题
  说明建 release → 传 dmg。幂等；令牌读 `$GITEE_TOKEN` 或
  `~/.config/wtmd/gitee-token`，没有则打印手工上传指引并退出 0——
  **缺令牌绝不阻塞 GitHub 发布**。Gitee 仓库只收 tag 快照与 release，
  不参与开发。

#### 教训

- **并发回来的结果没有顺序**——TaskGroup 谁先完成谁先到，多源场景里
  「首选源」必须由配置顺序决定，收完再排，不能听天由命。
- **守卫扫源码是全局的**：ContentView 里新写的 `menuIndicator(.automatic)`
  被「侧栏禁用 `.automatic`」的守卫当场拦下——装配守卫看的是整个文件，
  新代码也要守它的规矩。

#### 测试

902 → 909（+7，`UpdateDualSourceTests`）：双源同版本带全源、高版本胜出
（哪怕来自备源）、单源失败回退、全失败报错、Gitee 载荷宽容解码 + 模板
拼页、徽标换源菜单装配守卫。反向验证：把「取更高版本」改成取更低，
双源用例当场变红。

### v0.15.23 — 工具栏不再有保存按钮（#223）

工具栏上导出与设置之间那颗「向下箭头进盒子」，被认成了「导入」——它其实是
保存，且没有未保存改动时常年灰着，误解又加深一层。而它本来就没人点：
wtmd 有自动保存，⌘S 是所有编辑器用户的肌肉记忆。

#### 方案

删掉工具栏的保存 `Button`。**不动**⌘S 菜单项、命令面板保存命令、
`CommandCatalog.save` 与 `isEnabled(.save)`——菜单、面板、自动保存链路仍
依赖它们；工具栏少一颗没人用的按钮，导出与设置之间也不再有一对
「上箭头/下箭头」误导人。

#### 测试

909 不变（840 + 69），全绿。

### v0.15.24 — 工作区标题行：整行双击收放，关闭走右键菜单（#226）

工作区标题行右侧的 ✕（`xmark.circle.fill`）紧挨着展开/收起的视觉区域，
点击后整棵文件树当场消失——读起来就是「删除工作空间」，而它其实只是把
工作区从侧栏拿走。一颗承担着「看起来像毁掉东西」的按钮，不该是收放区里
最显眼的元素。

#### 方案

- **移除 ✕ 按钮**。
- **整行双击 = 收起/展开工作区分组**；分组展开状态住在 `WorkspaceStore`
  （`sectionExpanded`）——树随时会因磁盘变化重建，状态在视图里会被弹回。
- **文件夹行同样支持整行双击切换**：折叠箭头只有几像素宽，整行都该是
  开关，与标题行同一习惯。
- **「关闭工作区…」收进右键菜单**（destructive 样式）+ NSAlert 二次确认，
  弹窗明说「工作区会从侧栏移除，但不会删除磁盘上的任何文件」。菜单里
  其余轻操作（新建、Finder 显示、拷贝路径）不确认——确认只给重操作。

#### 教训

反向验证时用 `git checkout <源文件>` 恢复探针改动，把**未提交的特性修改**
一并冲掉了——探针要走 stash/补丁文件，或者先把特性提交再动源码。
守卫本身当场变红是它该干的活；被冲掉的是自己的疏忽。

#### 测试

909 → 913（+4，`WorkspaceHeaderTests` 装配守卫）：✕ 不得再现、双击手势
两处必须在、关闭必须过确认且弹窗说清「不删文件」、分组状态必须住在
store。反向验证见上。

### v0.15.25 — 没有删除的工作区：解除，而不是删掉（#229）

文件树右键的「移到废纸篓」直接对真实磁盘文件生效。哪怕进的是废纸篓、
哪怕有确认，一把常驻右键里的刀对写作工具来说仍是危险的口子——误点
一次就够。用户拍板：删除类选项全部去掉。

「关闭工作区」的语义也趁此摆正：它从第一天起就只解除 wtmd 与文件夹的
访问关系，文件夹和文件一个字节都不会动——那就叫**解除工作区**，并把
这件事说到明处。

#### 方案

- **移除「移到废纸篓」**：树行右键不再有删除项；连带清掉
  `WorkspaceStore.trash` / `WorkspaceFiles.trash` / `defaultMoveToTrash`
  / 注入参数 / `dropPaths`。删文件走访达——那里有废纸篓和它自己的习惯。
- **外部删除照常响应**：`documentWasTrashed` 跟进链路保留——在 Finder
  里删掉正打开的文件，wtmd 仍会草稿化、清选择、更新树。
- **更名**：File 菜单、命令面板、标题行右键共用 `CommandCatalog`，只改
  标题与关键词，`CommandKind` id 不动——用户改派过的快捷键不丢。
- **确认弹窗改写**：informational 风格，明说「只会解除访问关系，
  文件夹和里面的文件不会有任何改动」。

#### 测试

913 → 910：移除 4 条 trash 用例，新增「无删除入口」装配守卫（树行、
store、Files 三层钉住「不得再现」）。反向验证：源码注入
`Move to Trash` 字样 → 守卫当场变红。

### v0.15.26 — 侧栏的「工作区」分类头与按压高亮（#232）

两条来自同一个抱怨：侧栏「点击很硬」——摁下去没有任何视觉变化，也不容易
一眼看出工作区那片是什么。

#### 方案

- **分类头**：工作区树包进 `Section(t("Workspaces"))`，与「大纲」「最近
  文件」同一套侧栏节头；原分区头（文件夹名、双击收放、右键菜单、拖放）
  原样保留。
- **按压高亮**，两套反馈对应两种手势世界：
  - 树行（文件/文件夹/标题行）不能是 Button——Button 会吃掉拖拽手势，
    行就再也抓不起来。按压信号走 `onLongPressGesture(minimumDuration:
    .infinity)` 的 `onPressingChanged`：只取按下/抬起，永不完成，动作仍归
    `onTapGesture`；`maximumDistance: 8` 让真实拖拽一启动高亮就取消，
    不会残留在刚拖走的行上。
  - 大纲行、最近文件行是 Button，用自定义 `SidebarRowButtonStyle` 的
    `isPressed` 驱动，替换 `.plain`（plain 没有按压底色）。
- 高亮是中性色 0.1 的圆角底，明显弱于拖放目标的强调色 0.18——按压反馈
  绝不能读成「松手放这里」。

#### 测试

910 → 914（`SidebarFeedbackTests` 装配守卫）：分类头必须接、树行按压接线
≥3 处、Button 行按压样式 ≥2 处、组件两套必须齐。反向验证：拆掉
`.pressFeedback()` → 守卫当场变红 → 恢复绿。特性先提交再做反向验证——
v0.15.24 的教训这次用上了。

### v0.15.27 — 原生滚动条跟随主题：声明 color-scheme（#235）

深色主题下，代码块横向滚动条的槽永远白底。滚动条是 WKWebView 原生绘制的，
其明暗由 CSS `color-scheme` 决定——主题变量层只声明了颜色变量，从没声明过
`color-scheme`，WebKit 默认按浅色画。改颜色变量改不了滚动条。

#### 方案

`StyleSheet.cssText(light:dark:)` 给每个变量块补声明：浅色块
`color-scheme: light`、深色 media 块 `color-scheme: dark`；单变体主题照应
（常亮/常暗）。预览、HTML 导出、PDF 共用这条链路，一并生效。显式着色的
部分不受影响——`color-scheme` 只管没被显式上色的原生部件（滚动条、默认
表单控件）。

#### 教训：守卫断言也会被自己骗

反向验证第一版用裸子串 `"color-scheme: dark"` 断言深色块——它在
`prefers-color-scheme: dark` 里**本来就匹配得上**，探针删了真声明，守卫
照样绿。反向验证红不了就等于没验：断言改为带缩进前缀
（`  color-scheme: dark;`），并**用 grep 确认探针真的落地**再跑红。
另外 `--filter` 用函数名时 swift-testing 显示 "1 test in 0 suites"，
顶层函数（不在 `@Suite` 里）是这么显示的，不是没跑。

#### 测试

914 → 915（`cssTextDeclaresColorSchemeForNativeScrollbars`）。CI 上
`WorkspaceSearchController` 两条 flake（记忆在案的 rerun 即绿），重跑后
双绿。

### v0.15.28 — 代码块 Word Wrap 开关：版式层下发折行规则（#238）

预览里代码块只有横向滚动一种展示：超宽行（长 URL、深层缩进、宽表格代码）
要来回拖滚动条。行业里对这件事有成熟的叫法与语义——Vim 的 `:set wrap` /
VS Code 的 "Word Wrap"：折行只影响显示，实际文本一字不动。

#### 方案

设置 › 版式新增「代码块」一节，一个 **Word Wrap（自动换行）** 开关：

- **关（默认）**：与 v0.1 起行为一致——`pre { overflow: auto }`，保持排版、
  横向滚动。
- **开**：版式层下发
  `pre { white-space: pre-wrap; overflow-wrap: anywhere; }`——`pre-wrap`
  保留原有换行与缩进，`overflow-wrap: anywhere` 兜住无空格的超长标识符
  与 URL。

不发变量、直接发规则：折行是二值的展示模式，做成变量再由基础样式表分支
反而多一层。规则走既有版式层（`<style id="wtmd-layout">`）——晚于基础
样式表生效，切主题互不牵连；预览经 `applyLayout` 热更新，HTML 导出与
打印 PDF 自带同一规则，三端一致。

#### 测试

915 → 920（`TypesettingSettingsTests`）：默认关且 CSS 静默、开启后规则
生效、跨启动持久化、reset 归位、关掉后规则彻底消失（反向守卫——关了
开关 CSS 里就不能再有一丝 `pre-wrap`，否则横向滚动名存实亡）。

### v0.15.29 — 打开/新建的默认视图：按意图分流（#241）

打开文件沿用窗口当前视图、新建固定思绪——两种动作共用一个默认，读的人
要自己按一次 ⌘/。改成分流：**打开一篇非空的稿子默认先进成文（阅读）**——
打开文件最常见的意图是读；**新建保持思绪并自动点亮专注模式**——新建的
意图是要写了。

#### 方案

- `open(url:jumpingTo:)`：内容非空（按空白裁剪判断）且当前在思绪时切到
  成文。已在分栏/预览的不抢读者当前的选择；带行列跳转（⌘⇧F 命中）必须
  落源码——预览没有行号可落；空文件没有可读的预览，留在思绪。
- `init` 启动恢复路径同一条默认：上次打开的非空稿子也先进成文。欢迎页与
  未保存草稿不算「打开的稿子」，不受影响。
- `newDocument()`：点亮专注模式。设置是应用级的（`WritingSettings`），
  store 与 `typesetting` 同款借用——WindowModel 注入 `store.writing`，
  store 不拥有它。读者之前手动关过也照开：「新建」本身就是进入写作的意图；
  测试没接设置（`writing == nil`）时新建不碰真实偏好。

#### 测试

920 → 928（`DocumentStoreTests` +8）：非空默认预览、空文件留源码、跳转
留源码、不抢显式选择（分栏/预览各一）、启动恢复进预览、欢迎页留源码、
新建点亮专注（含手动关闭后再新建）、未接设置时无害。全量重跑时
`SettingsShellTests` 一条 L10n 断言红过一次——并行下别的套件动了全局
override（记忆在案的 flake 类型），单跑与重跑均绿。

### v0.15.30 — base16 社区配色内置 + 可视化主题编辑器（#244、#246）

主题系统从「三套手写 + 手写文件夹」长成两层：**十套 base16 社区配色**直接
内置（tinted-theming/schemes 的 `base16/` 目录字母序前十，2 浅 8 深），再加
一个**可视化主题编辑器**——挑任意主题当基底，取色器加 hex 调色、选字体，
实时样张预览，保存即装。

#### 方案

- **一张映射表吃下社区配色库**：`Theme.base16Map` 把 16 个色槽按固定语义落
  到变量上（base00→--bg、base05→--fg、base0D→--accent/--link、base03→
  --hl-comment…）。`base16CSS(_:)` 是纯函数：槽数不对或色值不像 hex 就整体
  返回 nil——宁可这套主题不出现，也不出一半颜色的残废主题。这张表同时是
  将来导入器的地基。
- **设置按来源分组**：内置 / base16 / 自定义三段，来源行常显。
- **编辑器**（`ThemeDraft` + `ThemeStore` + sheet）：草稿以任意主题为基底
  载入，单侧主题另一侧自动借用；暴露 10 主色 + 6 高亮 + 3 字体，`pre-border`
  与 `th-bg` 从 `border`/`pre-bg` 派生——编辑器少调一半，导出仍是完整的
  18 变量 + 3 字体，与手写主题无异。右侧 SwiftUI 样张实时预览；对比度低于
  3:1（WCAG）提醒但不拦着保存；同名文件夹冲突问「覆盖 / 另存为副本」；
  编辑既有自定义主题沿用原文件夹名，改名不分叉。内置主题不可被编辑覆盖。

#### 测试

928 → 947（+19）：base16 映射正确性与坏输入整体拒绝、十套可用性（恰好
一侧、id 与名字不撞、明暗都有样本）、`builtInThemesValid` 期望数 13；编辑器
的基底载入（双侧完整、单侧借用）、CSS 导出（21 行顺序稳定、派生项紧跟
源项）、hex 归一化、对比度（WCAG 参考 21:1）、写盘往返（写出的必须能被
`loadFolder` 原样读回）、冲突与覆盖、副本计数、改名不分叉、rebase、双面
互抄、低对比警告。界面另做离屏渲染快照供人眼复核（探针不入库）。

### v0.15.31 — base16 主题按语言显示正名（#249）

0x96f、3024 是社区仓库的 slug（编号、十六进制梗），当名字确实不合适。
给十套 base16 主题各起正名，显示名走翻译框架：中文界面叫**夜航、炭火、
淡漠、学徒、甜米露 · 夜/昼、盛世、余烬、石窟画室 · 浅/深**，英文界面叫
Night Flight、Ember、Apathy……slug 一律不动——主题的身份是 id，改名
不让已选中的主题失效。

#### 测试

947 → 948（+1）：显示名守卫——十套名字必须是十套正名之一（中/英两套
都算过，编号与 slug 不得出现）。名字是静态表启动时求值、override 全局，
所以中英两套都放行。

### v0.15.32 — 崩溃报告的隔代收割：版本与时刻不再误导（#252）

一份实测报告（0.15.30 被结束、0.15.31 启动时收割）把两个内容缺陷摆上了

台面：报告头 `version: 0.15.31`——排查的人去找 0.15.31 的毛病，死的却是

0.15.30；正文「时间：09:32」——那是死者的**启动**时刻，进程其实死在之后。

#### 方案

- **版本取死去那一位自报的**：`launchedVersion(in:)` 从轨迹最后一条

  `launch wtmd X` 解析，收割时填进报告头与正文；轨迹没有才回退收报告

  进程的版本。轨迹每行都立刻落盘，这条线永远在。

- **无现场时刻改叫「最后活动」**：`terminated`（强退/`kill -9`/断电）没有

  当场写下的时刻，`capturedAt` 只能取现场文件创建时间 = 启动时刻（#181

  同源）。这类报告的时间标签改为「最后活动」；信号/异常有真时刻，仍叫

  「时间」。判定不动——本例 macOS 无 DiagnosticReports 记录，确为强退，

  分类正确。

#### 测试

948 → 952（+4）：`launchedVersion` 解析、terminated 正文带死者版本与

「最后活动」标签（且不再出现「时间：」）、信号正文保持「时间」、隔代

收割端到端（半成品 + 轨迹 → 报告版本 0.15.30）。

### v0.15.33 — 设置 › 主题：卡片式主题库（#255）

主题选择从下拉 Picker 换成卡片库：颜色与字体不该藏在名字后面，用户在

选中之前就该看到主题长什么样。

#### 界面

- **卡片**：上半是用主题自身 CSS 变量渲染的迷你样张（标题、正文、行内

  代码、链接、代码块、四格色板），下半是名称 + 浅深徽章 + 作者。明暗

  双面主题左右各渲染一半，单侧主题整幅用那一侧——卡片本身就是一次

  「装上之后大概长这样」的诚实预览。

- **样张不进 WebView**：十几张卡同屏滚动，每张起一个 WKWebView 是

  灾难。SwiftUI 直绘，变量解析复用 `Theme.parseVariables`，颜色认不出

  回落系统语义色，字体栈第一个未安装的字族回落系统字体——坏一份数据

  不会弄瞎一张卡。

- **分组**：内置 / base16 社区配色（注明 tinted-theming · MIT）/ 自定义，

  组头带数量；自定义组尾一张虚线「添加主题…」卡。

- **筛选 chips**：全部 / 浅色 / 深色 / 浅·深，按主题自带哪一侧变量分。

- **添加主题**：选 `.wttheme` 文件夹直接安装。`copyThemePackage` 校验

  （theme.json + 至少一侧 CSS，否则整体拒绝）、拷贝、重名自动顺延

  （暖沙 → 暖沙 2），装完重扫并选中——导入不问第二遍。

- **底栏**：当前主题摘要（来源 · 作者 · 外观）+ 新建/编辑/打开主题

  文件夹/重新扫描，原 Picker 时代的动作一个不少。

#### 测试

952 → 958（+6）：筛选按明暗两侧路由、外观徽章文案（中英集合二选一，

防 t() 静态求值时机）、序号名去重、安装往返（拷贝出来还能 `loadFolder`

读回）、非法包拒绝与错误文案。

### v0.15.34 — 侧栏分类头的展开/收起开关（#259）

侧栏「工作区」分组原来只能双击文件夹标题行收放（且收起后标题行还占着
一行），「大纲」则完全收不起来——工作区树一长，大纲永远被压在下面。

#### 界面

- **分类头即开关**：「工作区」「大纲」两个分类头各加展开/收起开关——
  一颗随开合旋转的箭头 + 标题，整行可点，带按压反馈与辅助功能提示。
  用的还是 `Section(isExpanded:)`，收起自带动画不跳变。
- **收起即让位**：工作区收起后整组（含文件夹标题行）都不占位，大纲
  顶到侧栏最上面——树再长也不耽误先看大纲。
- **状态归属**：工作区收放状态继续住 `WorkspaceStore.sectionExpanded`
  （树重建不弹回，#226 的习惯不变，双击文件夹标题行仍是个开关）；大纲
  收放新增 `outlineExpanded` 住 ContentView。
- **职责上移**：`WorkspaceTreeView` 内层的可折叠 Section 移除——每组
  只有一套收放状态，不再嵌两层。

#### 测试

958 → 959（+1）：分类头收放守卫（两处 `Section(isExpanded:)` 接线 +
箭头旋转）；文件树内层不得再声明可折叠 Section，反向钉住职责上移。

### v0.15.35 — 更新检查与下载的韧性（#262）

用户反馈「有时候能更新下载成功，有时候又失败」。查下来三件事叠在一起：

#### 诊断

- **Gitee 备源从未同步**：`gitee.com/Micestark/wtmd` 上 0 tag、0 release，
  API 永远 404。双源设计里实际只有 GitHub 一个源在工作，所谓「兜底」
  一直是空的。
- **检查只试一次**：DNS 抖动、TLS 重置、CDN 段路由波动，任何一次都
  等于「检查失败」（状态栏闪 4 秒就没了，看不出为什么）。
- **下载只试一次**：dmg 直连 `release-assets.githubusercontent.com`，
  国内链路中途断流就废，只能重新点。

#### 改动

- **单源重试**：网络类错误 600ms 后再试一次。403/429（限流）、
  404（这个源没内容）、2xx 但 JSON 解不动——三类不重试，重试只会
  多耗一次 15 秒超时。
- **失败原因可见**：每个失败源记一条人话原因（请求超时 / 没有网络 /
  被限流（GitHub 每小时 60 次）/ 这个源还没有发布版本 / HTTP 状态 /
  返回内容无法解析），设置 › 版本逐条列出，成功即清空。排障要的是
  一行能读的话，不是一个 domain 错误码。
- **下载重试三次**，仍失败则换同版本的备用源——换源比让用户重新点
  一次便宜得多。
- **`sync-gitee-all.sh`**：把 GitHub 上每个正式版逐个推 tag、建 release、
  传 dmg 到 Gitee，已在 Gitee 的自动跳过；令牌未就位只打印手工步骤。

#### 测试

959 → 965（+6）：抖动后重试成功、限流不重试、失败源逐条按源序列出、
成功检查清空旧账、主源失败换备用源并走完全程、两源皆失败才报错。
另修两处随行为变化的旧断言（失败静默期 calls 计数、装配守卫）。

### v0.15.36 — 侧栏：分类头整行可点 + 滚动横线去除（#265）

用户报了两个侧栏问题：滚动时一条横线压在红绿灯按钮那一行；分类头只有
最左边那颗箭头能点。

#### 诊断（离屏渲染 + 合成点击实测）

用 `NSHostingView` 离屏渲染几种头部实现，再 `window.sendEvent` 逐点投递
合成 mouseDown/Up：

- HStack + `onTapGesture`：**整行都收不到点击**（箭头也不行）——真机上
  「只有箭头能点」是它恰好骑在系统命中区的边缘。
- Button + `.borderless`：同样被吞。
- Button + `.plain` / 自定义按压样式：箭头、标题、右侧空白整行都响应。

结论：List 的 section header 只让真正的 Button 吃命中。横线则是 macOS 26
滚动视图的默认**硬边缘**：侧栏内容从标题栏底下滚过时，一条 hairline 正好
压在红绿灯那一行。

#### 改动

- **分类头 = 铺满整行的 Button**（`SidebarRowButtonStyle` 按压高亮同行按钮）。
- **收放改自家状态**：不再用 `Section(isExpanded:)`，内容按状态条件渲染；
  收起后空 Section 的头部照常渲染（离屏渲染验证过）。
- **侧栏顶边软边缘**：macOS 26+ 挂 `scrollEdgeEffectStyle(.soft, for: .top)`
  （渐进模糊、没有线），旧系统原样返回。

#### 测试

965 → 966（+1）：分类头守卫更新 + 新增 `sidebarTopEdgeIsSoft`（反向钉住
「分类头必须是 Button」「顶边必须是软边缘」）。

### v0.15.37 — 落笔：一边写一边成为文章（#268）

第四种视图模式 `Live`（落笔）：Typora / Obsidian 式 live preview——编辑器
里直接以排版后的样子呈现，打一个字页面实时变样，不经过 WebView。

#### 思路

渲染全部走属性层：字符一个不动，光标、撤销、输入法、查找替换、回车续行
照旧。语法标记（`#`、`**`、反引号、`~~`、`>`、围栏行）退成次级颜色，内容
保持加粗/斜体/主题色；块级装饰（围栏代码块整宽底色、引用左侧竖条、`---`
横线）由 `LiveDecorationLayoutManager`（NSLayoutManager 子类）在
`drawBackground` 里画。

#### 两个坑

- **maxSize 钳制**：`NSTextView(frame:textContainer:)` 会把 `maxSize`
  钳在初始 frame（640×400）——布局照跑、`usedRect` 正确，但 `textView.frame`
  不随内容长高，打字机居中把 `frame.height` 当可滚动高度，光标过首屏就
  居不了中。手工构造后必须显式设 `maxSize = greatestFiniteMagnitude`。
- **frame 生长时序**：自建文本系统（NSTextStorage + 自定义 LayoutManager）
  的 frame 生长走后台布局完成回调，位置回填排在生长前会被钳在半截
  （CI macOS 15 抓到）。Coordinator 加同步 `growToContent()`，接在每条
  文本/字体变化路径的高亮之后。

#### 测试

966 → 970（+4）：标记褪色 + 内容样式保留、块收集（围栏/引用/横线、未闭合
围栏补到文末）、引用连行成一块、进落笔不重算预览 HTML、环序
edit→live→preview→split。

### v0.15.38 — 开窗策略：Obsidian 式，文件不再带回旧桌面（#271）

关掉所有窗口后从 Finder 右键「打开方式 → wtmd」打开一篇 md，屏幕上却
开回来好几个之前打开过的窗口。四层恢复各自为政：

1. 主窗会话永不结束：一扇可见窗都没有时 `openMain()` 把主窗举回来，
   带着上次开的旧文件占了前台。
2. 文件路由偏 Typora：前台窗开着别的稿子就另开一扇，文件又占一扇。
3. 启动时账本恢复把上次退出的副窗全摆回来——哪怕这次启动带着文件。
4. 系统 savedState 把 `wtmd.extra` 的旧 UUID 实例化成空白僵尸窗
   （副窗设了 `isRestorable = false`，主窗一直没设）。

#### 改动：意图优先，一条路走完

- **带文件启动跳过桌面恢复**：Finder/Dock 投递来文件时
  `WindowCoordinator.suppressRestoration` 置位，`restoreWindows()` 这次
  不摆账——打开文件是明确的意图，上次的桌子别抢戏。账留在 defaults 里，
  下一次普通启动照常回来。
- **文件路由改 Obsidian 式**：第一篇装进前台窗（`DocumentStore.open`
  换稿之前会先落盘，字不会丢）；前台窗里欠着**没名字的稿**时仍另开一扇
  ——那些字只在草稿里，被顶掉就真没了。多选时第二篇起各开一扇。
- **主窗也 `isRestorable = false`**：账本是窗口恢复的唯一事实来源，
  系统场景恢复的僵尸窗不再出现。
- 「点 Dock 图标回到上次的桌面」保持不变——那正是接着上次写。

#### 测试

970 → 971（+1）：带文件启动跳过桌面恢复、账本原样留给普通启动；
`OpenRequest.plan` 的路由守卫随新参数重写（前台有稿子也装进当前窗、
无名稿仍受保护）。

### v0.15.39 — 同语境一个文件一扇窗（#274）

同一篇文件还能在两扇窗各开一份：两边各写各的，靠落盘互相覆盖，先写的
一边无声丢字。占位表从「路径」升级为「路径 + 语境」。

#### 语境

- 文件在窗口**工作区根之下**被打开 → 工作区语境（记归一化的根）；
- 否则 → 单独语境（`nil`）。

#### 规则

- **同语境同文件只许一扇窗**：`owner(of:in:)` / `handOver(_:jumpingTo:from:in:)`
  只在同语境里找占主，重复打开一律把已有的那扇带到前面；
- **跨语境允许共存**：工作区窗 + 单独窗可以各开同一篇——这是两种打开
  方式，不该互相顶掉；
- `revealDocument` 返回是否找到活窗：占主是幽灵记录（表里有、窗口没了）
  时退回开一扇新窗，文件不落空；
- `OpenRequest.open` 的占主查询按**前台窗**对这个文件的语境来问。

#### 测试

971 → 973（+2）：占位表的同/跨语境查询与交接；端到端——工作区窗开着 X、
单独窗各开各的、第三扇单独窗交给已有单独窗、同一工作区根的第二扇窗
也要交出去。

### v0.15.40 — 下载完先问一句「安装并重启」（#277）

以前点更新 = 下载 → 挂载 → 装进 /Applications → 自动重启，用户全程没有
点头的机会。改成跟其他 macOS app 一样：**下载完成后弹窗确认**。

#### 流程

- 标题「wtmd vX 已下载，可以安装了」，说明「安装会退出 wtmd，装好后重新
  打开你的窗口。」
- 按钮：**安装并重启**（默认，Return）/ **以后**（Esc）
- 「以后」：什么都不装，旧版一个字节不动，应用继续跑；dmg 留在临时目录，
  设置页的访达退路仍可用
- 弹窗贴着当前窗口做 sheet；窗口上已经挂着别的东西（崩溃提示等）或没有
  窗口时，退化成独立弹窗——不能因为找不到窗口就把安装悄悄做了

#### 实现

- `UpdateInstaller.Steps` 新增可注入的 `confirm(version)` 步骤，`run()` 在
  下载成功之后、挂载之前等答案；测试里换成假闭包，不弹真窗
- 生产实现 `askToInstall(version:)`（NSAlert）
- 徽标提示文案改为「下载 v{}（装之前会先问你一句）」

#### 测试

973 → 976（+3）：先问后装的两条流程（拒绝时挂载/装配/重启一次都不碰、
接受时顺序 download → confirm → mount → install → relaunch），以及
生产入口接的是真弹窗而不是测试默认的「直接放行」。
