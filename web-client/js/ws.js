/**
 * ws.js — AI Agent WebSocket 封装（T2，T4 改为仅连接 Reasonix 后端）
 *
 * 职责：
 *   - 建立 WebSocket 连接：Reasonix 后端 ws://<host>:<port>/agent/ws
 *   - 用子协议 token.<forward_key> 认证（浏览器无法设置 Header，对齐 T3 agentproxy）
 *   - 发送 message.send / 接收 message.create / message.update / typing.* / error / session.create
 *   - 断线自动重连（3s 退避）
 *
 * 对外暴露 PicoWS 类（类名保留，兼容既有调用方）：
 *   const ws = new PicoWS({ url, token, onMessage, onStatus });
 *   ws.connect();
 *   ws.send(sessionId, content, media);
 *   ws.reconnect();      // 手动重建连接（token/地址变更后）
 *   ws.close();          // 主动关闭（不再自动重连）
 *   ws.ready;            // 当前是否已建立连接
 */
(function () {
  'use strict';

  var RECONNECT_DELAY = 3000;

  // Reasonix agentproxy WS 端点（对齐 agentproxy-design.md §6.3）。
  var REASONIX_DEFAULT_PORT = 18990;
  var REASONIX_DEFAULT_WS_PATH = '/agent/ws';

  /**
   * 部署层注入的开箱即用配置（T6 / T4 更新）。
   * 由 deploy 脚本生成 /opt/sophon/web-chat/config.js：
   *   window.PICO_WEB_CHAT_CONFIG = {
   *     wsUrl: "ws://host:18990/agent/ws",      // 可省略，回退当前主机默认端口
   *     token: "<forward_key>"                  // 可省略，回退手动填写
   *   }
   * 前端读不到时返回 null，回退为手动配置（向后兼容）。
   * 注意：config.js 仅存在于部署产物，不入仓库，避免把 token 明文写进源码。
   */
  function injectedConfig() {
    try {
      var c = window.PICO_WEB_CHAT_CONFIG;
      if (c && typeof c === 'object') {
        var cfg = {};
        if (c.wsUrl) cfg.wsUrl = String(c.wsUrl);
        if (c.token) cfg.token = String(c.token);
        // 兼容旧格式（picoclaw 时代）：reasonix 段携带 host/port/token
        if (c.reasonix && typeof c.reasonix === 'object') {
          if (!cfg.wsUrl && c.reasonix.host) {
            var port = c.reasonix.port ? String(c.reasonix.port) : String(REASONIX_DEFAULT_PORT);
            cfg.wsUrl = 'ws://' + String(c.reasonix.host) + ':' + port + REASONIX_DEFAULT_WS_PATH;
          }
          if (!cfg.token && c.reasonix.token) cfg.token = String(c.reasonix.token);
        }
        if (cfg.wsUrl || cfg.token) return cfg;
      }
    } catch (e) { /* 忽略 */ }
    return null;
  }

  class PicoWS {
    /**
     * @param {object} opts
     * @param {string} opts.url      WebSocket 地址，如 ws://host:18990/agent/ws
     * @param {string} opts.token    子协议 token（Reasonix forward key）
     * @param {function} opts.onMessage  收到消息回调（已解析为对象）
     * @param {function} [opts.onStatus] 状态回调：{ state: 'connecting'|'open'|'reconnecting'|'closed', info? }
     */
    constructor(opts) {
      this.url = opts.url;
      this.token = opts.token;
      this.onMessage = opts.onMessage;
      this.onStatus = opts.onStatus || function () {};
      this.ws = null;
      this.ready = false;
      this._closed = false;       // 主动关闭标志，主动关闭后不再重连
      this._reconnectTimer = null;
      this._reconnectCount = 0;
      this._queue = [];           // 连接未就绪时排队的发送帧
    }

    /** 建立连接（可重复调用；已连接时忽略） */
    connect() {
      if (this.ws && (this.ws.readyState === WebSocket.OPEN || this.ws.readyState === WebSocket.CONNECTING)) {
        return;
      }
      this._closed = false;
      this._emitStatus('connecting');
      try {
        this.ws = new WebSocket(this.url, ['token.' + this.token]);
      } catch (err) {
        // 地址不合法等同步错误：延迟后重试
        this._scheduleReconnect();
        return;
      }

      this.ws.onopen = () => {
        this.ready = true;
        this._reconnectCount = 0;
        this._flushQueue();
        this._emitStatus('open');
      };

      this.ws.onmessage = (e) => {
        var data = e.data;
        var msg;
        try {
          msg = typeof data === 'string' ? JSON.parse(data) : data;
        } catch (err) {
          // 非 JSON 帧：忽略，避免中断协议流
          return;
        }
        if (msg && this.onMessage) this.onMessage(msg);
      };

      this.ws.onclose = () => {
        var wasReady = this.ready;
        this.ready = false;
        if (wasReady) this._emitStatus('closed');
        this._scheduleReconnect();
      };

      this.ws.onerror = () => {
        // onclose 随后触发并处理重连，这里不重复调度
      };
    }

    /**
     * 发送一条用户消息。
     * 注意：sessionId 为 null/空时发送的帧不带 session_id 字段，
     * 服务端会自动创建会话并在回包中返回生成的 session_id（实测行为）。
     */
    send(sessionId, content, media) {
      if (!this.ready || !this.ws || this.ws.readyState !== WebSocket.OPEN) {
        throw new Error('WebSocket 未连接，无法发送消息');
      }
      var frame = this._buildFrame(sessionId, content, media);
      this.ws.send(JSON.stringify(frame));
    }

    /**
     * 发送一条用户消息；连接未就绪时排队，连接建立后自动发送。
     * 用于「新建会话需要重开连接」的场景：先 reconnect() 再 sendQueued()。
     */
    sendQueued(sessionId, content, media) {
      var frame = this._buildFrame(sessionId, content, media);
      if (this.ready && this.ws && this.ws.readyState === WebSocket.OPEN) {
        this.ws.send(JSON.stringify(frame));
        return true;
      }
      this._queue.push(frame);
      return false;
    }

    _buildFrame(sessionId, content, media) {
      var payload = { content: content };
      if (media && media.length) payload.media = media;
      var frame = { type: 'message.send', payload: payload };
      if (sessionId) frame.session_id = sessionId;
      return frame;
    }

    _flushQueue() {
      if (!this.ready || !this.ws) return;
      while (this._queue.length) {
        var frame = this._queue.shift();
        try { this.ws.send(JSON.stringify(frame)); } catch (e) { /* 忽略 */ }
      }
    }

    /** 手动重建连接（例如保存设置后 token/地址变化） */
    reconnect() {
      this.close();
      this.connect();
    }

    /** 主动关闭，不再自动重连 */
    close() {
      this._closed = true;
      this._queue = [];
      if (this._reconnectTimer) {
        clearTimeout(this._reconnectTimer);
        this._reconnectTimer = null;
      }
      if (this.ws) {
        try { this.ws.close(); } catch (e) { /* 忽略 */ }
        this.ws = null;
      }
      this.ready = false;
    }

    _scheduleReconnect() {
      if (this._closed) return;
      if (this._reconnectTimer) return;
      this._reconnectCount += 1;
      this._emitStatus('reconnecting', { delay: RECONNECT_DELAY, count: this._reconnectCount });
      this._reconnectTimer = setTimeout(() => {
        this._reconnectTimer = null;
        this.connect();
      }, RECONNECT_DELAY);
    }

    _emitStatus(state, info) {
      if (this.onStatus) this.onStatus({ state: state, info: info });
    }
  }

  // 兼容浏览器全局 + CommonJS（便于 node 测试）
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = PicoWS;
  } else {
    window.PicoWS = PicoWS;
  }

  window.PicoConfig = { injected: injectedConfig };
  window.PicoConstants = { REASONIX_DEFAULT_PORT: REASONIX_DEFAULT_PORT, REASONIX_DEFAULT_WS_PATH: REASONIX_DEFAULT_WS_PATH };
})();
