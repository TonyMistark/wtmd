import Foundation

/// 排版基础层：字体栈、间距、元素规则——不含任何颜色/主题变量取值。
/// 颜色与字体由主题变量层（`<style id="wtmd-theme">`）提供。
enum StyleSheet {
    static let baseCSS = """
    * { box-sizing: border-box; }
    html { -webkit-text-size-adjust: 100%; }
    body {
      margin: 0;
      padding: 48px 32px 96px;
      background: var(--bg);
      color: var(--fg);
      font-family: var(--font-body);
      font-size: 16px;
      line-height: 1.75;
      -webkit-font-smoothing: antialiased;
    }
    #wtmd-content {
      max-width: 760px;
      margin: 0 auto;
    }
    h1, h2, h3, h4, h5, h6 {
      font-family: var(--font-heading, var(--font-body));
      font-weight: 650;
      line-height: 1.3;
      margin: 1.6em 0 0.7em;
      scroll-margin-top: 24px;
    }
    h1 { font-size: 1.9em; margin-top: 0.4em; padding-bottom: 0.35em; border-bottom: 1px solid var(--border); }
    h2 { font-size: 1.45em; padding-bottom: 0.3em; border-bottom: 1px solid var(--border); }
    h3 { font-size: 1.22em; }
    h4 { font-size: 1.08em; }
    h5 { font-size: 1em; }
    h6 { font-size: 0.94em; color: var(--secondary); }
    p { margin: 0.85em 0; }
    a { color: var(--link); text-decoration: none; }
    a:hover { text-decoration: underline; }
    strong { font-weight: 650; }
    code, pre, kbd, samp {
      font-family: var(--font-mono);
    }
    code {
      background: var(--code-bg);
      padding: 0.15em 0.4em;
      border-radius: 5px;
      font-size: 0.88em;
    }
    pre {
      background: var(--pre-bg);
      border: 1px solid var(--pre-border);
      border-radius: 9px;
      padding: 14px 16px;
      overflow: auto;
      line-height: 1.55;
      margin: 1.1em 0;
    }
    pre code {
      background: none;
      padding: 0;
      font-size: 0.86em;
    }
    blockquote {
      margin: 1.1em 0;
      padding: 0.1em 1.1em;
      border-left: 4px solid var(--quote-bar);
      color: var(--quote-fg);
    }
    blockquote > :first-child { margin-top: 0.6em; }
    blockquote > :last-child { margin-bottom: 0.6em; }
    ul, ol { margin: 0.85em 0; padding-left: 1.9em; }
    li { margin: 0.3em 0; }
    li.task {
      list-style: none;
      margin-left: -1.4em;
    }
    li.task input {
      accent-color: var(--accent);
      margin-right: 0.45em;
      vertical-align: -0.12em;
    }
    table {
      border-collapse: collapse;
      display: block;
      max-width: 100%;
      overflow: auto;
      margin: 1.1em 0;
      font-size: 0.95em;
    }
    th, td {
      border: 1px solid var(--border);
      padding: 6px 14px;
    }
    th { background: var(--th-bg); font-weight: 650; }
    img {
      max-width: 100%;
      border-radius: 4px;
    }
    hr {
      border: 0;
      border-top: 1px solid var(--border);
      margin: 2em 0;
    }
    .footnotes {
      margin-top: 2.5em;
      padding-top: 1.2em;
      border-top: 1px solid var(--border);
      font-size: 0.9em;
      color: var(--secondary);
    }
    .footnotes ol { padding-left: 1.6em; }
    sup.footnote-ref a {
      text-decoration: none;
      font-size: 0.8em;
      padding: 0 0.15em;
    }
    .footnote-backref { text-decoration: none; }
    /* 代码高亮取色：默认由主题的强调色/前景色派生，主题可用 --hl-* 覆盖，无需新增主题文件 */
    :root {
      --hl-keyword: var(--accent);
      --hl-string: color-mix(in srgb, var(--accent) 55%, var(--fg));
      --hl-number: color-mix(in srgb, var(--accent) 70%, var(--fg));
      --hl-comment: var(--secondary);
      --hl-type: color-mix(in srgb, var(--accent) 40%, var(--fg));
      --hl-meta: color-mix(in srgb, var(--secondary) 60%, var(--accent));
    }
    .hljs-comment, .hljs-quote { color: var(--hl-comment); font-style: italic; }
    .hljs-keyword, .hljs-selector-tag, .hljs-literal, .hljs-doctag, .hljs-deletion { color: var(--hl-keyword); }
    .hljs-string, .hljs-regexp, .hljs-symbol, .hljs-bullet, .hljs-addition { color: var(--hl-string); }
    .hljs-number, .hljs-variable, .hljs-template-variable, .hljs-attr, .hljs-attribute { color: var(--hl-number); }
    .hljs-type, .hljs-built_in, .hljs-class .hljs-title, .hljs-title.class_ { color: var(--hl-type); }
    .hljs-title, .hljs-title.function_, .hljs-section, .hljs-name,
    .hljs-selector-id, .hljs-selector-class { color: var(--hl-type); font-weight: 600; }
    .hljs-meta, .hljs-tag { color: var(--hl-meta); }
    .hljs-emphasis { font-style: italic; }
    .hljs-strong { font-weight: 650; }
    .hljs-link { text-decoration: underline; }
    ::selection { background: color-mix(in srgb, var(--accent) 25%, transparent); }
    @media print {
      body { padding: 0; max-width: none; }
      #wtmd-content { max-width: none; }
      pre { white-space: pre-wrap; word-break: break-word; }
      a { color: var(--link); }
    }
    """

    static let script = """
    function __wtmdUpdate(bodyHTML) {
      document.getElementById('wtmd-content').innerHTML = bodyHTML;
      if (typeof __wtmdHighlight === 'function') { __wtmdHighlight(); }
    }
    // 增量更新：替换第 prefix..(total-suffix) 块，保留前后缀节点（图片/图表不重画）
    function __wtmdUpdateRange(diff) {
      var container = document.getElementById('wtmd-content');
      if (!container) { return; }
      var children = container.children;
      var oldCount = children.length;
      var start = diff.prefix;
      var oldEnd = oldCount - diff.suffix;
      if (start < 0 || oldEnd < start) { return; }

      // 删除旧变化段
      for (var i = oldEnd - 1; i >= start; i--) {
        if (children[i]) { container.removeChild(children[i]); }
      }
      // 插入新变化段（模板一次性解析，性能优于逐节点）
      if (diff.replacement.length > 0) {
        var html = diff.replacement.join('');
        var template = document.createElement('template');
        template.innerHTML = html;
        var refNode = container.children[start] || null;
        while (template.content.firstChild) {
          container.insertBefore(template.content.firstChild, refNode);
        }
      }
      // 新插入的代码块需要着色（已着色的块由 data-wtmd-hl 标记跳过）
      if (typeof __wtmdHighlight === 'function') { __wtmdHighlight(container); }
    }
    function __wtmdSetTheme(cssText) {
      var el = document.getElementById('wtmd-theme');
      if (el) { el.textContent = cssText; }
    }
    (function () {
      var timer = null;
      window.addEventListener('scroll', function () {
        if (timer) return;
        timer = setTimeout(function () {
          timer = null;
          var slug = '';
          var heads = document.querySelectorAll('h1,h2,h3,h4,h5,h6');
          for (var i = 0; i < heads.length; i++) {
            var h = heads[i];
            if (h.id && h.getBoundingClientRect().top <= 100) slug = h.id;
            else if (h.getBoundingClientRect().top > 100) break;
          }
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.wtmd) {
            window.webkit.messageHandlers.wtmd.postMessage({ slug: slug });
          }
        }, 120);
      }, { passive: true });
    })();
    """

    /// 高亮初始化：与内嵌的 highlight.js 一起注入。
    /// 预览与静态导出共用同一份——导出的 HTML 也自带着色，离线打开即所见。
    private static let highlightInit = """
    // 只处理 ```lang 围栏块；未注册语言/渲染失败一律保持为普通代码块
    function __wtmdHighlight(root) {
      if (!window.hljs) { return; }
      var scope = root || document.getElementById('wtmd-content') || document;
      var nodes = scope.querySelectorAll('pre code[class*="language-"]');
      for (var i = 0; i < nodes.length; i++) {
        var el = nodes[i];
        if (el.getAttribute('data-wtmd-hl')) { continue; }
        var found = /language-([^\\s]+)/.exec(el.className);
        var lang = found ? found[1] : '';
        if (!lang || !window.hljs.getLanguage(lang)) { continue; }
        try {
          el.innerHTML = window.hljs.highlight(el.textContent, {
            language: lang, ignoreIllegals: true
          }).value;
          el.setAttribute('data-wtmd-hl', '1');
        } catch (e) { /* 降级：保持原代码块 */ }
      }
    }
    document.addEventListener('DOMContentLoaded', function () { __wtmdHighlight(); });
    """

    /// 完整高亮脚本：内嵌库 + 初始化。资源缺失时返回空串（退化为无高亮，正文不受影响）。
    static var highlightScript: String {
        let library = WebAssets.highlightJS
        guard !library.isEmpty else { return "" }
        return "\(library)\n\(highlightInit)"
    }

    /// 将明/暗两份变量文本拼为合法主题样式表。
    /// - 两者皆有：浅色进 `:root`，深色进 `prefers-color-scheme: dark`
    /// - 仅一份：直接进 `:root`（常亮）
    /// - 皆无：返回 nil（非法主题）
    static func cssText(light: String?, dark: String?) -> String? {
        let l = light?.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = dark?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasL = !(l?.isEmpty ?? true)
        let hasD = !(d?.isEmpty ?? true)
        switch (hasL, hasD) {
        case (false, false):
            return nil
        case (true, false):
            return ":root {\n\(l!)\n}\n"
        case (false, true):
            return ":root {\n\(d!)\n}\n"
        case (true, true):
            return ":root {\n\(l!)\n}\n@media (prefers-color-scheme: dark) {\n  :root {\n\(d!)\n  }\n}\n"
        }
    }

    /// 完整预览文档：排版骨架 + 主题变量层 + 内嵌前端资源 + 正文（+ 可选交互脚本）。
    /// 高亮脚本始终内联（预览/HTML 导出/PDF 三端一致）；交互脚本仅预览需要。
    static func fullDocument(
        title: String,
        body: String,
        themeCSS: String,
        includeScript: Bool
    ) -> String {
        let scriptTag = includeScript ? "<script>\n\(script)\n</script>\n" : ""
        let highlight = highlightScript
        let highlightTag = highlight.isEmpty ? "" : "<script>\n\(highlight)\n</script>\n"
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>\(title)</title>
        <style id="wtmd-base">\(baseCSS)</style>
        <style id="wtmd-theme">\(themeCSS)</style>
        \(highlightTag)\(scriptTag)</head>
        <body>
        <div id="wtmd-content">
        \(body)
        </div>
        </body>
        </html>
        """
    }
}
