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
    /* [TOC] 目录：轻量框内按标题层级缩进 */
    .wtmd-toc {
      margin: 1.1em 0;
      padding: 0.7em 1.1em;
      border: 1px solid var(--border);
      border-radius: 6px;
      font-size: 0.95em;
    }
    .wtmd-toc:empty { display: none; }
    .wtmd-toc-list { list-style: none; margin: 0; padding: 0; }
    .wtmd-toc-list li { margin: 0.25em 0; }
    .wtmd-toc-l2 { padding-left: 1.2em; }
    .wtmd-toc-l3 { padding-left: 2.4em; }
    .wtmd-toc-l4 { padding-left: 3.6em; }
    .wtmd-toc-l5 { padding-left: 4.8em; }
    .wtmd-toc-l6 { padding-left: 6em; }
    .wtmd-toc a { color: var(--fg); text-decoration: none; }
    .wtmd-toc a:hover { color: var(--accent); text-decoration: underline; }
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
    /* Mermaid 图表：源码块默认可见，渲染成功后隐去；失败则保留源码并提示 */
    .mermaid-wrap { margin: 1.1em 0; text-align: center; }
    .mermaid-wrap.mermaid-rendered > pre { display: none; }
    .mermaid-wrap.mermaid-failed > .mermaid { display: none; }
    .mermaid-wrap svg { max-width: 100%; height: auto; }
    .mermaid-error { color: var(--accent); font-size: 0.88em; text-align: left; margin: 0.6em 0 0; }
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
      if (typeof __wtmdMermaidRenderAll === 'function') { __wtmdMermaidRenderAll(false); }
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
      // 新插入的 mermaid 块需要渲染，未变化块的已渲染 SVG 保持原位
      if (typeof __wtmdMermaidRenderAll === 'function') { __wtmdMermaidRenderAll(false); }
    }
    function __wtmdSetTheme(cssText) {
      var el = document.getElementById('wtmd-theme');
      if (el) { el.textContent = cssText; }
      // 图表颜色已烘焙进 SVG，主题变量变化后需按新配色重绘
      if (typeof __wtmdMermaidRenderAll === 'function') { __wtmdMermaidRenderAll(true); }
    }
    (function () {
      // 目录/内链锚点：页内平滑滚动，避免 WebView 把 #hash 当作导航。
      // 事件委托挂在 document 上，不触碰 #wtmd-content 的子节点结构。
      document.addEventListener('click', function (e) {
        var a = e.target && e.target.closest ? e.target.closest('a[href^="#"]') : null;
        if (!a) { return; }
        var id = a.getAttribute('href').slice(1);
        var target = id ? document.getElementById(id) : null;
        if (!target) { return; }
        e.preventDefault();
        target.scrollIntoView({ behavior: 'smooth', block: 'start' });
      });
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

    /// Mermaid 初始化：与内嵌的 mermaid 一起注入（仅在文档含 mermaid 围栏时）。
    /// ```mermaid 块渲染为图；失败降级为原代码块 + 错误提示，不白屏。
    private static let mermaidInit = """
    // 主题变量 → 图表配色（深浅色自适应，不新增主题文件）
    function __wtmdMermaidThemeVariables() {
      var cs = getComputedStyle(document.documentElement);
      function pick(name, fallback) {
        var value = cs.getPropertyValue(name).trim();
        return value || fallback;
      }
      return {
        background: pick('--bg', '#ffffff'),
        primaryColor: pick('--pre-bg', '#f5f5f5'),
        primaryTextColor: pick('--fg', '#222222'),
        primaryBorderColor: pick('--border', '#dddddd'),
        secondaryColor: pick('--th-bg', '#eeeeee'),
        tertiaryColor: pick('--code-bg', '#f5f5f5'),
        lineColor: pick('--quote-bar', '#888888'),
        fontFamily: pick('--font-body', 'sans-serif')
      };
    }

    function __wtmdMermaidInit() {
      if (!window.mermaid) { return false; }
      window.mermaid.initialize({
        startOnLoad: false,
        securityLevel: 'strict',
        theme: 'base',
        themeVariables: __wtmdMermaidThemeVariables()
      });
      return true;
    }

    var __wtmdMermaidSeq = 0;

    // 打印/存 PDF 的就绪信号：图表渲染完成后再进打印队列
    function __wtmdMermaidReady() {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.wtmd) {
        window.webkit.messageHandlers.wtmd.postMessage({ event: 'mermaid-ready' });
      }
    }

    // 清理 mermaid 自己在 DOM 上留下的临时节点：解析失败时它会往 document.body 追加
    // <div id="d{id}">（内含 "Syntax error in text" 的错误 SVG），落在 #wtmd-content 之外
    // 就成了文末一个可见脏块，而且每次重绘再积一份。只删正文容器之外的，避免误删已渲染的图。
    function __wtmdMermaidPurge(id) {
      var content = document.getElementById('wtmd-content');
      function drop(node) {
        if (node && node.parentNode && (!content || !content.contains(node))) {
          node.parentNode.removeChild(node);
        }
      }
      drop(document.getElementById('d' + id));
      drop(document.getElementById(id));
    }

    // 单个图表：成功则替换为 SVG，失败则保留源码块并给出错误提示
    function __wtmdMermaidDraw(target, source) {
      __wtmdMermaidSeq += 1;
      var id = 'wtmd-mermaid-' + __wtmdMermaidSeq;
      var wrap = target.parentNode;
      if (wrap && wrap.setAttribute) { wrap.setAttribute('data-wtmd-src', source); }
      return window.mermaid.render(id, source).then(function (result) {
        target.innerHTML = result.svg;
        __wtmdMermaidPurge(id);
        if (wrap && wrap.classList) {
          wrap.classList.remove('mermaid-failed');
          wrap.classList.add('mermaid-rendered');
        }
        return true;
      }).catch(function (error) {
        __wtmdMermaidPurge(id);
        var full = (error && error.message) ? String(error.message) : '语法无法解析';
        if (wrap && wrap.classList) {
          wrap.classList.add('mermaid-failed');
          var note = wrap.querySelector('.mermaid-error');
          if (!note) {
            note = document.createElement('p');
            note.className = 'mermaid-error';
            wrap.appendChild(note);
          }
          // mermaid 的解析诊断是多行的（含脱字符指向出错位置），行内压成单行并限长，
          // 完整诊断放到 title 上——悬停可见，不撑坏正文版式
          var inline = full.replace(/\\s+/g, ' ').trim();
          if (inline.length > 200) { inline = inline.slice(0, 200) + '…'; }
          note.textContent = '图表渲染失败：' + inline;
          note.title = full;
        }
        return false;
      });
    }

    // 扫描并渲染；force=true 时按当前主题重绘已渲染的图
    function __wtmdMermaidRenderAll(force) {
      var container = document.getElementById('wtmd-content');
      if (!container || !__wtmdMermaidInit()) { __wtmdMermaidReady(); return; }

      var jobs = [];
      var codes = container.querySelectorAll('pre > code.language-mermaid');
      for (var i = 0; i < codes.length; i++) {
        var code = codes[i];
        var pre = code.parentNode;
        var host = pre.parentNode;
        var wrapped = host && host.classList && host.classList.contains('mermaid-wrap');
        if (wrapped) {
          if (!force) { continue; }
          var target = host.querySelector('.mermaid');
          if (!target) { continue; }
          // 上次就因语法失败、且源码没变的块：重试还是同样的错误，跳过。
          // 否则每次切主题都会再失败一次（并在 body 上再留一份错误 SVG）
          if (host.classList.contains('mermaid-failed') &&
              host.getAttribute('data-wtmd-src') === code.textContent) { continue; }
          target.textContent = code.textContent;
          jobs.push(__wtmdMermaidDraw(target, code.textContent));
          continue;
        }
        // 首次：包一层 .mermaid-wrap —— 顶层块数量保持不变（增量 diff 依赖这一点）
        var graph = document.createElement('div');
        graph.className = 'mermaid';
        graph.textContent = code.textContent;
        var wrap = document.createElement('div');
        wrap.className = 'mermaid-wrap';
        pre.parentNode.insertBefore(wrap, pre);
        wrap.appendChild(pre);        // 源码块保留，作为渲染失败时的降级内容
        wrap.appendChild(graph);
        jobs.push(__wtmdMermaidDraw(graph, code.textContent));
      }
      if (jobs.length === 0) { __wtmdMermaidReady(); return; }
      Promise.all(jobs).then(function () { __wtmdMermaidReady(); });
    }

    document.addEventListener('DOMContentLoaded', function () { __wtmdMermaidRenderAll(false); });
    """

    /// 完整 mermaid 脚本：内嵌库 + 初始化。资源缺失时返回空串。
    static var mermaidScript: String {
        let library = WebAssets.mermaidJS
        guard !library.isEmpty else { return "" }
        return "\(library)\n\(mermaidInit)"
    }

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
    /// 高亮脚本始终内联（预览/HTML 导出/PDF 三端一致）；mermaid 体积大，
    /// 仅在文档确实含 mermaid 围栏时注入（懒加载）；交互脚本仅预览需要。
    static func fullDocument(
        title: String,
        body: String,
        themeCSS: String,
        includeScript: Bool
    ) -> String {
        let scriptTag = includeScript ? "<script>\n\(script)\n</script>\n" : ""
        let highlight = highlightScript
        let highlightTag = highlight.isEmpty ? "" : "<script>\n\(highlight)\n</script>\n"
        let mermaid = body.contains("language-mermaid") ? mermaidScript : ""
        let mermaidTag = mermaid.isEmpty ? "" : "<script>\n\(mermaid)\n</script>\n"
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>\(title)</title>
        <style id="wtmd-base">\(baseCSS)</style>
        <style id="wtmd-theme">\(themeCSS)</style>
        \(mermaidTag)\(highlightTag)\(scriptTag)</head>
        <body>
        <div id="wtmd-content">
        \(body)
        </div>
        </body>
        </html>
        """
    }
}
