/**
 * markdown.js — Markdown 渲染（T3）
 *
 * 职责：
 *   - marked.js 解析 Markdown → HTML
 *   - highlight.js 代码块高亮
 *   - DOMPurify sanitize 防 XSS（AI 回复内容不可信，必须过消毒）
 *
 * 对外暴露（挂 window.Markdown）：
 *   renderMarkdown(text)        → 安全 HTML 字符串（可直接 innerHTML）
 *   renderCodeBlock(code, lang) → 高亮后的 <pre><code> HTML
 *
 * 依赖 vendor/ 本地库（离线可用）。任一库缺失时自动降级：
 *   - 无 marked   → 纯文本渲染（escape 后换行 → <br>）
 *   - 无 hljs     → 代码块仅做转义，不高亮
 *   - 无 DOMPurify→ 仍渲染，但 console 告警提示 XSS 风险（正常部署必须带 purify）
 */
(function () {
  'use strict';

  var markedLib = window.marked;
  var hljsLib = window.hljs;
  var purifyLib = window.DOMPurify;

  // 允许的代码语言别名 → 传给 hljs 的语言名
  var LANG_ALIASES = {
    'js': 'javascript',
    'ts': 'typescript',
    'py': 'python',
    'sh': 'bash',
    'shell': 'bash',
    'html': 'xml',
    'yml': 'yaml',
    'c++': 'cpp',
    'cs': 'csharp',
    'txt': 'plaintext',
    'text': 'plaintext'
  };

  function resolveLang(lang) {
    if (!lang) return '';
    var l = String(lang).trim().toLowerCase();
    if (LANG_ALIASES[l]) return LANG_ALIASES[l];
    return l;
  }

  function escapeHtml(str) {
    return String(str)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  /** 文本 → 段落 HTML：转义后按换行分段，避免纯文本降级时挤成一行 */
  function escapeParagraphs(text) {
    var lines = String(text).replace(/\r\n/g, '\n').split('\n');
    var out = [];
    var para = [];
    function flush() {
      if (para.length) {
        out.push('<p>' + para.join('<br>') + '</p>');
        para = [];
      }
    }
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trim() === '') {
        flush();
      } else {
        para.push(escapeHtml(lines[i]));
      }
    }
    flush();
    return out.join('');
  }

  /** 代码块 → 高亮 HTML。lang 缺省/未知语言时走 highlightAuto 或纯转义 */
  function renderCodeBlock(code, lang) {
    var langName = resolveLang(lang);
    var codeCls = 'hljs';
    if (langName) codeCls += ' language-' + escapeHtml(lang);
    var dataLang = lang ? ' data-lang="' + escapeHtml(lang) + '"' : '';
    var inner;

    if (hljsLib && typeof hljsLib.highlight === 'function') {
      try {
        if (langName && hljsLib.getLanguage(langName)) {
          inner = hljsLib.highlight(String(code), { language: langName }).value;
        } else {
          // 无语言/未知语言：自动识别，失败则纯转义
          var auto = hljsLib.highlightAuto(String(code));
          inner = auto && auto.value ? auto.value : escapeHtml(code);
        }
      } catch (e) {
        inner = escapeHtml(code);
      }
    } else {
      inner = escapeHtml(code);
    }

    return '<pre' + dataLang + '><code class="' + codeCls + '">' + inner + '</code></pre>';
  }

  /**
   * 渲染 Markdown 文本为安全 HTML。
   * @param {string} text
   * @returns {string} 可安全写入 innerHTML 的 HTML 字符串
   */
  function renderMarkdown(text) {
    if (text === null || text === undefined) return '';
    text = String(text);

    // 非字符串/空内容
    if (!text.trim()) return '';

    var html;
    if (markedLib && typeof markedLib.parse === 'function') {
      // marked v4：定制渲染器注入代码高亮
      try {
        var renderer = new markedLib.Renderer();
        renderer.code = function (code, infostring) {
          return renderCodeBlock(code, infostring);
        };
        html = markedLib.parse(text, { renderer: renderer, breaks: true, gfm: true });
      } catch (e) {
        html = escapeParagraphs(text);
      }
    } else {
      // 无 marked：纯文本降级
      html = escapeParagraphs(text);
    }

    // 安全底线：过 DOMPurify
    if (purifyLib && typeof purifyLib.sanitize === 'function') {
      try {
        return purifyLib.sanitize(html, { USE_PROFILES: { html: true } });
      } catch (e) {
        return escapeParagraphs(text);
      }
    }
    if (window.console && console.warn) {
      console.warn('[markdown] DOMPurify 未加载，输出未经消毒（存在 XSS 风险）');
    }
    return html;
  }

  window.Markdown = {
    renderMarkdown: renderMarkdown,
    renderCodeBlock: renderCodeBlock
  };
})();
