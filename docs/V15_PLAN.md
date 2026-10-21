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
