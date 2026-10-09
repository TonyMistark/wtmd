# wtmd

**W**here **T**houghts **M**eet **D**ocuments

一个开源、本地优先的 macOS Markdown 写作与阅读工具。思绪落下的一刻，成文已然成型。

![Status](https://img.shields.io/badge/status-v0.1%20MVP-green) ![License](https://img.shields.io/badge/license-MIT-blue) ![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)

## 特性

- **思绪 ⇄ 成文** — `⌘/` 在源码与预览之间即刻切换；源码是思绪的原貌，预览是思绪的成文，同一窗口、无跳转
- **主题系统** — 内置「默认 / 纸墨 / 终端」三套主题；自定义主题拖入 `.wttheme` 文件夹即装，CSS 变量格式，切换即时生效不丢滚动
- **语法高亮源码编辑器** — 标题、强调、代码、链接、引用、列表一目了然
- **排版级预览** — 阅读级字体版式，浅色/深色主题自动跟随系统
- **大纲导航** — 侧栏自动生成标题层级，点击跳转，滚动时同步高亮当前章节
- **文件管理** — 最近文件、未命名草稿自动保存（重启不丢）
- **导出** — 独立 HTML 文件（内联主题）、打印/存为 PDF
- **零第三方依赖** — Markdown 解析器完全自研（`WTMarkdownKit`），17 项单元测试覆盖

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

- v0.2 — 脚注、Mermaid 图表、图片粘贴落地、增量渲染（[详见规划](docs/V02_PLAN.md)）
- v0.3 — 打字机模式、专注模式、命令面板
- v0.4 — WYSIWYG 编辑模式可行性评估

## 参与贡献

欢迎 issue 与 PR，主题与本地化优先。

## 协议

[MIT](LICENSE)
