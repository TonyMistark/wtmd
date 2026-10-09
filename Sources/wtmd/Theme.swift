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

    /// 完整预览文档：排版骨架 + 主题变量层 + 正文（+ 可选交互脚本）。
    static func fullDocument(
        title: String,
        body: String,
        themeCSS: String,
        includeScript: Bool
    ) -> String {
        let scriptTag = includeScript ? "<script>\n\(script)\n</script>\n" : ""
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>\(title)</title>
        <style id="wtmd-base">\(baseCSS)</style>
        <style id="wtmd-theme">\(themeCSS)</style>
        \(scriptTag)</head>
        <body>
        <div id="wtmd-content">
        \(body)
        </div>
        </body>
        </html>
        """
    }
}
