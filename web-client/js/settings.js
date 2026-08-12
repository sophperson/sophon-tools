/**
 * settings.js — 设置面板逻辑（T3，T4 改为仅 Reasonix 后端）
 *
 * 职责：
 *   - 设置面板：WebSocket 地址、token（forward key）、主题（浅/深色）
 *   - localStorage 持久化（键 pico-web-chat.settings，与 chat.js 共用）
 *   - 默认（且仅）连接 Reasonix WS 端点：ws://<host>:<port>/agent/ws（子协议 token.<forward_key>）
 *   - 主题切换：data-theme 属性即时生效并记忆
 *   - token 输入框显示/隐藏切换（敏感信息）
 *   - 保存后通过 onSave 回调重建 WebSocket 连接（应用新 token/地址）
 *
 * 依赖：chat.js 先加载，通过 window.ChatApp.getSettings / connect 协同。
 * 面板 DOM 结构由 index.html 静态提供（T1 已就位，T4 移除后端下拉）。
 */
(function () {
  'use strict';

  var SETTINGS_KEY = 'pico-web-chat.settings';
  var THEME_KEY = 'pico-web-chat.theme';

  // Reasonix 默认值：与 ws.js 保持一致（ws.js 先加载）。
  var REASONIX_DEFAULT_PORT = (window.PicoConstants && window.PicoConstants.REASONIX_DEFAULT_PORT) || 18990;
  var REASONIX_DEFAULT_WS_PATH = (window.PicoConstants && window.PicoConstants.REASONIX_DEFAULT_WS_PATH) || '/agent/ws';

  /** 部署层注入配置（T6）：ws.js 提供 PicoConfig.injected()；缺失时视为无注入 */
  function injected() {
    if (window.PicoConfig && typeof window.PicoConfig.injected === 'function') {
      try { return window.PicoConfig.injected(); } catch (e) { return null; }
    }
    return null;
  }

  /** localStorage 是否已显式保存过非空 token */
  function hasLocalToken() {
    try {
      var s = JSON.parse(localStorage.getItem(SETTINGS_KEY) || '{}');
      return typeof s.token === 'string' && s.token.length > 0;
    } catch (e) {
      return false;
    }
  }

  /** 当前 token 是否为「仅注入」：localStorage 未显式保存，且注入配置存在 */
  function isTokenInjectedOnly() {
    return !hasLocalToken() && !!(injected() && injected().token);
  }

  /** Reasonix 默认 ws 地址：注入配置优先，否则当前主机 + 默认端口 */
  function defaultWsUrl() {
    var inj = injected();
    if (inj && inj.wsUrl) return inj.wsUrl;
    return 'ws://' + window.location.hostname + ':' + REASONIX_DEFAULT_PORT + REASONIX_DEFAULT_WS_PATH;
  }

  function defaultSettings() {
    var inj = injected();
    return {
      wsUrl: defaultWsUrl(),
      token: inj && inj.token ? inj.token : '',
      model: 'DeepSeek-V4-Flash-0731',
      theme: 'light'
    };
  }

  function load() {
    var defaults = defaultSettings();
    try {
      var raw = localStorage.getItem(SETTINGS_KEY);
      var s = raw ? JSON.parse(raw) : {};
      s = Object.assign({}, defaults, s);
      // 兼容 T2：无 wsUrl 时用默认地址推导
      if (!s.wsUrl) s.wsUrl = defaults.wsUrl;
      if (s.theme !== 'light' && s.theme !== 'dark') s.theme = defaults.theme;
      // 开箱即用（T6）：localStorage 未显式保存 token 时，用注入配置兜底，
      // 使页面加载即可对话；该值不写回 localStorage（避免敏感信息落入浏览器存储）。
      if (!hasLocalToken() && defaults.token) s.token = defaults.token;
      return s;
    } catch (e) {
      return defaults;
    }
  }

  function save(s) {
    var out = s;
    try {
      // 开箱即用（T6）：token 仅来自注入配置时，不写回 localStorage
      // （避免把部署层注入的敏感信息落入浏览器存储；显式填写的 token 正常持久化）
      var inj = injected();
      if (!hasLocalToken() && inj && inj.token && out.token === inj.token) {
        out = Object.assign({}, s);
        delete out.token;
      }
      localStorage.setItem(SETTINGS_KEY, JSON.stringify(out));
    } catch (e) { /* 存储满等忽略 */ }
  }

  function getTheme() {
    try {
      var t = localStorage.getItem(THEME_KEY);
      return t === 'dark' || t === 'light' ? t : null;
    } catch (e) {
      return null;
    }
  }

  function applyTheme(theme) {
    var root = document.documentElement;
    // 需求要求设在 document.documentElement；同时同步到 body 以兼容 T1 的 body[data-theme] 选择器
    root.setAttribute('data-theme', theme);
    if (document.body) document.body.setAttribute('data-theme', theme);
    // 切换 highlight.js 主题（浅/深各一份 CSS，link[disabled] 控制）
    var light = document.getElementById('hljs-theme-light');
    var dark = document.getElementById('hljs-theme-dark');
    if (light) light.disabled = theme !== 'light';
    if (dark) dark.disabled = theme !== 'dark';
    try {
      localStorage.setItem(THEME_KEY, theme);
    } catch (e) { /* 忽略 */ }
  }

  function initTheme() {
    // 优先级：localStorage 记忆值 > 设置面板当前值 > 默认浅色
    var s = load();
    var theme = getTheme() || s.theme || 'light';
    applyTheme(theme);
    return theme;
  }

  function setTheme(theme) {
    applyTheme(theme);
    var s = load();
    s.theme = theme;
    save(s);
    var sel = document.getElementById('setting-theme');
    if (sel) sel.value = theme;
  }

  function open() {
    var modal = document.getElementById('settings-modal');
    if (!modal) return;
    var s = load();
    var wsEl = document.getElementById('setting-ws');
    var tokenEl = document.getElementById('setting-token');
    var modelEl = document.getElementById('setting-model');
    var themeSel = document.getElementById('setting-theme');
    if (wsEl) wsEl.value = s.wsUrl || '';
    // 开箱即用（T6）：token 仅来自注入配置时不回显到输入框（避免泄露长度/值），
    // 由连接逻辑直接使用；仅当用户已显式保存过 token 才回显。
    if (tokenEl) tokenEl.value = hasLocalToken() ? (s.token || '') : '';
    if (modelEl) modelEl.value = s.model || '';
    if (themeSel) themeSel.value = s.theme || 'light';
    // 注入配置提示：localStorage 未显式保存且注入存在时提示「已自动配置」
    var hint = document.getElementById('setting-token-hint');
    if (hint) hint.hidden = !isTokenInjectedOnly();
    modal.hidden = false;
    if (tokenEl) tokenEl.focus();
  }

  function close() {
    var modal = document.getElementById('settings-modal');
    if (modal) modal.hidden = true;
  }

  function isOpen() {
    var modal = document.getElementById('settings-modal');
    return !!modal && !modal.hidden;
  }

  function saveFromForm() {
    var s = load();
    var wsEl = document.getElementById('setting-ws');
    var tokenEl = document.getElementById('setting-token');
    var modelEl = document.getElementById('setting-model');
    var themeSel = document.getElementById('setting-theme');
    var typedToken = tokenEl && tokenEl.value.trim();
    var next = {
      wsUrl: (wsEl && wsEl.value.trim()) || s.wsUrl,
      // token 语义（T6）：
      //   - 用户显式填写 → 保存并持久化
      //   - 用户留空 → 视为「清除个人配置」，回退到注入配置（若存在）或空；不把注入值写回 localStorage
      token: typedToken || (isTokenInjectedOnly() ? (injected().token || '') : ''),
      model: (modelEl && modelEl.value.trim()) || s.model,
      theme: (themeSel && themeSel.value) || s.theme
    };
    // 空 wsUrl 回退默认地址
    if (!next.wsUrl) next.wsUrl = defaultSettings().wsUrl;
    save(next);
    applyTheme(next.theme);
    return next;
  }

  function init() {
    // 初始化主题（页面加载即应用）
    initTheme();

    var modal = document.getElementById('settings-modal');
    if (!modal) return;

    // 打开：侧边栏「设置」入口 + 顶栏齿轮按钮
    document.querySelectorAll('.sidebar-entry').forEach(function (btn) {
      if (btn.textContent.indexOf('设置') !== -1) {
        btn.addEventListener('click', open);
      }
    });
    var headerGear = document.querySelector('.chat-header-right .icon-btn');
    if (headerGear) headerGear.addEventListener('click', open);

    // 关闭：右上角 X、遮罩点击、Esc
    var closeBtn = modal.querySelector('.modal-header .icon-btn');
    if (closeBtn) closeBtn.addEventListener('click', close);
    modal.addEventListener('click', function (e) {
      if (e.target === modal) close();
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && isOpen()) close();
    });

    // token 显示/隐藏切换（敏感信息）
    var tokenEl = document.getElementById('setting-token');
    var toggle = document.getElementById('setting-token-toggle');
    if (tokenEl && toggle) {
      toggle.addEventListener('click', function () {
        var isHidden = tokenEl.type === 'password';
        tokenEl.type = isHidden ? 'text' : 'password';
        toggle.setAttribute('aria-pressed', String(isHidden));
        toggle.title = isHidden ? '隐藏 token' : '显示 token';
        toggle.textContent = isHidden ? '隐藏' : '显示';
      });
    }

    // 保存：持久化 + 主题生效 + 重建 WebSocket（应用新 token/地址）
    var saveBtn = modal.querySelector('.modal-footer .btn-primary');
    if (saveBtn) {
      saveBtn.addEventListener('click', function () {
        var next = saveFromForm();
        close();
        if (window.ChatApp && window.ChatApp.getSettings) {
          // 让 chat.js 读到新配置并重建连接
          var onSave = window.ChatApp.onSettingsSave;
          if (typeof onSave === 'function') onSave(next);
        }
      });
    }

    // 主题下拉即时切换（不保存也生效，下次打开/保存仍记忆）
    var themeSel = document.getElementById('setting-theme');
    if (themeSel) {
      themeSel.addEventListener('change', function () {
        applyTheme(themeSel.value);
      });
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

  window.Settings = {
    load: load,
    save: save,
    getTheme: getTheme,
    setTheme: setTheme,
    applyTheme: applyTheme,
    open: open,
    close: close,
    isOpen: isOpen
  };
})();
