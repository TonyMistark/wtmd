# v0.2-alpha 任务拆解 — 主题系统专项

> 目标：主题系统完整落地。退出标准见文末验收清单。
> 预估：1 个工作日 ｜ 涉及文件：`Theme.swift`（重构）、`ThemeManager.swift`（新增）、`DocumentStore.swift`、`ContentView.swift`、`PreviewView.swift`、WTMarkdownKit 无改动

## 架构决策（实现前先读）

1. **两层 CSS**：现有 `Theme.css` 拆为 `base.css`（排版骨架：字体栈、间距、元素规则——不含颜色）+ 变量主题层（每个主题一组 `:root`/`@media (prefers-color-scheme)` 变量覆盖）。切主题 = 只替换变量层
2. **WebView 切主题协议**：注入 `__wtmdSetTheme(cssText)` JS 函数，替换 `<style id="wtmd-theme">` 元素内容；正文 DOM 不动、滚动不丢、无白屏
3. **主题解析在库层**：`.wttheme` 文件夹的发现/校验/加载逻辑独立成 `ThemeManager`（App 层），格式定义放枚举，可单测

## 任务清单

### A. 主题基础设施（先行，约 1.5h）

- [ ] A1. **拆分 CSS**：`Theme.swift` 中 `css` 拆为 `baseCSS`（排版骨架）+ `defaultThemeCSS`（现有颜色变量即默认主题）；`fullDocument` 改为注入两个 `<style>` 标签（`id="wtmd-base"`、`id="wtmd-theme"`）
- [ ] A2. **ThemeManager 骨架**：新建 `Sources/wtmd/ThemeManager.swift`。`Theme` 模型（id/name/author/hasLight/hasDark/来源）；扫描内置主题 + `~/Library/Application Support/wtmd/Themes/*.wttheme/`；`@Published var themes` / `currentThemeID`（UserDefaults 持久化）
- [ ] A3. **主题加载管线**：读取 `theme.json` → 校验必填字段（name）→ 读 `light.css`/`dark.css`（至少其一）→ 拼接为主题 CSS 文本（自动包裹 `:root{}` 与 `@media(prefers-color-scheme:dark){:root{}}`）；格式错误降级为默认主题并 console 提示
- [ ] A4. **单元测试**：`ThemeManager` 的 JSON 校验、CSS 拼接、非法主题跳过（放 App 层 tests？→ 决策：放 `Tests/wtmdTests/` 新 target，或先以手测+后续 CI 补；**取前者**，见 F2）

### B. 内置三主题（约 1.5h）

- [ ] B1. **默认主题**：现有变量原样迁移为内置主题「wtmd 默认」
- [ ] B2. **纸墨主题**：衬线字体栈（`"Songti SC", "Noto Serif SC", Georgia, serif`）、暖白 `--bg: #faf7f0`、墨色 `--fg: #2b2620`、朱砂 `--accent: #a63f34`；深色模式纸墨夜读（深褐底、米金字）；标题/正文衬线，代码块保持等宽
- [ ] B3. **终端主题**：等宽字体（含正文字体也改等宽）、高对比（近黑底 `--bg: #0d1117`、亮绿/青强调）、类似终端提示符的 blockquote 样式（`>` 前缀视觉）；仅深色（`hasLight=false` 时浅色模式也用同一套）
- [ ] B4. **主题资源打包**：三主题作为 Swift 字符串常量内置（不读文件系统，保 SPM 裸二进制可移植）；自定义主题仍走 `.wttheme` 目录

### C. 预览联动（约 1h）

- [ ] C1. **JS 注入**：`Theme.script` 增加主题函数：`__wtmdSetTheme(cssText)` —— 找到 `#wtmd-theme` style 元素替换内容
- [ ] C2. **PreviewView 联动**：`updateNSView` 监听 `themeCSS` 变化 → `evaluateJavaScript("__wtmdSetTheme(...)")`；首载时 `fullDocument` 直接带主题 CSS
- [ ] C3. **HTML 导出**：`exportHTML` 导出的独立文件内联 base + 当前主题 CSS（他人打开即所见）
- [ ] C4. **PDF 打印**：打印管线同样内联当前主题

### D. 主题 UI（约 1.5h）

- [ ] D1. **工具栏主题菜单**：`Menu` 列出所有主题（内置+自定义分组），当前项打勾；含「打开主题文件夹…」（`NSWorkspace.shared.open`）
- [ ] D2. **偏好设置面板**：Settings Scene；主题列表 + 每主题一行说明（作者/明暗支持）；选择即时生效
- [ ] D3. **导出 HTML 对话框**：导出时可选「跟随当前主题」/「默认主题」（默认跟随）
- [ ] D4. **键盘**：无快捷键占用（主题是低频操作，不为它分配全局键）

### E. 收尾（约 0.5h）

- [ ] E1. 手动验收：三主题 × 浅深色 × 模式切换 × 大纲跳转 × 导出 HTML/PDF，截图对比
- [ ] E2. 构建 + 全量测试 + 烟测（pkill 旧进程 + nohup 重启）
- [ ] E3. 提交：`feat: v0.2-alpha 主题系统`；推送；`git tag v0.2.0-alpha` + 推 tag
- [ ] E4. README 特性列表补「自定义 CSS 主题」；V02_PLAN.md 勾选 alpha 节

## 暂不做（防蔓延）

- 主题在线导入/URL 安装（先本地拖入）
- 主题编辑器/实时预览编辑
- 编辑器（源码模式）配色主题化——源码高亮走系统语义色，跟随系统深浅色即可，主题只管成文
- 编辑器字体设置（与主题无关的偏好项，v0.3 命令面板时再做）

## 验收标准（alpha 出口）

- [ ] 三内置主题切换即时生效，无白屏、无滚动丢失
- [ ] 自建一个 `.wttheme` 文件夹拖入 `Themes/` 目录，重启后在菜单出现且可用
- [ ] 非法 `theme.json` 不崩溃、降级默认
- [ ] 导出 HTML 双击打开即当前主题外观
- [ ] 打印 PDF 为当前主题
- [ ] 单测全过（含 ThemeManager 新用例）
- [ ] 构建烟测 8s 无崩溃

## 风险预案

| 风险 | 预案 |
|---|---|
| `Settings` Scene 在 SPM 裸二进制的菜单注册问题 | 若偏好面板无法弹出，降级为工具栏菜单内嵌子菜单（D2 降级方案） |
| 内置主题字符串维护痛苦 | 写一个 `Themes/` 源文件夹 + 构建期内联脚本（若简单字符串不够用再上） |
| WebView JS 注入时机（文档未加载完） | `evaluateJavaScript` 前检查 `webView.isLoading`，未就绪则入队 `didFinish` 后补发 |
