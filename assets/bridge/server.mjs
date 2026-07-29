import http from "node:http";
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import net from "node:net";
import crypto from "node:crypto";
import { spawn, execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";

const execFileAsync = promisify(execFile);
const appDir = path.dirname(fileURLToPath(import.meta.url));
const runtimeDir = path.join(appDir, "runtime");
const configPath = path.join(runtimeDir, "config.json");
const firstLoginPath = path.join(runtimeDir, "first-login.txt");
const pidPath = path.join(runtimeDir, "bridge.pid");
const logPath = path.join(runtimeDir, "bridge.log");
const handoffPath = path.join(appDir, "HANDOFF.md");
const handoffBackupPath = path.join(runtimeDir, "HANDOFF.last-known-good.md");
const handoffEventsPath = path.join(runtimeDir, "handoff-events.jsonl");
const userProfile = process.env.USERPROFILE || "";
const localAppData =
  process.env.LOCALAPPDATA || path.join(userProfile, "AppData", "Local");

const defaults = {
  host: "127.0.0.1",
  port: 17823,
  ccSwitchExe: "",
  webViewDataDir: path.join(
    localAppData,
    "com.ccswitch.desktop",
    "EBWebView",
  ),
  codexConfigPath: path.join(userProfile, ".codex", "config.toml"),
  codexAumid: "",
};

await fsp.mkdir(runtimeDir, { recursive: true });

function makePassword() {
  return crypto.randomBytes(18).toString("base64url");
}

function hashPassword(password, salt) {
  return crypto.scryptSync(password, salt, 32).toString("hex");
}

async function loadConfig() {
  let persisted = {};
  try {
    const raw = await fsp.readFile(configPath, "utf8");
    persisted = JSON.parse(raw.replace(/^\uFEFF/, ""));
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }

  const config = { ...defaults, ...persisted };
  let newPassword = null;
  if (!config.passwordSalt || !config.passwordHash) {
    const password = makePassword();
    config.passwordSalt = crypto.randomBytes(16).toString("hex");
    config.passwordHash = hashPassword(password, config.passwordSalt);
    newPassword = password;
  }
  await fsp.writeFile(configPath, `${JSON.stringify(config, null, 2)}\n`, {
    mode: 0o600,
  });
  if (newPassword) {
    await fsp.writeFile(
      firstLoginPath,
      `Codex Switchboard first-login password:\r\n${newPassword}\r\n`,
      { mode: 0o600 },
    );
  }
  return config;
}

const config = await loadConfig();
await fsp.writeFile(pidPath, `${process.pid}\n`);

const sessions = new Map();
const loginAttempts = new Map();
const recentLogs = [];
let activeOperation = null;

function redact(value) {
  return String(value ?? "")
    .replace(/Bearer\s+[A-Za-z0-9._~+/=-]+/gi, "Bearer [REDACTED]")
    .replace(/\b(sk|ds|key)-[A-Za-z0-9_-]{8,}\b/gi, "[REDACTED]")
    .replace(/experimental_bearer_token\s*=\s*"[^"]*"/gi, 'experimental_bearer_token = "[REDACTED]"')
    .slice(0, 800);
}

async function record(level, message) {
  const item = {
    at: new Date().toISOString(),
    level,
    message: redact(message),
  };
  recentLogs.unshift(item);
  recentLogs.splice(80);
  await fsp.appendFile(logPath, `${JSON.stringify(item)}\n`).catch(() => {});
}

async function recordHandoffEvent(phase, target, message) {
  if (phase === "prepared") {
    await fsp.copyFile(handoffPath, handoffBackupPath).catch(() => {});
  }
  const event = {
    at: new Date().toISOString(),
    source: "remote-bridge",
    providerId: target?.id || null,
    providerName: target?.name || null,
    phase,
    message: redact(message),
  };
  await fsp
    .appendFile(handoffEventsPath, `${JSON.stringify(event)}\n`, "utf8")
    .catch(() => {});
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function parseCookies(req) {
  return Object.fromEntries(
    String(req.headers.cookie || "")
      .split(";")
      .map((part) => part.trim())
      .filter(Boolean)
      .map((part) => {
        const index = part.indexOf("=");
        return index < 0
          ? [part, ""]
          : [part.slice(0, index), decodeURIComponent(part.slice(index + 1))];
      }),
  );
}

function getSession(req) {
  const id = parseCookies(req).ccrb_session;
  const session = id ? sessions.get(id) : null;
  if (!session || session.expiresAt < Date.now()) {
    if (id) sessions.delete(id);
    return null;
  }
  session.expiresAt = Date.now() + 30 * 24 * 60 * 60 * 1000;
  return session;
}

function send(res, status, body, headers = {}) {
  res.writeHead(status, {
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
    "Content-Security-Policy":
      "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'",
    ...headers,
  });
  res.end(body);
}

function sendJson(res, status, value) {
  send(res, status, JSON.stringify(value), {
    "Content-Type": "application/json; charset=utf-8",
  });
}

async function readBody(req, limit = 8192) {
  let size = 0;
  const chunks = [];
  for await (const chunk of req) {
    size += chunk.length;
    if (size > limit) throw new Error("请求内容过大");
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString("utf8");
}

function passwordMatches(candidate) {
  const expected = Buffer.from(config.passwordHash, "hex");
  const actual = Buffer.from(
    hashPassword(String(candidate || ""), config.passwordSalt),
    "hex",
  );
  return expected.length === actual.length && crypto.timingSafeEqual(expected, actual);
}

function loginAllowed(ip) {
  const now = Date.now();
  const attempts = (loginAttempts.get(ip) || []).filter((time) => now - time < 60_000);
  if (attempts.length >= 6) return false;
  attempts.push(now);
  loginAttempts.set(ip, attempts);
  return true;
}

async function processExists(imageName) {
  const { stdout } = await execFileAsync(
    "C:\\Windows\\System32\\tasklist.exe",
    ["/FI", `IMAGENAME eq ${imageName}`, "/FO", "CSV", "/NH"],
    { windowsHide: true },
  ).catch(() => ({ stdout: "" }));
  return stdout.toLowerCase().includes(`"${imageName.toLowerCase()}"`);
}

async function stopProcess(imageName) {
  await execFileAsync(
    "C:\\Windows\\System32\\taskkill.exe",
    ["/IM", imageName, "/F"],
    { windowsHide: true },
  ).catch(() => {});
}

async function readDevToolsPort() {
  const portFile = path.join(config.webViewDataDir, "DevToolsActivePort");
  const lines = (await fsp.readFile(portFile, "utf8")).trim().split(/\r?\n/);
  const port = Number(lines[0]);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error("CC Switch DevToolsActivePort 无效");
  }
  return port;
}

async function getCdpTarget() {
  const port = await readDevToolsPort();
  const response = await fetch(`http://127.0.0.1:${port}/json/list`, {
    signal: AbortSignal.timeout(2000),
  });
  if (!response.ok) throw new Error(`CC Switch CDP HTTP ${response.status}`);
  const targets = await response.json();
  const page = targets.find((target) => target.type === "page");
  if (!page?.webSocketDebuggerUrl) throw new Error("未找到 CC Switch WebView");
  return page.webSocketDebuggerUrl;
}

async function startCcSwitch() {
  if (!config.ccSwitchExe) {
    throw new Error("CC Switch executable is not configured");
  }
  await fsp.access(config.ccSwitchExe);
  const portFile = path.join(config.webViewDataDir, "DevToolsActivePort");
  await fsp.rm(portFile, { force: true }).catch(() => {});
  const child = spawn(config.ccSwitchExe, [], {
    detached: true,
    stdio: "ignore",
    windowsHide: true,
    env: {
      ...process.env,
      WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS:
        "--remote-debugging-address=127.0.0.1 --remote-debugging-port=0",
    },
  });
  child.unref();
  for (let attempt = 0; attempt < 60; attempt += 1) {
    await sleep(250);
    try {
      await getCdpTarget();
      await record("info", "CC Switch bridge connected");
      return;
    } catch {}
  }
  throw new Error("CC Switch 启动后未开放本机控制端口");
}

async function ensureCcSwitch() {
  try {
    await getCdpTarget();
    return;
  } catch (error) {
    await record("warn", `CC Switch bridge probe failed: ${error.message}`);
  }
  if (await processExists("cc-switch.exe")) {
    await record("warn", "CC Switch is running without bridge access; restarting it");
    await stopProcess("cc-switch.exe");
    await sleep(800);
  }
  await startCcSwitch();
}

class CdpConnection {
  constructor(socket) {
    this.socket = socket;
    this.pending = new Map();
    this.nextId = 1;
    socket.addEventListener("message", (event) => {
      const message = JSON.parse(event.data);
      if (!message.id || !this.pending.has(message.id)) return;
      const { resolve, reject } = this.pending.get(message.id);
      this.pending.delete(message.id);
      if (message.error) reject(new Error(message.error.message));
      else resolve(message.result);
    });
  }

  send(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = this.nextId++;
      this.pending.set(id, { resolve, reject });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }

  close() {
    this.socket.close();
  }
}

async function invoke(command, args = {}) {
  await ensureCcSwitch();
  const socket = new WebSocket(await getCdpTarget());
  await new Promise((resolve, reject) => {
    socket.addEventListener("open", resolve, { once: true });
    socket.addEventListener("error", reject, { once: true });
  });
  const cdp = new CdpConnection(socket);
  try {
    const expression = `(async () => {
      const invoke = globalThis.__TAURI_INTERNALS__?.invoke ||
        globalThis.__TAURI__?.core?.invoke;
      if (!invoke) throw new Error("Tauri invoke is unavailable");
      try {
        return { ok: true, value: await invoke(
          ${JSON.stringify(command)},
          ${JSON.stringify(args)}
        ) };
      } catch (error) {
        return { ok: false, error: String(error) };
      }
    })()`;
    const result = await cdp.send("Runtime.evaluate", {
      expression,
      awaitPromise: true,
      returnByValue: true,
    });
    if (result.exceptionDetails) {
      throw new Error(
        result.exceptionDetails.exception?.description ||
          result.exceptionDetails.text ||
          "CC Switch command failed",
      );
    }
    const envelope = result.result.value;
    if (!envelope?.ok) throw new Error(envelope?.error || "CC Switch command failed");
    return envelope.value;
  } finally {
    cdp.close();
  }
}

function extractTopLevelTomlValue(text, key) {
  let inSection = false;
  for (const rawLine of String(text || "").split(/\r?\n/)) {
    const line = rawLine.trim();
    if (line.startsWith("[")) inSection = true;
    if (inSection) continue;
    const match = line.match(new RegExp(`^${key}\\s*=\\s*"([^"]*)"`));
    if (match) return match[1];
  }
  return null;
}

function providerSummary(id, provider) {
  const configToml =
    provider?.settingsConfig?.config || provider?.settings_config?.config || "";
  const apiFormat = provider?.meta?.apiFormat || null;
  return {
    id,
    name: provider?.name || id,
    category: provider?.category || null,
    apiFormat,
    model: extractTopLevelTomlValue(configToml, "model"),
    needsRouting: apiFormat === "openai_chat",
  };
}

async function getLiveState() {
  const [currentId, rawProviders, proxy, takeover] = await Promise.all([
    invoke("get_current_provider", { app: "codex" }),
    invoke("get_providers", { app: "codex" }),
    invoke("get_proxy_status"),
    invoke("get_proxy_takeover_status"),
  ]);
  const providers = Object.entries(rawProviders).map(([id, provider]) =>
    providerSummary(id, provider),
  );
  const current = providers.find((provider) => provider.id === currentId) || null;
  const liveText = await fsp.readFile(config.codexConfigPath, "utf8").catch(() => "");
  return {
    current,
    providers,
    routing: {
      running: Boolean(proxy?.running),
      address: proxy?.address || null,
      port: proxy?.port || null,
      codexTakeover: Boolean(takeover?.codex),
    },
    codex: {
      running: await processExists("ChatGPT.exe"),
      liveModel: extractTopLevelTomlValue(liveText, "model"),
      liveProvider: extractTopLevelTomlValue(liveText, "model_provider"),
    },
    operation: activeOperation,
    logs: recentLogs.slice(0, 20),
  };
}

async function portOpen(host, port, timeout = 1500) {
  return await new Promise((resolve) => {
    const socket = net.createConnection({ host, port });
    const finish = (value) => {
      socket.destroy();
      resolve(value);
    };
    socket.setTimeout(timeout);
    socket.once("connect", () => finish(true));
    socket.once("timeout", () => finish(false));
    socket.once("error", () => finish(false));
  });
}

async function restartCodex() {
  await record("info", "Restarting Codex Desktop");
  for (const image of ["codex-code-mode-host.exe", "codex.exe", "ChatGPT.exe"]) {
    await stopProcess(image);
  }
  await sleep(1800);
  if (!config.codexAumid) {
    throw new Error("Codex Desktop AppUserModelId is not configured");
  }
  const child = spawn(
    "C:\\Windows\\explorer.exe",
    [`shell:AppsFolder\\${config.codexAumid}`],
    { detached: true, stdio: "ignore", windowsHide: true },
  );
  child.unref();
  for (let attempt = 0; attempt < 50; attempt += 1) {
    await sleep(400);
    if (await processExists("ChatGPT.exe")) {
      await record("info", "Codex Desktop is running");
      return;
    }
  }
  throw new Error("Codex Desktop 重启后未检测到进程");
}

async function verifySwitch(target) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    await sleep(300);
    const state = await getLiveState();
    const providerOk = state.current?.id === target.id;
    const routingOk =
      !target.needsRouting ||
      (state.routing.running &&
        state.routing.codexTakeover &&
        (await portOpen("127.0.0.1", 15721)));
    const modelOk = !target.model || state.codex.liveModel === target.model;
    if (providerOk && routingOk && modelOk) return state;
  }
  throw new Error("切换后的供应商、路由或模型验证未通过");
}

async function switchAndRestart(providerId) {
  const previous = await getLiveState();
  const target = previous.providers.find((provider) => provider.id === providerId);
  if (!target) throw new Error("目标供应商不存在");

  await recordHandoffEvent(
    "prepared",
    target,
    "Handoff snapshot created before the remote model switch.",
  );
  activeOperation = {
    providerId,
    providerName: target.name,
    startedAt: new Date().toISOString(),
    stage: "switching",
  };
  await record("info", `Switch requested: ${target.name}`);

  try {
    if (target.needsRouting) {
      if (!previous.routing.running) await invoke("start_proxy_server");
      if (!previous.routing.codexTakeover) {
        await invoke("set_proxy_takeover_for_app", {
          appType: "codex",
          enabled: true,
        });
      }
      await invoke("switch_proxy_provider", {
        appType: "codex",
        providerId: target.id,
      });
    } else {
      if (previous.routing.codexTakeover) {
        await invoke("set_proxy_takeover_for_app", {
          appType: "codex",
          enabled: false,
        });
      }
      await invoke("switch_provider", { app: "codex", id: target.id });
    }

    activeOperation.stage = "verifying";
    await verifySwitch(target);
    activeOperation.stage = "restarting";
    await restartCodex();
    activeOperation.stage = "complete";
    await record("info", `Switch complete: ${target.name}`);
    await recordHandoffEvent(
      "completed",
      target,
      "Provider switch verification and Codex restart completed.",
    );
    return await getLiveState();
  } catch (error) {
    await record("error", `Switch failed: ${error.message}`);
    await recordHandoffEvent("failed", target, error.message);
    activeOperation.stage = "failed";
    activeOperation.error = redact(error.message);
    throw error;
  } finally {
    setTimeout(() => {
      activeOperation = null;
    }, 5000).unref();
  }
}

const loginHtml = `<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Codex Remote Bridge</title><style>
body{margin:0;background:#0b1020;color:#e8ecf5;font:16px system-ui;display:grid;place-items:center;min-height:100vh}
main{width:min(88vw,390px);background:#151c31;border:1px solid #293451;border-radius:22px;padding:28px;box-shadow:0 20px 60px #0008}
h1{font-size:24px;margin:0 0 8px}p{color:#aeb8cf;line-height:1.55}
input,button{box-sizing:border-box;width:100%;border-radius:12px;padding:14px;font-size:16px}
input{background:#0d1425;color:#fff;border:1px solid #35415f;margin:12px 0}
button{border:0;background:#7868ff;color:#fff;font-weight:700}
</style></head><body><main><h1>Codex Remote Bridge</h1><p>请输入首次登录密码。登录状态仅保存在当前浏览器。</p>
<form method="post" action="/login"><input name="password" type="password" autocomplete="current-password" required autofocus>
<button type="submit">登录</button></form></main></body></html>`;

function dashboardHtml(csrf) {
  return `<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Codex Remote</title><style>
:root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;background:#090e1b;color:#eef2fb;font:15px system-ui}
main{width:min(94vw,560px);margin:22px auto 60px}.hero,.card{background:#141b2d;border:1px solid #27324c;border-radius:20px;padding:20px;margin:14px 0}
h1{font-size:24px;margin:0 0 6px}.muted{color:#9ca9c4}.status{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:18px}
.pill{background:#0c1323;border-radius:13px;padding:12px}.pill b{display:block;margin-top:5px;font-size:16px}
.provider{width:100%;display:flex;align-items:center;justify-content:space-between;background:#11192a;color:#fff;border:1px solid #303d5c;border-radius:15px;padding:15px;margin:10px 0;text-align:left}
.provider.current{border-color:#7b6cff;background:#1c2040}.provider:disabled{opacity:.5}.tag{font-size:12px;color:#aeb8cf}
.danger{background:#4b2130;border-color:#87445b}#message{white-space:pre-wrap;line-height:1.5}.ok{color:#7ee2a8}.bad{color:#ff8e9e}
button{font:inherit}.spin{animation:pulse 1s infinite}@keyframes pulse{50%{opacity:.55}}
</style></head><body><main><section class="hero"><h1>Codex Remote</h1><div class="muted">CC Switch 模型切换与客户端重启</div>
<div class="status"><div class="pill">当前供应商<b id="provider">读取中…</b></div><div class="pill">Codex<b id="codex">读取中…</b></div>
<div class="pill">本地路由<b id="routing">读取中…</b></div><div class="pill">实际模型<b id="model">读取中…</b></div></div></section>
<section class="card"><b>切换模型</b><p class="muted">选择后将验证配置并重启 Codex。正在执行的任务会中断。</p><div id="providers"></div></section>
<section class="card"><b>执行状态</b><p id="message" class="muted">准备就绪</p></section></main>
<script>
const csrf=${JSON.stringify(csrf)};let busy=false;
const e=id=>document.getElementById(id);
async function load(){
  try{
    const r=await fetch('/api/state',{cache:'no-store'});if(r.status===401){location.reload();return}
    const s=await r.json();e('provider').textContent=s.current?.name||'未知';e('codex').textContent=s.codex.running?'运行中':'未运行';
    e('routing').textContent=s.routing.running?(s.routing.codexTakeover?'已接管':'运行中'):'关闭';
    e('model').textContent=s.codex.liveModel||'未知';
    e('providers').innerHTML='';
    for(const p of s.providers){const b=document.createElement('button');b.className='provider'+(p.id===s.current?.id?' current':'');
      b.disabled=busy;b.innerHTML='<span><b>'+escapeHtml(p.name)+'</b><span class="tag">'+escapeHtml(p.model||'')+(p.needsRouting?' · 路由':'')+'</span></span><span>'+(p.id===s.current?.id?'当前':'切换')+'</span>';
      b.onclick=()=>switchTo(p);e('providers').appendChild(b)}
    if(s.operation){busy=true;e('message').className='spin';e('message').textContent='正在执行：'+s.operation.providerName+' · '+s.operation.stage}
  }catch(err){e('message').className='bad';e('message').textContent='状态读取失败：'+err.message}
}
function escapeHtml(v){return String(v).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
async function switchTo(p){
  if(busy)return;if(!confirm('切换到 '+p.name+' 并重启 Codex？\\n\\n当前任务会被中断。'))return;
  busy=true;e('message').className='spin';e('message').textContent='正在切换、验证并重启…';await load();
  try{const r=await fetch('/api/switch',{method:'POST',headers:{'content-type':'application/json','x-csrf-token':csrf},body:JSON.stringify({providerId:p.id})});
    const data=await r.json();if(!r.ok)throw new Error(data.error||'操作失败');e('message').className='ok';e('message').textContent='完成：'+(data.current?.name||p.name)+'，Codex 已重启。'}
  catch(err){e('message').className='bad';e('message').textContent='失败：'+err.message}
  finally{busy=false;await load()}
}
load();setInterval(load,5000);
</script></body></html>`;
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host || "localhost"}`);
    if (url.pathname === "/health") {
      return sendJson(res, 200, { ok: true });
    }
    if (url.pathname === "/login" && req.method === "POST") {
      const ip = req.socket.remoteAddress || "unknown";
      if (!loginAllowed(ip)) return send(res, 429, "登录尝试过多，请稍后再试");
      const body = new URLSearchParams(await readBody(req));
      if (!passwordMatches(body.get("password"))) {
        await record("warn", `Failed login from ${ip}`);
        return send(res, 401, loginHtml, { "Content-Type": "text/html; charset=utf-8" });
      }
      const id = crypto.randomBytes(32).toString("base64url");
      const session = {
        csrf: crypto.randomBytes(24).toString("base64url"),
        expiresAt: Date.now() + 30 * 24 * 60 * 60 * 1000,
      };
      sessions.set(id, session);
      const secure =
        req.headers["x-forwarded-proto"] === "https" ? "; Secure" : "";
      return send(res, 303, "", {
        Location: "/",
        "Set-Cookie": `ccrb_session=${encodeURIComponent(id)}; HttpOnly; SameSite=Strict; Path=/; Max-Age=2592000${secure}`,
      });
    }

    const session = getSession(req);
    if (!session) {
      return send(res, 401, loginHtml, {
        "Content-Type": "text/html; charset=utf-8",
      });
    }

    if (url.pathname === "/" && req.method === "GET") {
      return send(res, 200, dashboardHtml(session.csrf), {
        "Content-Type": "text/html; charset=utf-8",
      });
    }
    if (url.pathname === "/api/state" && req.method === "GET") {
      return sendJson(res, 200, await getLiveState());
    }
    if (url.pathname === "/api/switch" && req.method === "POST") {
      if (req.headers["x-csrf-token"] !== session.csrf) {
        return sendJson(res, 403, { error: "CSRF 校验失败" });
      }
      if (activeOperation) {
        return sendJson(res, 409, { error: "已有切换操作正在进行" });
      }
      const body = JSON.parse(await readBody(req));
      if (typeof body.providerId !== "string" || body.providerId.length > 128) {
        return sendJson(res, 400, { error: "供应商参数无效" });
      }
      return sendJson(res, 200, await switchAndRestart(body.providerId));
    }
    return sendJson(res, 404, { error: "Not found" });
  } catch (error) {
    await record("error", error.message);
    return sendJson(res, 500, { error: redact(error.message) });
  }
});

server.listen(config.port, config.host, async () => {
  await record("info", `Bridge listening on ${config.host}:${config.port}`);
  ensureCcSwitch().catch((error) =>
    record("error", `CC Switch startup check failed: ${error.message}`),
  );
});

async function shutdown() {
  await fsp.rm(pidPath, { force: true }).catch(() => {});
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 2000).unref();
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
