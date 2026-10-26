# 主题系统与外部主题兼容

本文说明 wtmd 的主题文件格式、它和行业标准的关系，以及如何把社区主题
（base16 / base24）转成 wtmd 能读的 `.wttheme`。

---

## 一、先说清楚：`light.css` / `dark.css` 不遵循任何行业规范

预览里主题那一段，本质就是一段 **CSS 自定义属性（CSS Custom Properties，
W3C 标准的 `--foo: value;`）** 的裸声明，被程序塞进 `:root { … }` 里：

```css
:root { color-scheme: light; /* light.css 的内容 */ }
@media (prefers-color-scheme: dark) {
  :root { color-scheme: dark; /* dark.css 的内容 */ }
}
```

- `light.css` / `dark.css` **只是文件名**，不是格式名。`theme.json` 里的
  `light` / `dark` 字段可以改成任何名字（不能带 `/`）。
- 文件里唯一有意义的是 `--变量: 值;` 这批声明，选择器由程序加。
- 技术上写整条规则也能跑（内置「终端」主题给 `blockquote` 加了双线框，
  WebKit 当 CSS 嵌套规则处理），但**推荐只写变量**——主题是数据，不该是样式表编程。

所以：**wtmd 没有"主题规范"，只有一份变量清单 + 一条"只写声明"的约定。**
好处是任何能产出 CSS 变量的工具都能做主题；代价是**没有任何社区会按我们的
变量名写主题**，社区主题不能直接扔进来用。

> 若要往"正式标准"上靠，CSS 侧只有 Custom Properties；设计令牌侧有 W3C
> Design Tokens Community Group 的 JSON 格式（DTCG），但主题社区基本不用它。
> 真正被主题社区广泛采纳的是下一节的 base16。

### 三层样式表，主题只占中间一层

| 层 | `<style>` id | 管什么 | 谁写 |
|---|---|---|---|
| 排版骨架 | `wtmd-base` | 标题层级、段落、代码块、表格、目录、脚注——**一个颜色都不含**，全走 `var(--x)` | 程序 |
| 主题变量层 | `wtmd-theme` | `--bg` `--fg` `--accent` `--font-body` 等 | **主题文件** |
| 版式层 | `wtmd-layout` | 版心宽度、字号、行距、代码块 Word Wrap | 读者（设置 › 版式） |
| 纸上版式 | `wtmd-print` | 打印 / PDF 的边距与页码 | 程序 |

切主题只替换 `#wtmd-theme` 那段文本，不重载页面：滚动位置不丢，只是 mermaid
图按新配色重绘一次。读者的字号行距也不会被主题带走。

主题同时决定**写作区**（`NSTextView`）的 `--bg` / `--fg` / `--font-mono`，
明暗各存一份、绘制时按系统外观自己挑，所以预览与写作区一起换装。

---

## 二、`.wttheme` 格式

一个主题是一个**文件夹**，不是单文件：

```
warm-sand.wttheme/
├── theme.json      ← 必须有
├── light.css       ← 至少这一个或 dark.css 有内容
└── dark.css
```

`theme.json`：

```json
{
  "name": "暖砂",
  "author": "wtmd",
  "light": "light.css",
  "dark": "dark.css"
}
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `name` | 是 | 空白或缺失 → 整个主题被静默跳过（不崩溃，列表里就是不出现） |
| `author` | 否 | 显示在设置 › 外观 |
| `light` / `dark` | 否 | 默认 `light.css` / `dark.css`；不许带 `/`（防路径逃逸） |

- 两份 CSS 都空（或都读不到）→ 跳过。
- 文件其余部分**不执行**：只有 CSS 文本和 JSON，第三方主题没有执行代码的风险。
- 主题 id = `custom.<文件夹名>`：覆盖安装就是覆盖同名文件夹，再点「重新扫描」。

### 变量清单

15 个常用变量（全部可选，缺了用骨架里的默认值）：

| 变量 | 用途 |
|---|---|
| `--bg` `--fg` | 页面底色 / 正文色（也决定写作区底色与字色） |
| `--secondary` | 次级文字（h6、脚注、状态类） |
| `--border` | 分隔线、表格框、标题下缘线 |
| `--accent` | 强调（选区、任务勾选、错误提示、链接悬停） |
| `--link` | 链接颜色 |
| `--code-bg` | 行内代码底 |
| `--pre-bg` `--pre-border` | 代码块底 / 边框 |
| `--th-bg` | 表头底 |
| `--quote-bar` `--quote-fg` | 引用左侧竖条 / 引用文字 |
| `--font-body` `--font-heading` `--font-mono` | 正文 / 标题 / 等宽字体栈 |

可选 6 个代码高亮覆盖（不写则从 `--accent` / `--fg` 派生）：
`--hl-keyword` `--hl-string` `--hl-number` `--hl-comment` `--hl-type` `--hl-meta`。

**不要把 `--wtmd-measure` / `--wtmd-font-size` / `--wtmd-line-height` 写进主题**
——那是读者的版式，版式层在这之后加载，写在主题里也会被覆盖。

### 安装

1. 设置 › 外观 › **打开主题文件夹…**（或 ⌘K 搜「主题文件夹」）
2. 把整个 `xxx.wttheme` 文件夹拖进 `~/Library/Application Support/wtmd/Themes/`
3. 回到设置点 **重新扫描**，列表里出现新主题，选中即生效

命令行等价：

```sh
cp -R xxx.wttheme ~/Library/Application\ Support/wtmd/Themes/
```

### 两个容易踩的点

- **颜色写 hex 最稳**：预览是 CSS，`rgb()` / `oklch()` 也能吃；但写作区只解析
  `#rgb` / `#rgba` / `#rrggbb` / `#rrggbbaa`，认不出就回落系统语义色（不崩，
  但写作区与预览会不一致）。
- **字体栈取第一个真实字族名**：`ui-monospace`、`monospace`、`system-ui` 这类
  通用关键字会被跳过；系统隐藏字体（名字以 `.` 开头）不能直接用，会拿到错误字重。

---

## 三、行业里有哪些"主题社区"

分两类：**配色方案库**（palette / scheme，只给颜色，跨应用）和
**应用主题**（绑死某个应用的 DOM / 配置键）。

| 生态 | 规模 | 格式 | 直接兼容的可行性 |
|---|---|---|---|
| **tinted-theming（base16 / base24）** | 230+ schemes，70+ 应用 | YAML，16（或 24）个**语义固定**的色槽 | **最好接**：色槽义固定、体量小、MIT 许可、跨应用一致 |
| VS Code Marketplace | 数千个主题 | 主题 JSON（`workbench.colors` + `tokenColors`），多数打包成 `.vsix` | 能接但要猜语义：`editor.background` 之类可映射，`tokenColors` 得按 TextMate scope 猜，质量参差 |
| Obsidian | 数百个 | CSS 片段，选择器绑 Obsidian 自己的 DOM 类名 | **不能直接接**——换一套 DOM 就全废，只能人眼抄颜色 |
| iTerm2 / Terminal.app / Alacritty / kitty / Ghostty | 各几十到几百套 | plist / 自有文本格式 | 只能取 16 个 ANSI 色，等价于 base16 的色槽 |
| Catppuccin / Dracula / Nord / Rosé Pine 等品牌 | 各 1 套 4 个变体 | 各家自己的 palette JSON / CSS 变量 | 逐个手写适配器，收益有限 |

**结论**：base16（现由 tinted-theming 维护，原 Chris Kempson 的 Base16）是唯一
同时满足「社区规模 + 机器可读 + 色槽语义固定 + 跨应用」的生态，所以它才是
"直接兼容一个主题社区"的正确目标。用户很可能本来就在 iTerm / VSCode / Vim
里用同一套 base16 配色，换到 wtmd 是同一个名字、同一组颜色。

- 仓库：<https://github.com/tinted-theming/schemes>（`base16/` 与 `base24/` 目录）
- 规范：`system` / `name` / `author` / `variant` / `palette.base00…base0F`（spec 0.11）；
  更早的 0.10 是扁平的 `scheme` / `author` / `base00…base0F`，两种都要认。
- 画廊：<https://tinted-theming.github.io/base16-gallery/>

### base16 色槽的语义

| 槽 | 含义 | 槽 | 含义 |
|---|---|---|---|
| `base00` | 背景（默认） | `base08` | 变量 / 红色 |
| `base01` | 背景（浅/深一档，表面） | `base09` | 常量 / 橙色 |
| `base02` | 背景（选区、边框） | `base0A` | 类 / 黄色 |
| `base03` | 注释、不可见 | `base0B` | 字符串 / 绿色 |
| `base04` | 深色前景、次级文字 | `base0C` | 支持 / 青色 |
| `base05` | 默认前景、正文 | `base0D` | 函数 / 蓝色 |
| `base06` | 浅色前景 | `base0E` | 关键字 / 紫色 |
| `base07` | 背景（最浅/最深） | `base0F` | 弃用 / 棕色 |

---

## 四、把 base16 主题转成 `.wttheme`

### 映射表

| wtmd 变量 | base16 槽 |
|---|---|
| `--bg` | `base00` |
| `--fg` | `base05` |
| `--secondary` | `base04` |
| `--border` / `--pre-border` | `base02` |
| `--accent` / `--link` | `base0D` |
| `--code-bg` / `--pre-bg` / `--th-bg` | `base01` |
| `--quote-bar` | `base03` |
| `--quote-fg` | `base04` |
| `--hl-keyword` | `base0E` |
| `--hl-string` | `base0B` |
| `--hl-number` | `base09` |
| `--hl-comment` | `base03` |
| `--hl-type` | `base0A` |
| `--hl-meta` | `base0C` |

字体不映射（base16 不含字体），留空即用骨架默认栈。

### 转换脚本

复制成一个文件、`chmod +x`，用法 `./base16-to-wttheme.py gruvbox-dark.yaml`。
只依赖 python3 标准库；同时认 spec 0.11（`palette:` 嵌套）和 0.10（扁平）两种写法。

```python
#!/usr/bin/env python3
"""Convert a base16/base24 scheme YAML into a wtmd .wttheme folder."""

import json
import pathlib
import re
import sys

# wtmd variable -> base16 slot
MAP = {
    "bg": "base00", "fg": "base05", "secondary": "base04",
    "border": "base02", "accent": "base0D", "link": "base0D",
    "code-bg": "base01", "pre-bg": "base01", "pre-border": "base02",
    "th-bg": "base01", "quote-bar": "base03", "quote-fg": "base04",
    "hl-keyword": "base0E", "hl-string": "base0B", "hl-number": "base09",
    "hl-comment": "base03", "hl-type": "base0A", "hl-meta": "base0C",
}
META_KEYS = {"system", "name", "scheme", "author", "slug", "variant", "description"}
SLOT = re.compile(r"base[0-9a-fA-F]{2}")


def parse(path):
    meta, palette = {}, {}
    for raw in pathlib.Path(path).read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("- "):
            line = line[2:]
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        key, value = key.strip(), value.strip()
        if value[:1] in ("'", '"'):
            quote = value[0]
            end = value.find(quote, 1)
            value = value[1:end] if end != -1 else value[1:]
        else:
            value = value.split("#", 1)[0].strip()
        if key in META_KEYS:
            meta[key] = value
        elif SLOT.fullmatch(key):
            # Normalise case: some schemes ship "base0a", the map uses "base0A".
            slot = "base" + key[4:].upper()
            palette[slot] = value if value.startswith("#") else "#" + value
    return meta, palette


def luminance(hex_color):
    body = hex_color.lstrip("#")
    if len(body) != 6:
        return 0.0
    channels = []
    for i in (0, 2, 4):
        c = int(body[i:i + 2], 16) / 255
        channels.append(c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4)
    r, g, b = channels
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: base16-to-wttheme.py <scheme.yaml>")
    source = pathlib.Path(sys.argv[1])
    meta, palette = parse(source)
    missing = [slot for slot in MAP.values() if slot not in palette]
    if missing:
        sys.exit(f"{source.name}: missing slots {sorted(set(missing))}")

    name = meta.get("name") or meta.get("scheme") or source.stem
    variant = meta.get("variant", "").lower()
    if variant not in ("light", "dark"):
        variant = "light" if luminance(palette["base00"]) > 0.5 else "dark"

    body = "\n".join(f"  --{var}: {palette[slot]};" for var, slot in MAP.items())
    css = body + "\n"

    slug = meta.get("slug") or source.stem
    target = (pathlib.Path.home() / "Library/Application Support/wtmd/Themes"
              / f"{slug}.wttheme")
    target.mkdir(parents=True, exist_ok=True)
    (target / "theme.json").write_text(
        json.dumps({"name": name, "author": meta.get("author", "")},
                   ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    # Only the variant we got; the loader accepts one-sided themes.
    (target / f"{variant}.css").write_text(css, encoding="utf-8")
    print(f"{name} -> {target}")


if __name__ == "__main__":
    main()
```

生成后回设置点「重新扫描」即可；预览与写作区一起换装。

**想让浅色/深色共用一套**：把生成的 `dark.css` 复制一份改名 `light.css`
（单变体的主题在两种外观下都用它，终端主题就是这么做的）。

### 一对多：base16 的明暗成对主题

base16 里很多主题是成对的（`gruvbox-dark` / `gruvbox-light`）。想让系统切深浅
色时自动跟着换，需要**一个** `.wttheme` 里同时放两份：跑两次脚本拿到两个
文件夹，把其中一个的 `dark.css`（或 `light.css`）拷到另一个里，再删掉多余的文件夹：

```sh
./base16-to-wttheme.py gruvbox-dark.yaml    # -> gruvbox-dark.wttheme/dark.css
./base16-to-wttheme.py gruvbox-light.yaml   # -> gruvbox-light.wttheme/light.css
cp ~/Library/Application\ Support/wtmd/Themes/gruvbox-light.wttheme/light.css \
   ~/Library/Application\ Support/wtmd/Themes/gruvbox-dark.wttheme/
```

### 换算质量提示

- base16 的 `base03` 是"注释色"，在深色主题里常偏暗。拿它当 `--quote-bar`
  可能太淡，必要时手调成 `base02`。
- `--accent` 用 `base0D`（蓝）最稳；喜欢更有性格的可以换 `base0E`（紫）或
  `base0A`（黄），但注意 `--accent` 也用于任务勾选和错误提示。
- 转换只在做主题时跑一次，不用跟着版本升级。

---

## 五、程序里做到哪一步了

base16 的**前十套**已经内置：`Theme.base16Map` 就是第四节那张映射表，色值以
`base00…base0F` 顺序写死在 `ThemeManager.swift` 的 `base16Schemes` 里，设置 ›
外观中单独分组显示。换一批主题只改那张表，其它地方不用动。

**导入器还没做**——`.yaml` 仍然不会被读取，用户要装自己的配色得跑第四节的
脚本。要接的话，最短路径是：

1. `ThemeFormat` 里加一个 `loadBase16(_ text: String) -> Theme?`，复用上面的映射表
   （纯函数，好测）；
2. `scanCustomThemes()` 除了目录，也扫主题目录下的 `*.yaml` / `*.yml` 单文件；
3. 想要"主题列表"体验，再加一个从 `tinted-theming/schemes` 拉清单的设置页，
   点一下下载并选中——这一步要联网，得单独讨论隐私与失败降级。

在此之前，本文的脚本就是那条链路的离线版本。
