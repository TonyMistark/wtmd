# v0.14 — 崩了也说清楚

**状态**：已发布（v0.14.1，2026-10-20）｜ 前置：v0.13.0 已发布（2026-10-20，详见 [V13_PLAN.md](V13_PLAN.md)）

## 一句话

多窗口之后最难受的一种失败是**无声消失**：进程被一个信号打死，窗口连同刚敲的半句话一起不见了，
而读者手里什么都没有——没有报错、没有日志、没有一个能发给作者看的东西。

v0.14 补的是这一条：**崩溃现场留在本机，下次打开时有人把话说清楚，并且一条链接就能把它送到 issue 里。**

## 现状（立项前核实）

- 应用没有任何崩溃采集：`signal(SIGSEGV)` 是默认处理，进程直接消失
- 系统会在 `~/Library/Logs/DiagnosticReports/` 留一份 `.ips`，但那是给开发者看的
  一屏寄存器与地址，普通读者既找不到也读不懂，更不会想到把它发出来
- v0.10 的多窗口崩溃就是这样：读者只记得「开第二扇窗的时候没了」

## 形态

三段，缺一不可：

1. **当场记下**（信号处理器）——只做异步信号安全的事：往预打开的 fd 写信号名与栈
2. **下次说清**（启动时的面板）——补上版本、系统、当时开着几扇窗、之前在做什么
3. **一条路送到 GitHub**——预填好的新建 issue 页面；发不发由读者按下提交

## 采集什么，不采集什么

| 记 | 不记 |
| --- | --- |
| 信号名（SIGSEGV / SIGABRT / …） | 文档正文，一个字都不记 |
| 调用栈（最多 80 帧）与主二进制的加载基址 | 文件内容、剪贴板、键盘输入 |
| 版本、系统版本、架构 | 用户名、机器名、路径里的家目录 |
| 崩溃时开着几扇窗口、手上是哪个文件名 | 窗口位置、工作区路径 |
| 最近 40 行操作轨迹（启动/开窗/关窗/打开文档） | 任何联网行为 |

报告只存在 `~/Library/Application Support/wtmd/crashes/`，
一份一个 `.wtmdcrash`（纯文本 Markdown，开头一段 HTML 注释装元数据）。
旁边的 `.seen` 表示「已经给读者看过了」。

## alpha — 把现场记下来

- `CrashCatcher`：装 `SIGSEGV / SIGABRT / SIGBUS / SIGILL / SIGFPE / SIGTRAP`
  与 `NSSetUncaughtExceptionHandler`（Objective-C 异常）
- 处理器里**只碰 fd**：`write()` / `backtrace()` / `backtrace_symbols_fd()` 都是异步信号安全的。
  不在处理器里拼字符串、不加锁、不分配——崩溃往往就发生在某把锁被持有的瞬间，
  再进一次就是死锁，进程会挂成「无响应」，连系统崩溃日志都不会生成
- 现场写进 `.inflight-<pid>-<启动时刻>.raw`，开场就写一行 `base 0x…`（`__TEXT` 的
  `vmaddr + slide`）。没有它，换一次启动同一串地址就对不上任何符号，
  有了它 `atos -o wtmd -l <base> <addr>` 一句就能还原函数名与行号
- 写完之后**恢复默认处理并 `raise`**：系统的那份崩溃日志照旧生成，我们的文件只是补充
- `CrashBreadcrumbs`：一行一次追加（启动 / 开窗 / 关窗 / 打开文档 / 当前窗口数），
  崩溃时最后那 40 行就是「之前在做什么」
- 正常退出的两道清理：`NSApplication.willTerminate` + `atexit`。崩溃与 `kill -9`
  都不会走到 `exit`，所以这两道不会把现场误删

## beta — 说清楚，并且给一条路

- `CrashStore`（应用级一份，挂 `SharedAppEnvironment`）：
  - `harvest()`：把上次的半成品补成正式报告（版本/系统/窗口数/文档名/轨迹），删掉半成品
  - 记账：清单从目录推导，不另立索引；最多 20 份、90 天，超了自动清
  - `issueURL(for:)` / `openIssue(for:)` / `copyToPasteboard` / `reveal` / `markSeen`
- `CrashPanel`：一句话说发生了什么（`SIGSEGV — 读写了一块不属于它的内存，常见原因是空对象`），
  下面是只读的完整报告（可选中复制），底栏「在访达中显示 / 复制报告 / 忽略 / 在 GitHub 上报告…」
- `GitHubIssue`：只拼链接，不代提交。按**编码后**的长度截断（一个汉字编码成九个字节，
  按字符数算会超得离谱），砍掉的多半是轨迹尾巴
- 入口：启动时主窗自动弹出（副窗不弹）；菜单 `帮助 › 报告问题…` 随时可写一份不带现场的；
  `帮助 › 崩溃报告文件夹` 直接开目录；`⌘K` 也能搜到「报告问题」
- 强退/断电（只有头没有栈）也报，但说清楚「这次没抓到现场」——原因不明比知道没抓到更难受

## 为什么不做「自动提交」

自动开 issue 需要一枚有写权限的 token，得存在这台机器上，还得向读者解释它能做什么。
为了一次点击的方便，把一把能改仓库的钥匙放在别人电脑里，不值。
预填页面是同样的两步（看一眼、按提交），却没有那把钥匙。

## 边界（这一版不做）

- 上传到自建服务 / 第三方崩溃平台：不联网是这一版的前提
- 采样与「是否发送」的同意管理：不发送就不需要同意
- 符号化：报告里给地址与基址，符号化在开发机上一句 `atos` 解决
  （应用被 ad-hoc 签名、每次发版二进制不同，内置符号表对不上）
- 卡顿（hang）检测：`SIGSEGV` 这一类能抓，主线程卡住不产生信号

## 验收

- [x] 真实 `raise(SIGSEGV)` → 现场文件里有信号名、栈、基址
- [x] 用 `atos -l <base>` 能把栈里的地址还原成函数名与行号
- [x] 正常退出（`NSApp.terminate`）→ 半成品被删掉，不产生报告
- [x] 下次启动 → 半成品被整理成 `.wtmdcrash`，面板拿到最新一份
- [x] 「忽略」→ 不再问，但文件仍在
- [x] 报告里没有正文，只有文件名
- [x] 预填链接在中文正文下不超长

## 落地记录（alpha + beta，2026-10-20）

- 新增 `CrashReport`（模型 / 元数据编解码 / 正文装配 / 轨迹解读）、
  `CrashCatcher`（信号处理器 + 轨迹）、`CrashStore`（账房）、`GitHubIssue`（只拼链接）、
  `CrashPanel`（面板）。
- **真实崩溃验证**：临时在 `wtmdApp.init` 里挂了 `raise(SIGSEGV)`（用完删掉），
  跑 `dist/wtmd.app` 得到现场文件；`atos -o dist/wtmd.app/Contents/MacOS/wtmd -l 0x1009ac000 0x1009e5ff4`
  还原出 `crashSignalHandler(_:) (CrashCatcher.swift:197)`——**基址是对的**，
  这意味着读者发来的报告，在开发机上能还原成函数名。
- 踩到两个坑：
  - `mach_header` 的第一个 `LC_SEGMENT_64` 是 `__PAGEZERO`（`vmaddr` 为 0），
    拿它当基址会写出一行 `base 0x0`。要跳过 `vmaddr == 0` 的那一段。
  - 正常退出只挂 `willTerminate` 不够：`osascript quit` 与终端里 Ctrl-C 都走不到那里。
    补 `atexit` 之后，`NSApp.terminate` 与正常退出都能清掉半成品。
- 报告正文里的标签分隔符跟着语言走（`Time: …` / `时间：…`），
  最早写成「英文标签 + 全角冒号」，读起来别扭。
- 「报告问题…」不直接拉浏览器，而是先摊开面板：看一眼要发出去的是什么，再按那个按钮。
- 测试 691 → **721**（`CrashReportTests` 12 / `CrashStoreTests` 9 / `GitHubIssueTests` 4 /
  `CrashPanelTests` 6）。
- 反向验证六组全红：harvest 不删原件 / 看过不落标记 / prune 不限份数 /
  超长正文按字符数判 / 窗口数取最早的 / 没帧也当崩溃。

## 进度

| 阶段 | 内容 | 估时 | 状态 |
| --- | --- | --- | --- |
| v0.14.0-alpha | 信号处理器、现场文件、操作轨迹 | 半个工作日 | ✅ 完成（2026-10-20） |
| v0.14.0-beta | 报告账房、面板、GitHub 预填链接 | 半个工作日 | ✅ 完成（2026-10-20） |
| v0.14.0-rc | 收尾、文档、发布 | 半个工作日 | ✅ 完成（2026-10-20） |

## 落地记录（rc，2026-10-20）

- README：徽章 v0.13.0 → v0.14.0、测试 691 → 721、特性列表补「崩了也说清楚」、路线图补 v0.14。
- PRODUCT.md 路线图补 v0.14。
- tag `v0.14.0` → DMG → GitHub Release。
- 存留策略：`crashes/` 最多 20 份、90 天；`.seen` 侧标只表示「已展示过」，
  文件仍在，随时可以再复制出来发给作者。

## 补丁（v0.14.1，2026-10-20）

发布两小时后收到第一份真实崩溃报告（issue #135）：**开着打字机模式，点一下编辑器必崩。**

- 栈：`-[NSTextView mouseDown:]` → 选区通知 → `textViewDidChangeSelection` →
  `recenter(animated:)` → `NSAnimationContext.runAnimationGroup` →
  `clipView.animator().setBoundsOrigin` → `NSViewHierarchyInvalidateVisibleRect` → `SIGSEGV`。
- 定位：真窗口探针（后来的 `EditorRecenterTests`）稳定复现。只去掉
  `allowsImplicitAnimation` 仍崩；把动画组挪到下一拍不崩但居中完全失效（offset 停在 14）；
  直接 `scroll(to:)` 既不崩也居中正确。所以问题不在「在事件栈里滚动」，在
  **`animator()` 改 clip view bounds 本身**——自绘 clip view（要能滚过内容末尾半屏）
  与 AppKit 的可见矩形失效逻辑对不上。
- 修法：`recenter()` 去掉动画，直接滚动；去掉只服务动画的 `animated` 参数与 `isRestoring`；
  补一条「视图不在窗口上就不碰滚动位置」的结构保护。
- 测试 721 → **725**（`EditorRecenterTests` 4 条，串行真窗口）；反向验证三组全红
  （把动画加回来时进程直接 SIGSEGV，与读者报告一致）。
- 教训：**动画代理只碰「不会引起布局连锁」的属性**。滚动位置会牵动可见矩形、
  牵动文档视图布局，在这种自绘滚动结构里不能交给 `animator()`。
