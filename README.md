# wtmd

**W**here **T**houghts **M**eet **D**ocuments

一个开源、本地优先的 macOS Markdown 写作与阅读工具。思绪落下的一刻，成文已然成型。

![Status](https://img.shields.io/badge/status-v0.2.0-green) ![License](https://img.shields.io/badge/license-MIT-blue) ![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)

## 特性

- **思绪 ⇄ 成文** — `⌘/` 在源码与预览之间即刻切换；源码是思绪的原貌，预览是思绪的成文，同一窗口、无跳转
- **主题系统** — 内置「默认 / 纸墨 / 终端」三套主题；自定义主题拖入 `.wttheme` 文件夹即装，CSS 变量格式，切换即时生效不丢滚动
- **图片粘贴即成文** — 截图/拖入图片自动落地 `assets/` 目录并插入相对路径引用，文档目录整体拷贝依然自洽
- **脚注** — `[^id]` 引用与定义，文末自动编号汇总，双向锚点跳转
- **代码高亮** — 预览中 ```lang 围栏代码块按语言着色；本地内嵌 highlight.js（36 种常用语言），离线可用、不外联网，配色由当前主题派生，未识别的语言保持纯文本
- **Mermaid 图表** — ```mermaid 围栏渲染为流程图/时序图，本地内嵌 mermaid，配色随主题变量自适应；渲染失败降级为原代码块并提示错误，打印与导出同样出图
- **实时统计** — 状态栏字数/词数/阅读时长，中英混合口径，Markdown 感知（代码块与 URL 不掺水）
- **语法高亮源码编辑器** — 标题、强调、代码、链接、引用、列表一目了然
- **排版级预览** — 阅读级字体版式，浅色/深色主题自动跟随系统
- **大纲导航** — 侧栏自动生成标题层级，点击跳转，滚动时同步高亮当前章节
- **文件管理** — 最近文件、未命名草稿自动保存（重启不丢）
- **导出** — 独立 HTML 文件（内联主题）、打印/存为 PDF
- **零第三方依赖** — Markdown 解析器完全自研（`WTMarkdownKit`），69 项单元测试覆盖，GitHub Actions 双系统 CI

## 快速开始

```bash
git clone <repo-url> && cd wtmd
swift run
```

或只构建：

```bash
swift build -c release
.build/release/wtmd
```

要求：macOS 14+，Xcode 15+（含 Swift 工具链）。

## 打包

```bash
./make-app.sh     # 生成 dist/wtmd.app（含内嵌前端资源，本地签名）
./make-dmg.sh     # 生成 dist/wtmd-<版本>.dmg（v0.3 首发对外分发）
```

## 设计哲学

1. **写作即排版** — 源码与预览是同一份文本的两种视图
2. **极简无干扰** — 界面只在需要时出现
3. **纯文本本质** — 底层永远是标准 Markdown（兼容 GFM 方言）
4. **本地优先** — 不强制云端、不要求账号，文件属于你自己
5. **开放可塑** — MIT 协议，主题开放

详见 [docs/PRODUCT.md](docs/PRODUCT.md)。

## 支持

`WTMarkdownKit` 可独立用于 Markdown → HTML 渲染与大纲提取：

```swift
import WTMarkdownKit

let result = WTMarkdown.render("# 标题\n\n正文 **加粗**")
result.html    // "<h1 id=\"标题\">标题</h1>\n<p>正文 <strong>加粗</strong></p>"
result.outline // [OutlineItem(level: 1, text: "标题", slug: "标题", line: 0)]
```

已覆盖：标题、段落、粗体/斜体/删除线、行内代码、链接、图片、自动链接、硬换行、无序/有序/嵌套/任务列表、引用（可嵌套）、围栏代码块、GFM 表格（含对齐）、分隔线、HTML 转义、中文锚点。

## 路线图

- v0.1 — 已发布：双模式视图、大纲导航、文件管理、HTML/PDF 导出
- v0.2 — **已发布（v0.2.0）**：主题系统、图片粘贴落地、脚注、实时统计、长文档增量渲染、预览代码高亮、Mermaid 图表（[详见规划](docs/V02_PLAN.md)）
- v0.3 — 打字机模式、专注模式、命令面板、文件夹工作区、DMG 分发
- v0.4 — WYSIWYG 编辑模式可行性评估

## 参与贡献

欢迎 issue 与 PR，主题与本地化优先。

## 协议

[MIT](LICENSE)
