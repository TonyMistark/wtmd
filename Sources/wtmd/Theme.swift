import Foundation

/// 预览主题与完整 HTML 文档构建。
enum Theme {
    static let css = """
    :root {
      --bg: #ffffff;
      --fg: #1f2328;
      --secondary: #59636e;
      --border: #d1d9e0;
      --accent: #0969da;
      --link: #0969da;
      --code-bg: #f0f2f5;
      --pre-bg: #f6f8fa;
      --pre-border: #e4e8ec;
      --th-bg: #f6f8fa;
      --quote-bar: #d1d9e0;
      --quote-fg: #59636e;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #1e2126;
        --fg: #e2e6eb;
        --secondary: #9aa4af;
        --border: #3d444d;
        --accent: #6cb2ff;
        --link: #6cb2ff;
        --code-bg: #2b2f36;
        --pre-bg: #25282e;
        --pre-border: #33373d;
        --th-bg: #25282e;
        --quote-bar: #3d444d;
        --quote-fg: #9aa4af;
      }
    }
    * { box-sizing: border-box; }
    html { -webkit-text-size-adjust: 100%; }
    body {
      margin: 0;
      padding: 48px 32px 96px;
      background: var(--bg);
      color: var(--fg);
      font-family: -apple-system, "SF Pro Text", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
      font-size: 16px;
      line-height: 1.75;
      -webkit-font-smoothing: antialiased;
    }
    #wtmd-content {
      max-width: 760px;
      margin: 0 auto;
    }
    h1, h2, h3, h4, h5, h6 {
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
      font-family: "SF Mono", ui-monospace, Menlo, Consolas, monospace;
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

    static func fullDocument(title: String, body: String, includeScript: Bool) -> String {
        let scriptTag = includeScript ? "<script>\n\(script)\n</script>\n" : ""
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>\(title)</title>
        <style>\(css)</style>
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
