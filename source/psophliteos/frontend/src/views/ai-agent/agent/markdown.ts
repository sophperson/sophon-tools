import { marked, type Tokens } from 'marked';
import DOMPurify from 'dompurify';

export function escapeHtml(str: string): string {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

// 懒加载实例（动态 import 减小首屏体积，首次用到时才加载）
// 引入 highlight.js 的 common 全集（含 37 种常见语言），避免逐语言动态 import
// 导致的打包时路径无法静态解析。
let hljs: any = null;
let highlightReady: Promise<void> | null = null;

function ensureHighlight(): Promise<void> {
  if (hljs) return Promise.resolve();
  if (!highlightReady) {
    highlightReady = import('highlight.js/lib/common').then((mod) => {
      const lib = (mod as any).default || mod;
      if (lib && typeof lib.highlight === 'function') hljs = lib;
    });
  }
  return highlightReady;
}

let katexLib: any = null;
let katexReady: Promise<void> | null = null;

function ensureKatex(): Promise<void> {
  if (katexLib) return Promise.resolve();
  if (!katexReady) {
    katexReady = import('katex').then((mod) => {
      const lib = (mod as any).default || mod;
      if (lib && typeof lib.renderToString === 'function') katexLib = lib;
    });
  }
  return katexReady;
}

let mermaid: any = null;
let mermaidReady: Promise<void> | null = null;

function ensureMermaid(): Promise<void> {
  if (mermaid) return Promise.resolve();
  if (!mermaidReady) {
    mermaidReady = import('mermaid').then((mod) => {
      const lib = (mod as any).default || mod;
      if (lib && typeof lib.render === 'function') {
        mermaid = lib;
        if (typeof lib.initialize === 'function') {
          try {
            lib.initialize({ startOnLoad: false, securityLevel: 'strict' });
          } catch (e) {
            /* ignore */
          }
        }
      }
    });
  }
  return mermaidReady;
}

// marked 扩展：数学公式 + 代码块高亮（mermaid 代码块在主函数中预提取）
marked.use({
  renderer: {
    code({ text, lang, escaped }: { text: string; lang?: string; escaped?: boolean }) {
      // 普通代码块 → highlight.js 高亮（hljs 由调用方先 await ensureHighlight()）
      const normalized = (lang || '').toLowerCase();
      const raw = text.replace(/\n$/, '');
      if (hljs && normalized && hljs.getLanguage(normalized)) {
        try {
          const res = hljs.highlight(raw, { language: normalized });
          return `<pre class="webchat-codeblock"><code class="hljs language-${normalized}">${res.value}</code></pre>`;
        } catch (e) {
          /* fallthrough */
        }
      }
      return `<pre class="webchat-codeblock"><code>${escaped ? raw : escapeHtml(raw)}</code></pre>`;
    },
  },
  extensions: [
    {
      name: 'inlineMath',
      level: 'inline',
      start(src: string) {
        const i = src.indexOf('$');
        return i >= 0 ? i : undefined;
      },
      tokenizer(src: string) {
        const block = /^\$\$([\s\S]+?)\$\$/;
        let m = block.exec(src);
        if (m) return { type: 'inlineMath', raw: m[0], text: m[1], display: true };
        const inline = /^\$([^$\n\r]|\\.)+?\$/;
        m = inline.exec(src);
        if (m) return { type: 'inlineMath', raw: m[0], text: m[1], display: false };
        return undefined;
      },
      renderer(token: Tokens.Generic) {
        // 公式无法解析时回退为原文（原样输出）。katexLib 由调用方先把 await ensureKatex()
        if (!katexLib) return escapeHtml(token.raw);
        try {
          return katexLib.renderToString(token.text, { displayMode: token.display, throwOnError: true });
        } catch (e) {
          return escapeHtml(token.raw);
        }
      },
    },
  ],
});

const MERMAID_FENCE_RE = /^```mermaid\s*\n([\s\S]*?)```/gm;

/** mermaid 渲染：异步生成 SVG（失败/未就绪时返回空串）。 */
async function renderMermaid(code: string): Promise<string> {
  try {
    if (!mermaid) return '';
    const id = 'mermaid-' + Math.random().toString(36).slice(2, 10);
    const { svg } = await mermaid.render(id, code);
    if (!svg) return '';
    // mermaid 输出为 SVG + style（无脚本），消毒后插入
    return `<div class="webchat-mermaid">${DOMPurify.sanitize(svg, { ADD_ATTR: ['target', 'rel'] })}</div>`;
  } catch (e) {
    return '';
  }
}

/** 渲染 markdown → 安全 HTML。AI 内容不可信，一律经 DOMPurify 消毒。 */
export async function renderMarkdownToHtml(content: string): Promise<string> {
  const text = content || '';
  try {
    const mermaidBlocks: string[] = [];
    // 先抽离 mermaid 代码块（避免 marked 将其当普通代码块渲染）
    const src = text.replace(MERMAID_FENCE_RE, (match, body: string) => {
      mermaidBlocks.push(body);
      return `MERMAID${mermaidBlocks.length - 1}`;
    });
    // 先确保 katex 与 highlight.js 已加载（renderer 同步执行，需依赖就绪）
    await ensureKatex();
    await ensureHighlight();
    const html = DOMPurify.sanitize(marked.parse(src, { async: false }) as string, {
      ADD_ATTR: ['target', 'rel'],
      ADD_TAGS: ['math', 'mrow', 'mfrac', 'msqrt', 'mroot', 'msub', 'msup', 'msubsup', 'munder', 'mover', 'munderover', 'mn', 'mo', 'mi', 'mtext', 'ms', 'mspace', 'mtd', 'mtr', 'mtable', 'semantics', 'annotation', 'annotation-xml'],
    });
    if (mermaidBlocks.length) {
      try {
        await ensureMermaid();
      } catch (e) {
        /* 加载失败则回退代码块 */
      }
    }
    return await mermaidBlocks.reduce(
      (p: Promise<string>, block, i) =>
        p.then(async (acc) => {
          const svgHtml = await renderMermaid(block);
          return acc.replace(
            `MERMAID${i}`,
            svgHtml || `<pre class="webchat-codeblock"><code>${escapeHtml(block)}</code></pre>`
          );
        }),
      Promise.resolve(html)
    );
  } catch (e) {
    // 渲染失败时回退为纯文本（保证内容仍可读、不可信内容不被注入）
    return escapeHtml(text);
  }
}
