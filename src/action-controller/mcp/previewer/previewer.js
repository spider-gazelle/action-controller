// MCP Apps card previewer: a lightweight MCP client (Streamable HTTP) and a mock
// MCP Apps host (postMessage JSON-RPC) that renders a tool's card.
(() => {
  "use strict";

  const config = JSON.parse(document.getElementById("previewer-config").textContent);
  const tool = config.tool;

  const MCP_PROTOCOL = "2025-11-25";
  const APPS_PROTOCOL = "2026-01-26";
  const UI_EXTENSION = "io.modelcontextprotocol/ui";
  const UI_MIME = "text/html;profile=mcp-app";
  const HEADERS_KEY = "ac-mcp-card-previewer:headers";
  const RESERVED = new Set(["viewport_size", "theme"]);
  const INIT_TIMEOUT = 8000;

  const VIEWPORTS = {
    desktop: { width: 1280, height: 800, platform: "web", touch: false, hover: true },
    tablet: { width: 768, height: 1024, platform: "mobile", touch: true, hover: false },
    mobile: { width: 375, height: 667, platform: "mobile", touch: true, hover: false },
  };

  const FONTS = {
    "--font-sans": "system-ui, -apple-system, 'Segoe UI', sans-serif",
    "--font-mono": "ui-monospace, SFMono-Regular, Menlo, monospace",
    "--border-radius-sm": "4px",
    "--border-radius-md": "8px",
    "--border-radius-lg": "12px",
    "--border-width-regular": "1px",
  };
  const THEMES = {
    light: {
      ...FONTS,
      "--color-background-primary": "#ffffff",
      "--color-background-secondary": "#f5f6f8",
      "--color-background-tertiary": "#eceef1",
      "--color-text-primary": "#1c1f24",
      "--color-text-secondary": "#5f6672",
      "--color-text-danger": "#c4314b",
      "--color-border-primary": "#d9dde3",
      "--color-border-secondary": "#e6e9ed",
    },
    dark: {
      ...FONTS,
      "--color-background-primary": "#1a1a1a",
      "--color-background-secondary": "#232528",
      "--color-background-tertiary": "#2c2f33",
      "--color-text-primary": "#e6e8eb",
      "--color-text-secondary": "#9aa1ab",
      "--color-text-danger": "#f08396",
      "--color-border-primary": "#343a42",
      "--color-border-secondary": "#2a2f35",
    },
  };

  const $ = (selector) => document.querySelector(selector);
  const query = new URLSearchParams(location.search);
  const stage = $("#stage");
  const device = $("#device");
  const deviceWrap = $("#device-wrap");
  const statusText = $("#status");

  const state = {
    viewport: VIEWPORTS[query.get("viewport_size")] ? query.get("viewport_size") : "desktop",
    theme: THEMES[query.get("theme")] ? query.get("theme") : (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"),
    displayMode: "inline",
    phase: "idle",
    result: null,
    run: 0,
  };
  let client = null;
  let bridge = null;

  // ---------------------------------------------------------------- logging

  const logEntries = [];
  const MAX_LOG = 500;

  function log(dir, summary, data, level = "info") {
    const entry = { dir, summary, data, level, at: new Date().toISOString() };
    logEntries.push(entry);
    if (logEntries.length > MAX_LOG) logEntries.shift();
    appendEntry($("#log"), entry);
    if (level === "error") console.error(`[${dir}] ${summary}`, data ?? "");
    else if (level === "warn") console.warn(`[${dir}] ${summary}`, data ?? "");
    return entry;
  }

  function appendEntry(list, entry) {
    const item = document.createElement("li");
    item.dataset.level = entry.level;
    const details = document.createElement("details");
    const summary = document.createElement("summary");
    const dir = document.createElement("span");
    dir.className = "dir";
    dir.textContent = entry.dir;
    const text = document.createElement("span");
    text.textContent = entry.summary;
    summary.append(dir, text);
    details.append(summary);
    if (entry.data !== undefined) {
      const pre = document.createElement("pre");
      pre.textContent = typeof entry.data === "string" ? entry.data : JSON.stringify(entry.data, null, 2);
      details.append(pre);
    }
    item.append(details);
    list.append(item);
    while (list.children.length > MAX_LOG) list.firstElementChild.remove();
    list.scrollTop = list.scrollHeight;
  }

  function toModel(method, data) {
    log("card → host", method, data);
    appendEntry($("#model"), { dir: method, summary: summarise(data), data, level: "info" });
  }

  function summarise(data) {
    const content = data && (data.content || []);
    const text = content.find && content.find((block) => block.type === "text");
    return text ? text.text.slice(0, 120) : "";
  }

  function setPhase(phase, message, error = false) {
    state.phase = phase;
    stage.dataset.state = phase;
    statusText.textContent = message || "";
    if (error) statusText.dataset.error = "";
    else delete statusText.dataset.error;
  }

  // ---------------------------------------------------------------- MCP client

  class RpcError extends Error {
    constructor(error) {
      super(error.message);
      this.code = error.code;
      this.data = error.data;
    }
  }

  class HttpError extends Error {
    constructor(status, message, challenge) {
      super(message);
      this.status = status;
      this.challenge = challenge;
    }
  }

  // Streamable HTTP client, every request carries the configured headers
  class McpClient {
    constructor(url, headers, onNotification) {
      this.url = url;
      this.headers = headers;
      this.onNotification = onNotification;
      this.nextId = 1;
      this.sessionId = null;
      this.protocolVersion = null;
    }

    async connect() {
      const result = await this.request("initialize", {
        protocolVersion: MCP_PROTOCOL,
        capabilities: { extensions: { [UI_EXTENSION]: { mimeTypes: [UI_MIME] } } },
        clientInfo: { name: "action-controller card previewer", version: "1.0.0" },
      });
      this.protocolVersion = result.protocolVersion;
      await this.notify("notifications/initialized");
      return result;
    }

    async request(method, params) {
      const id = this.nextId++;
      const message = { jsonrpc: "2.0", id, method };
      if (params !== undefined) message.params = params;
      log("mcp →", method, params);
      const replies = await this.post(message);
      const reply = replies.find((candidate) => candidate.id === id);
      if (!reply) throw new Error(`no response to ${method}`);
      if (reply.error) {
        log("← mcp", `${method} error ${reply.error.code}: ${reply.error.message}`, reply.error, "error");
        throw new RpcError(reply.error);
      }
      log("← mcp", method, reply.result);
      return reply.result;
    }

    async notify(method, params) {
      const message = { jsonrpc: "2.0", method };
      if (params !== undefined) message.params = params;
      log("mcp →", method, params);
      await this.post(message);
    }

    async post(message) {
      const headers = {
        ...this.headers,
        "Content-Type": "application/json",
        Accept: "application/json, text/event-stream",
      };
      if (this.sessionId) headers["Mcp-Session-Id"] = this.sessionId;
      if (this.protocolVersion) headers["MCP-Protocol-Version"] = this.protocolVersion;

      const response = await fetch(this.url, {
        method: "POST",
        headers,
        body: JSON.stringify(message),
        credentials: "same-origin",
      });
      const session = response.headers.get("Mcp-Session-Id");
      if (session) this.sessionId = session;
      if (response.status === 202) return [];

      const body = await response.text();
      const type = response.headers.get("Content-Type") || "";
      let messages = [];
      try {
        messages = type.includes("text/event-stream") ? parseEvents(body) : (body ? [JSON.parse(body)] : []);
      } catch (_error) {
        messages = [];
      }
      if (!response.ok) {
        const error = messages[0] && messages[0].error;
        const detail = error ? error.message : body.slice(0, 200);
        log("← mcp", `HTTP ${response.status} ${detail}`, body, "error");
        throw new HttpError(response.status, `HTTP ${response.status}: ${detail}`, response.headers.get("WWW-Authenticate"));
      }

      for (const reply of messages) {
        if (reply.method && reply.id === undefined) {
          log("← mcp", reply.method, reply.params);
          this.onNotification(reply);
        }
      }
      return messages;
    }

    // ends the session, best effort
    close() {
      if (!this.sessionId) return;
      const headers = { ...this.headers, "Mcp-Session-Id": this.sessionId };
      if (this.protocolVersion) headers["MCP-Protocol-Version"] = this.protocolVersion;
      fetch(this.url, { method: "DELETE", headers, credentials: "same-origin" }).catch(() => {});
    }
  }

  function parseEvents(body) {
    const messages = [];
    for (const block of body.split(/\r?\n\r?\n/)) {
      const data = block
        .split(/\r?\n/)
        .filter((line) => line.startsWith("data:"))
        .map((line) => line.slice(5).replace(/^ /, ""))
        .join("\n");
      if (data) messages.push(JSON.parse(data));
    }
    return messages;
  }

  // ---------------------------------------------------------------- MCP Apps host

  const PERMISSIONS = { camera: "camera", microphone: "microphone", geolocation: "geolocation", clipboardWrite: "clipboard-write" };

  // the policy real hosts apply: nothing external unless the card declares it
  function contentSecurityPolicy(csp = {}) {
    const list = (domains, fallback) => (domains && domains.length ? domains.join(" ") : fallback);
    const resources = list(csp.resourceDomains, "");
    return [
      "default-src 'none'",
      `script-src 'unsafe-inline' 'unsafe-eval' blob: data: ${resources}`,
      `style-src 'unsafe-inline' blob: data: ${resources}`,
      `img-src blob: data: ${resources}`,
      `font-src blob: data: ${resources}`,
      `media-src blob: data: ${resources}`,
      `connect-src ${list(csp.connectDomains, "'none'")}`,
      `frame-src ${list(csp.frameDomains, "'none'")}`,
      `base-uri ${list(csp.baseUriDomains, "'none'")}`,
      "object-src 'none'",
    ].join("; ").replace(/ +;/g, ";");
  }

  function injectPolicy(html, csp) {
    const meta = `<meta http-equiv="Content-Security-Policy" content="${contentSecurityPolicy(csp).replace(/"/g, "&quot;")}">`;
    if (/<head[^>]*>/i.test(html)) return html.replace(/<head[^>]*>/i, (head) => head + meta);
    if (/<html[^>]*>/i.test(html)) return html.replace(/<html[^>]*>/i, (open) => `${open}<head>${meta}</head>`);
    return meta + html;
  }

  class HostBridge {
    constructor(iframe, listedTool, uiMeta, callId) {
      this.iframe = iframe;
      this.tool = listedTool;
      this.uiMeta = uiMeta || {};
      this.callId = callId;
      this.nextId = 1;
      this.pending = new Map();
      this.initialized = false;
      this.input = null;
      this.result = null;
      this.cancelled = null;
      this.delivered = false;
      this.listener = (event) => {
        if (event.source === this.iframe.contentWindow) this.receive(event.data);
      };
      window.addEventListener("message", this.listener);
      this.initTimer = setTimeout(() => {
        if (!this.initialized) log("host", "the card hasn't sent ui/initialize, is it an MCP App?", undefined, "warn");
      }, INIT_TIMEOUT);
    }

    send(message) {
      const direction = message.method ? message.method : `reply #${message.id}`;
      log("host → card", direction, message.params ?? message.result ?? message.error);
      this.iframe.contentWindow && this.iframe.contentWindow.postMessage(message, "*");
    }

    notify(method, params) {
      this.send({ jsonrpc: "2.0", method, params });
    }

    request(method, params, timeout = 1000) {
      const id = `host-${this.nextId++}`;
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          this.pending.delete(id);
          reject(new Error(`${method} timed out`));
        }, timeout);
        this.pending.set(id, (reply) => {
          clearTimeout(timer);
          reply.error ? reject(new RpcError(reply.error)) : resolve(reply.result);
        });
        this.send({ jsonrpc: "2.0", id, method, params });
      });
    }

    reply(id, result) {
      this.send({ jsonrpc: "2.0", id, result });
    }

    fail(id, code, message) {
      log("host", message, undefined, "warn");
      this.send({ jsonrpc: "2.0", id, error: { code, message } });
    }

    async receive(message) {
      if (!message || message.jsonrpc !== "2.0") return;

      // a reply to a host request
      if (message.method === undefined) {
        log("card → host", `reply #${message.id}`, message.result ?? message.error);
        const resolve = this.pending.get(message.id);
        if (resolve) {
          this.pending.delete(message.id);
          resolve(message);
        }
        return;
      }

      const level = message.method === "notifications/message" ? logLevel(message.params) : "info";
      if (message.method !== "ui/message" && message.method !== "ui/update-model-context") {
        log("card → host", message.method, message.params, level);
      }
      if (message.id === undefined) return this.notification(message.method, message.params || {});

      try {
        const result = await this.handle(message.method, message.params || {}, message.id);
        if (result !== undefined) this.reply(message.id, result);
      } catch (error) {
        if (error instanceof RpcError) this.send({ jsonrpc: "2.0", id: message.id, error: { code: error.code, message: error.message, data: error.data } });
        else this.fail(message.id, -32603, error.message);
      }
    }

    async handle(method, params, id) {
      switch (method) {
        case "ui/initialize":
          return {
            protocolVersion: params.protocolVersion || APPS_PROTOCOL,
            hostInfo: { name: "action-controller card previewer", version: "1.0.0" },
            hostCapabilities: {
              openLinks: {},
              downloadFile: {},
              serverTools: { listChanged: true },
              serverResources: {},
              logging: {},
              message: { text: {}, image: {}, resource: {} },
              updateModelContext: { text: {}, image: {}, resource: {}, structuredContent: {} },
              sandbox: { csp: this.uiMeta.csp || {}, permissions: this.uiMeta.permissions || {} },
            },
            hostContext: this.context(),
          };
        case "ping":
          return {};
        case "tools/call":
          return this.callTool(params, id);
        case "resources/read":
        case "resources/list":
        case "resources/templates/list":
          return client.request(method, params);
        case "ui/open-link":
          if (!/^(https?:|mailto:)/i.test(params.url || "")) return { isError: true };
          window.open(params.url, "_blank", "noopener");
          return {};
        case "ui/download-file":
          return download(params.contents || []);
        case "ui/message":
        case "ui/update-model-context":
          toModel(method, params);
          return {};
        case "ui/request-display-mode":
          if (params.mode === "inline" || params.mode === "fullscreen") setDisplayMode(params.mode);
          return { mode: state.displayMode };
        default:
          this.fail(id, -32601, `${method} isn't supported by the previewer`);
          return undefined;
      }
    }

    // the same rules as a real host: only listed tools that cards can see
    async callTool(params, id) {
      const target = client.tools.get(params.name);
      if (!target) {
        this.fail(id, -32602, `Tool ${params.name} isn't in the tool list, hosts only let cards call listed tools`);
        return undefined;
      }
      const visibility = target._meta && target._meta.ui && target._meta.ui.visibility;
      if (visibility && !visibility.includes("app")) {
        this.fail(id, -32602, `Tool ${params.name} is only visible to the model (visibility: ${visibility.join(", ")})`);
        return undefined;
      }
      return client.request("tools/call", params);
    }

    notification(method, params) {
      switch (method) {
        case "ui/notifications/initialized":
          this.initialized = true;
          clearTimeout(this.initTimer);
          if (this.input) this.notify("ui/notifications/tool-input", { arguments: this.input });
          this.deliver();
          break;
        case "ui/notifications/size-changed":
          if (state.displayMode === "inline" && params.height) {
            this.iframe.style.height = `${Math.max(40, Math.ceil(params.height))}px`;
            fit();
          }
          break;
        case "ui/notifications/request-teardown":
          teardown().then(() => setPhase("idle", "The card asked to be closed"));
          break;
      }
    }

    toolInput(args) {
      this.input = args;
      if (this.initialized) this.notify("ui/notifications/tool-input", { arguments: args });
    }

    toolResult(result) {
      this.result = result;
      this.deliver();
    }

    toolCancelled(reason) {
      this.cancelled = reason;
      this.deliver();
    }

    deliver() {
      if (!this.initialized || this.delivered) return;
      if (this.result) {
        this.delivered = true;
        this.notify("ui/notifications/tool-result", this.result);
        if (this.result.isError) stage.dataset.toolError = "true";
        setPhase("ready", this.result.isError ? "Rendered, the tool returned an error" : "Rendered");
      } else if (this.cancelled) {
        this.delivered = true;
        this.notify("ui/notifications/tool-cancelled", { reason: this.cancelled });
      }
    }

    context() {
      const viewport = VIEWPORTS[state.viewport];
      return {
        toolInfo: { id: this.callId, tool: this.tool },
        theme: state.theme,
        styles: { variables: THEMES[state.theme] },
        displayMode: state.displayMode,
        availableDisplayModes: ["inline", "fullscreen"],
        containerDimensions: state.displayMode === "fullscreen" ? { width: viewport.width, height: viewport.height } : { width: viewport.width, maxHeight: viewport.height * 2 },
        locale: navigator.language,
        timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone,
        userAgent: "action-controller card previewer",
        platform: viewport.platform,
        deviceCapabilities: { touch: viewport.touch, hover: viewport.hover },
      };
    }

    contextChanged() {
      if (this.initialized) this.notify("ui/notifications/host-context-changed", this.context());
    }

    async teardown() {
      if (this.initialized) {
        try {
          await this.request("ui/resource-teardown", {}, 1000);
        } catch (error) {
          log("host", `teardown: ${error.message}`, undefined, "warn");
        }
      }
      clearTimeout(this.initTimer);
      window.removeEventListener("message", this.listener);
    }
  }

  function logLevel(params) {
    const level = (params && params.level) || "info";
    if (["error", "critical", "alert", "emergency"].includes(level)) return "error";
    return level === "warning" ? "warn" : "info";
  }

  function download(contents) {
    for (const item of contents) {
      if (item.type === "resource_link") {
        window.open(item.uri, "_blank", "noopener");
        continue;
      }
      const resource = item.resource || {};
      const data = resource.blob ? Uint8Array.from(atob(resource.blob), (c) => c.charCodeAt(0)) : resource.text || "";
      const url = URL.createObjectURL(new Blob([data], { type: resource.mimeType || "application/octet-stream" }));
      const link = document.createElement("a");
      link.href = url;
      link.download = (resource.uri || "download").split("/").pop() || "download";
      link.click();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    }
    return {};
  }

  // ---------------------------------------------------------------- arguments form

  const schema = tool.inputSchema || {};
  const properties = schema.properties || {};
  const required = new Set(schema.required || []);

  function resolve(node) {
    let current = node || {};
    for (let depth = 0; current.$ref && depth < 10; depth++) {
      const path = current.$ref.replace(/^#\//, "").split("/");
      current = path.reduce((value, key) => (value ? value[key] : undefined), schema) || {};
    }
    return current;
  }

  // how a property is entered: string, integer, number, boolean, enum or json
  function kindOf(node) {
    const property = resolve(node);
    if (property.enum) return { kind: "enum", values: property.enum };
    let type = property.type;
    const options = property.anyOf || property.oneOf;
    if (!type && options) {
      const types = options.map(resolve).filter((option) => option.type !== "null");
      return types.length === 1 ? kindOf(types[0]) : { kind: "json" };
    }
    if (Array.isArray(type)) {
      const types = type.filter((name) => name !== "null");
      type = types.length === 1 ? types[0] : null;
    }
    return { kind: ["string", "integer", "number", "boolean"].includes(type) ? type : "json" };
  }

  function buildForm() {
    const fields = $("#fields");
    const names = Object.keys(properties);
    if (names.length === 0) {
      fields.innerHTML = '<p class="muted">This tool takes no arguments.</p>';
      return;
    }
    for (const name of names) {
      const property = resolve(properties[name]);
      const { kind, values } = kindOf(properties[name]);
      const field = document.createElement("div");
      field.className = "field";
      field.dataset.name = name;
      const id = `arg-${name}`;
      const label = document.createElement("label");
      label.htmlFor = id;
      label.textContent = name;
      if (required.has(name)) {
        const star = document.createElement("span");
        star.className = "required";
        star.textContent = " *";
        label.append(star);
      }
      let input;
      if (kind === "enum" || kind === "boolean") {
        input = document.createElement("select");
        const options = kind === "boolean" ? [true, false] : values;
        input.append(new Option(required.has(name) ? "choose…" : "(not set)", ""));
        for (const value of options) input.append(new Option(String(value), String(value)));
      } else if (kind === "json") {
        input = document.createElement("textarea");
        input.placeholder = "JSON";
      } else {
        input = document.createElement("input");
        input.type = kind === "string" ? "text" : "number";
        if (kind === "integer") input.step = "1";
        if (kind === "number") input.step = "any";
      }
      input.id = id;
      input.name = name;
      input.dataset.kind = kind;
      if (property.default !== undefined && input.tagName !== "SELECT") input.placeholder = `default: ${JSON.stringify(property.default)}`;
      field.append(label, input);
      const help = [property.description || properties[name].description, kind === "json" ? "JSON value" : null].filter(Boolean).join(" · ");
      if (help) {
        const small = document.createElement("small");
        small.textContent = help;
        field.append(small);
      }
      fields.append(field);
    }
  }

  // the raw (string) values entered, empty fields are left out
  function rawValues() {
    const raw = {};
    for (const input of document.querySelectorAll("#fields [name]")) {
      if (input.value !== "") raw[input.name] = input.value;
    }
    return raw;
  }

  function coerce(name, raw) {
    const { kind, values } = kindOf(properties[name]);
    switch (kind) {
      case "string":
        return raw;
      case "integer":
      case "number": {
        const number = Number(raw);
        if (raw.trim() === "" || Number.isNaN(number) || (kind === "integer" && !Number.isInteger(number))) throw new Error(`expected ${kind === "integer" ? "an integer" : "a number"}`);
        return number;
      }
      case "boolean":
        if (raw === "true" || raw === "1") return true;
        if (raw === "false" || raw === "0") return false;
        throw new Error("expected true or false");
      case "enum": {
        const match = values.find((value) => String(value) === raw);
        if (match === undefined) throw new Error(`expected one of ${values.join(", ")}`);
        return match;
      }
      default:
        try {
          return JSON.parse(raw);
        } catch (_error) {
          throw new Error("expected JSON");
        }
    }
  }

  // the tool arguments, `null` if a value is invalid or a required one is missing
  function collectArguments(showErrors) {
    const raw = rawValues();
    const args = {};
    let valid = true;
    for (const field of document.querySelectorAll("#fields .field")) {
      const name = field.dataset.name;
      field.classList.remove("invalid");
      field.querySelector(".error")?.remove();
      let problem = null;
      if (raw[name] === undefined) {
        if (required.has(name)) problem = "required";
      } else {
        try {
          args[name] = coerce(name, raw[name]);
        } catch (error) {
          problem = error.message;
        }
      }
      if (problem) {
        valid = false;
        if (showErrors) {
          field.classList.add("invalid");
          const message = document.createElement("small");
          message.className = "error";
          message.style.color = "var(--danger)";
          message.textContent = problem;
          field.append(message);
        }
      }
    }
    return valid ? args : null;
  }

  // ---------------------------------------------------------------- request headers

  function loadHeaders() {
    let saved = [];
    try {
      saved = JSON.parse(sessionStorage.getItem(HEADERS_KEY) || "[]");
    } catch (_error) {
      saved = [];
    }
    for (const [key, value] of query) {
      if (!key.startsWith("header.")) continue;
      const name = key.slice(7);
      saved = saved.filter(([existing]) => existing.toLowerCase() !== name.toLowerCase());
      saved.push([name, value]);
    }
    for (const [name, value] of saved) addHeaderRow(name, value);
    saveHeaders();
  }

  function addHeaderRow(name = "", value = "") {
    const row = document.createElement("div");
    row.className = "header-row";
    const nameInput = document.createElement("input");
    nameInput.placeholder = "Authorization";
    nameInput.value = name;
    nameInput.className = "header-name";
    nameInput.spellcheck = false;
    const valueInput = document.createElement("input");
    valueInput.type = "password";
    valueInput.placeholder = "Bearer …";
    valueInput.value = value;
    valueInput.className = "header-value";
    valueInput.autocomplete = "off";
    const remove = document.createElement("button");
    remove.type = "button";
    remove.textContent = "✕";
    remove.title = "Remove header";
    remove.addEventListener("click", () => {
      row.remove();
      saveHeaders();
    });
    nameInput.addEventListener("change", saveHeaders);
    valueInput.addEventListener("change", saveHeaders);
    row.append(nameInput, valueInput, remove);
    $("#headers").append(row);
  }

  function headerPairs() {
    return [...document.querySelectorAll(".header-row")]
      .map((row) => [row.querySelector(".header-name").value.trim(), row.querySelector(".header-value").value])
      .filter(([name]) => name);
  }

  function saveHeaders() {
    try {
      sessionStorage.setItem(HEADERS_KEY, JSON.stringify(headerPairs()));
    } catch (_error) {
      // storage unavailable, headers still apply to this page
    }
  }

  function requestHeaders() {
    const headers = {};
    for (const [name, value] of headerPairs()) {
      if (name.toLowerCase() === "cookie") {
        log("host", "browsers don't let pages set the Cookie header, this site's cookies are sent automatically", undefined, "warn");
        continue;
      }
      headers[name] = value;
    }
    return headers;
  }

  // ---------------------------------------------------------------- stage

  function setDisplayMode(mode) {
    state.displayMode = mode;
    stage.dataset.displayMode = mode;
    $("#exit-fullscreen").hidden = mode !== "fullscreen";
    const iframe = device.querySelector("iframe");
    if (iframe && mode === "fullscreen") iframe.style.height = `${VIEWPORTS[state.viewport].height}px`;
    fit();
    if (bridge) bridge.contextChanged();
  }

  // scales the device to fit the stage, the card still lays out at the viewport width
  function fit() {
    const viewport = VIEWPORTS[state.viewport];
    device.style.width = `${viewport.width}px`;
    const available = stage.clientWidth - 32;
    const scale = Math.min(1, available / viewport.width);
    device.style.transform = scale < 1 ? `scale(${scale})` : "";
    deviceWrap.style.width = `${viewport.width * scale}px`;
    deviceWrap.style.height = `${device.offsetHeight * scale}px`;
  }

  function applyView() {
    stage.dataset.viewport = state.viewport;
    stage.dataset.theme = state.theme;
    for (const button of document.querySelectorAll("[data-viewport]")) button.setAttribute("aria-pressed", String(button.dataset.viewport === state.viewport));
    for (const button of document.querySelectorAll("[data-theme-choice]")) button.setAttribute("aria-pressed", String(button.dataset.themeChoice === state.theme));
    fit();
    if (bridge) bridge.contextChanged();
  }

  async function teardown() {
    if (bridge) {
      const previous = bridge;
      bridge = null;
      await previous.teardown();
    }
    if (client) {
      client.close();
      client = null;
    }
    device.replaceChildren();
    delete stage.dataset.toolError;
    state.displayMode = "inline";
    stage.dataset.displayMode = "inline";
    $("#exit-fullscreen").hidden = true;
    fit();
  }

  // keeps the URL in sync so the current preview can be shared or scripted
  function updateLocation() {
    const params = new URLSearchParams();
    for (const [name, value] of Object.entries(rawValues())) params.set(name, value);
    params.set("viewport_size", state.viewport);
    params.set("theme", state.theme);
    for (const [key, value] of query) if (key.startsWith("header.")) params.set(key, value);
    history.replaceState(null, "", `${location.pathname}?${params}`);
  }

  // ---------------------------------------------------------------- run

  async function run(args) {
    const runId = ++state.run;
    await teardown();
    if (runId !== state.run) return;
    $("#result").textContent = "";
    state.result = null;
    setPhase("loading", "Connecting…");

    const mcp = new McpClient(config.mcp, requestHeaders(), (notification) => {
      if (notification.method === "notifications/tools/list_changed") refreshTools(mcp);
    });
    client = mcp;
    mcp.tools = new Map();
    try {
      await mcp.connect();
      if (!tool.root) {
        await mcp.request("tools/call", { name: "open_toolbox", arguments: { name: tool.toolbox } });
      }
      await refreshTools(mcp);
      const listed = mcp.tools.get(tool.name);
      if (!listed) throw new Error(`${tool.name} isn't in the tool list`);
      const meta = listed._meta || {};
      const uri = (meta.ui && meta.ui.resourceUri) || meta["ui/resourceUri"];
      if (!uri) throw new Error("the tool doesn't advertise a card, is MCPServer.ui_base set?");

      const callId = mcp.nextId;
      const call = mcp.request("tools/call", { name: tool.name, arguments: args });
      call.catch(() => {}); // handled below, once the card is mounted
      const read = await mcp.request("resources/read", { uri });
      if (runId !== state.run) return;
      const content = (read.contents || [])[0] || {};
      const html = content.text !== undefined ? content.text : new TextDecoder().decode(Uint8Array.from(atob(content.blob || ""), (c) => c.charCodeAt(0)));
      const uiMeta = (content._meta && content._meta.ui) || {};

      setPhase("rendering", "Waiting for the card…");
      const iframe = document.createElement("iframe");
      iframe.id = "card";
      iframe.title = tool.title || tool.name;
      iframe.setAttribute("sandbox", "allow-scripts allow-forms allow-popups allow-popups-to-escape-sandbox allow-downloads");
      const allow = Object.keys(uiMeta.permissions || {}).map((name) => PERMISSIONS[name]).filter(Boolean);
      if (allow.length) iframe.allow = allow.join("; ");
      bridge = new HostBridge(iframe, listed, uiMeta, callId);
      bridge.toolInput(args);
      iframe.srcdoc = injectPolicy(html, uiMeta.csp);
      device.append(iframe);
      fit();

      const currentBridge = bridge;
      try {
        const result = await call;
        state.result = result;
        $("#result").textContent = JSON.stringify(result, null, 2);
        currentBridge.toolResult(result);
      } catch (error) {
        $("#result").textContent = error.message;
        currentBridge.toolCancelled(error.message);
        if (runId === state.run) setPhase("error", `Tool call failed: ${error.message}`, true);
      }
    } catch (error) {
      if (runId !== state.run) return;
      let message = error.message;
      if (error instanceof HttpError && error.status === 401) {
        message = "401 Unauthorized: add an Authorization header (or sign in) and render again";
      }
      log("host", message, undefined, "error");
      setPhase("error", message, true);
    }
  }

  async function refreshTools(mcp) {
    const listed = await mcp.request("tools/list", {});
    mcp.tools = new Map((listed.tools || []).map((entry) => [entry.name, entry]));
  }

  // ---------------------------------------------------------------- wiring

  function selectTab(name) {
    for (const button of document.querySelectorAll("[data-tab]")) button.setAttribute("aria-selected", String(button.dataset.tab === name));
    for (const panel of document.querySelectorAll("[data-panel]")) panel.hidden = panel.dataset.panel !== name;
  }

  function start() {
    buildForm();
    loadHeaders();

    for (const [name, value] of query) {
      if (RESERVED.has(name) || name.startsWith("header.")) continue;
      const input = document.querySelector(`#fields [name="${CSS.escape(name)}"]`);
      if (input) input.value = value;
      else log("host", `unknown argument ${name} in the URL`, undefined, "warn");
    }

    $("#args-form").addEventListener("submit", (event) => {
      event.preventDefault();
      const args = collectArguments(true);
      if (!args) return;
      updateLocation();
      run(args);
    });
    $("#add-header").addEventListener("click", () => addHeaderRow());
    $("#exit-fullscreen").addEventListener("click", () => setDisplayMode("inline"));
    for (const button of document.querySelectorAll("[data-viewport]")) {
      button.addEventListener("click", () => {
        state.viewport = button.dataset.viewport;
        applyView();
        updateLocation();
      });
    }
    for (const button of document.querySelectorAll("[data-theme-choice]")) {
      button.addEventListener("click", () => {
        state.theme = button.dataset.themeChoice;
        applyView();
        updateLocation();
      });
    }
    for (const button of document.querySelectorAll("[data-tab]")) button.addEventListener("click", () => selectTab(button.dataset.tab));
    new ResizeObserver(fit).observe(stage);
    new ResizeObserver(fit).observe(device);

    applyView();
    if (!tool.found) log("host", `${tool.ui} wasn't found in MCPServer.ui_base`, undefined, "warn");

    // renders straight away when every required argument is known
    const args = collectArguments(false);
    if (args) run(args);
    else setPhase("idle", "Fill in the required arguments to render the card");
  }

  // for automated tests: `await page.waitForSelector('#stage[data-state="ready"]')`
  window.cardPreviewer = {
    get state() { return state.phase; },
    get result() { return state.result; },
    get log() { return logEntries.slice(); },
    get viewport() { return state.viewport; },
    get theme() { return state.theme; },
    run: () => {
      const args = collectArguments(true);
      return args ? run(args) : Promise.resolve();
    },
  };

  start();
})();
