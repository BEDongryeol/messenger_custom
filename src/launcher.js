/*
 * Dooray Skin launcher (Mac / Windows 공용)
 *
 * Dooray Messenger 실행 파일 자체를 Node 로 실행한다:
 *   ELECTRON_RUN_AS_NODE=1 "<Dooray 실행파일>" launcher.js
 * 따라서 process.execPath == Dooray 실행 파일이며, PC 에 Node 설치가 필요 없다.
 *
 * 동작
 *  1) 이미 Skin 이 주입된 Dooray 가 떠 있으면 그 창만 앞으로 가져오고 끝낸다.
 *  2) 주입 안 된 Dooray 가 떠 있으면 종료한다(단일 인스턴스 앱이라 재시작 필요).
 *  3) Dooray 를 --inspect=127.0.0.1:<임시포트> 로 실행하고, 메인 프로세스에 훅을 심는다.
 *     훅: 모든 Dooray 웹 화면에 core.js 주입 + 창 투명도 메시지 처리.
 *  4) 디버거 포트를 즉시 닫는다(다른 로컬 프로세스가 붙지 못하게).
 * 앱 파일(app.asar, 서명)은 전혀 수정하지 않는다.
 */
const fs = require('fs');
const path = require('path');
const net = require('net');
const os = require('os');
const { spawn, execFileSync } = require('child_process');

const IS_MAC = process.platform === 'darwin';
const IS_WIN = process.platform === 'win32';
const DOORAY_BIN = process.execPath;
const MAC_APP = IS_MAC ? DOORAY_BIN.replace(/\/Contents\/MacOS\/[^/]+$/, '') : null;
// core.js 는 launcher.js 옆(앱 번들 Resources 또는 설치 폴더)에서 읽고,
// 로그/상태는 사용자 데이터 폴더에 쓴다(앱 번들 내부에 쓰지 않음).
const DATA_DIR = IS_WIN
  ? path.join(process.env.APPDATA || os.homedir(), 'DooraySkin')
  : path.join(os.homedir(), 'Library', 'Application Support', 'DooraySkin');
try {
  fs.mkdirSync(DATA_DIR, { recursive: true });
} catch {}
const LOG = path.join(DATA_DIR, 'launcher.log');
const STATE = path.join(DATA_DIR, 'state.json');
const CORE = fs.readFileSync(path.join(__dirname, 'core.js'), 'utf8');

const log = (...a) => {
  const line = `[${new Date().toISOString()}] ${a.map((x) => (typeof x === 'string' ? x : JSON.stringify(x))).join(' ')}\n`;
  try {
    fs.appendFileSync(LOG, line);
  } catch {}
  process.stdout.write(line);
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------- process helpers ----------
const exeName = path.basename(DOORAY_BIN);

function listDoorayPids() {
  try {
    if (IS_MAC) {
      const out = execFileSync('/usr/bin/pgrep', ['-x', exeName], { encoding: 'utf8' });
      return out.split(/\s+/).filter(Boolean).map(Number).filter((p) => p !== process.pid);
    }
    if (IS_WIN) {
      const out = execFileSync('tasklist', ['/FO', 'CSV', '/NH', '/FI', `IMAGENAME eq ${exeName}`], { encoding: 'utf8' });
      return out
        .split(/\r?\n/)
        .map((l) => l.split('","')[1])
        .filter(Boolean)
        .map(Number)
        .filter((p) => p && p !== process.pid);
    }
  } catch {
    return []; // pgrep 은 결과 없으면 exit 1
  }
  return [];
}

const alive = (pid) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

async function stopDooray() {
  const pids = listDoorayPids();
  if (!pids.length) return;
  log('기존 Dooray 종료', pids);
  if (IS_WIN) {
    try {
      execFileSync('taskkill', ['/IM', exeName, '/F', '/FI', `PID ne ${process.pid}`], { stdio: 'ignore' });
    } catch {}
  } else {
    for (const p of pids) try { process.kill(p, 'SIGTERM'); } catch {}
  }
  for (let i = 0; i < 40 && listDoorayPids().length; i++) await sleep(250);
  for (const p of listDoorayPids()) try { process.kill(p, 'SIGKILL'); } catch {}
  await sleep(500);
}

const freePort = () =>
  new Promise((res, rej) => {
    const s = net.createServer();
    s.listen(0, '127.0.0.1', () => {
      const { port } = s.address();
      s.close(() => res(port));
    });
    s.on('error', rej);
  });

function launchDooray(args = []) {
  const env = { ...process.env };
  delete env.ELECTRON_RUN_AS_NODE;
  if (IS_MAC) {
    // LaunchServices 로 띄워야 카메라/마이크 권한이 Dooray 앱 자신에게 귀속된다.
    const a = ['-a', MAC_APP];
    if (args.length) a.push('--args', ...args);
    execFileSync('/usr/bin/open', a, { env });
  } else {
    const child = spawn(DOORAY_BIN, args, { env, detached: true, stdio: 'ignore', windowsHide: false });
    child.unref();
  }
}

// ---------- main-process hook (Dooray 메인 프로세스 안에서 실행됨) ----------
function mainHook(CORE_SRC, HOOK_LOG, EARLY_FILE) {
  if (global.__drbHooked) return JSON.stringify({ ok: true, already: true, pid: process.pid });
  global.__drbHooked = true;
  const req = typeof require === 'function' ? require : process.mainModule.require;
  const { app, webContents, BrowserWindow, nativeTheme } = req('electron');
  const fs = req('fs');
  const hlog = (...a) => {
    try {
      fs.appendFileSync(HOOK_LOG, `[${new Date().toISOString()}] pid=${process.pid} ${a.map((x) => (typeof x === 'string' ? x : JSON.stringify(x))).join(' ')}\n`);
    } catch {}
  };
  hlog('hook installed');
  const isDooray = (u) => /^https:\/\/([a-z0-9-]+\.)*dooray\.com\//i.test(u || '');
  // 시작 덮개: 다크 모드 사용자가 Dooray 를 켤 때 밝은 화면이 번쩍이지 않게, 대화 화면 문서가 정해지는 순간(did-navigate)
  // 다크 배경색 덮개 CSS 를 넣는다. core.js 가 다크 모드를 적용하면 html[data-drb-ready] 로 걷히고, 4초 뒤엔 스스로 사라진다.
  // 색은 core.js 가 보낸 early 값을 EARLY_FILE 에 저장해 다음 실행 때 쓴다. (src/early.js 의 CSS 와 같은 내용 유지)
  const EARLY_URL_RE = /^https:\/\/([a-z0-9-]+\.)*dooray\.com\/messenger(?:\/?(?:[?#]|$)|\/(?:popup|channels)\/\d+)/i;
  let earlyBg = null;
  try {
    const e = JSON.parse(fs.readFileSync(EARLY_FILE, 'utf8'));
    if (e && /^#[0-9a-f]{6}$/i.test(e.bg)) earlyBg = e.bg;
  } catch {}
  const earlyCss = (bg) =>
    `html:not([data-drb-light]){background:${bg}!important;color-scheme:dark}` +
    `html:not([data-drb-light])::after{content:"";position:fixed;inset:0;z-index:2147483647;background:${bg};pointer-events:none;` +
    `transition:opacity .25s,visibility .25s;animation:drb-early-out .3s ease 4s forwards}` +
    `html[data-drb-ready]::after{opacity:0;visibility:hidden}` +
    `@keyframes drb-early-out{to{opacity:0;visibility:hidden}}`;
  const putEarly = (wc, url) => {
    if (!earlyBg || !EARLY_URL_RE.test(url || '') || wc.isDestroyed()) return;
    wc.insertCSS(earlyCss(earlyBg)).then(() => hlog('early css', wc.id, earlyBg)).catch((e) => hlog('early css error', String(e && e.message)));
  };
  const saveEarly = (bg) => {
    const v = typeof bg === 'string' && /^#[0-9a-f]{6}$/i.test(bg) ? bg : null;
    if (v === earlyBg) return;
    earlyBg = v;
    try {
      if (v) fs.writeFileSync(EARLY_FILE, JSON.stringify({ bg: v }));
      else fs.rmSync(EARLY_FILE, { force: true });
    } catch {}
  };
  let opacity = 1;
  // 투명도는 대화 창(앱 메인 창 = file:// 셸, 메신저 화면, 따로 띄운 채팅 창)에만 적용.
  // 이미지·파일·메일 미리보기, 메일·업무·캘린더 작성, 조직도 등 나머지 창은 항상 불투명.
  // 주소가 아직 없는(막 만들어진) 창도 불투명으로 시작해 깜빡임을 막고, 주소가 정해지면 다시 판단한다.
  const CHAT_URL_RE = /^file:|^https:\/\/[^/]+\/messenger\/?(?:[?#]|$)|^https:\/\/[^/]+\/messenger\/(?:popup|channels)\/\d+(?:\/threads\/\d+)?\/?(?:[?#]|$)/;
  const isOpaqueWindow = (w) => {
    try {
      return !CHAT_URL_RE.test(w.webContents.getURL() || "");
    } catch {
      return false;
    }
  };
  const applyOpacity = (w) => {
    try {
      if (!w.isDestroyed()) w.setOpacity(isOpaqueWindow(w) ? 1 : opacity);
    } catch {}
  };
  const PROBE =
    ';JSON.stringify({skin: window.__drbSkin && window.__drbSkin.version, host: window.__drbSkin && window.__drbSkin.host, btn: !!document.querySelector("[data-drb-sidebar-btn]"), header: !!document.querySelector("[data-testid=channel-header-title]")})';
  const inject = (wc, why) => {
    if (wc.isDestroyed()) return;
    const url = wc.getURL();
    if (!isDooray(url)) return hlog('skip', why, wc.id, url.slice(0, 80));
    wc.executeJavaScript('window.__DRB_HOST="desktop";\n' + CORE_SRC + PROBE, true)
      .then((r) => {
        hlog('inject', why, wc.id, url.slice(0, 80), r);
        // 버튼은 SPA 렌더링 뒤에 붙으므로 5초 뒤 상태를 한 번 더 기록
        setTimeout(() => {
          if (!wc.isDestroyed()) wc.executeJavaScript(PROBE.slice(1), true).then((r2) => hlog('after5s', wc.id, r2)).catch(() => {});
        }, 5000);
      })
      .catch((e) => hlog('inject-error', why, wc.id, url.slice(0, 80), String(e && e.message)));
  };
  // 자동 업데이트: 페이지의 [업데이트] → 새 DooraySkin-mac.zip 을 받아 풀고 새 Dooray Skin.app 실행.
  // 새 앱이 ~/Applications 에 자기 설치 → 런처가 버전 변경을 보고 이 Dooray 를 재시작한다.
  // 브라우저가 아니라 메인 프로세스가 받으므로 quarantine 이 붙지 않아 Gatekeeper 경고가 없다.
  const UPDATE_URL_RE = /^https:\/\/github\.com\/BEDongryeol\/messenger_custom\/releases\/download\/[^/]+\/DooraySkin-mac\.zip$/;
  let updating = false;
  const notifyPages = (js) =>
    webContents.getAllWebContents().forEach((w) => {
      try {
        if (!w.isDestroyed() && isDooray(w.getURL())) w.executeJavaScript(js, true).catch(() => {});
      } catch {}
    });
  const doUpdate = async (u) => {
    if (updating) return;
    updating = true;
    try {
      if (!UPDATE_URL_RE.test(String(u.url))) throw new Error('허용되지 않은 주소 ' + u.url);
      const os = req('os');
      const path = req('path');
      const cp = req('child_process');
      const doFetch = globalThis.fetch || req('electron').net.fetch;
      hlog('update start', u.version, u.url);
      const res = await doFetch(u.url);
      if (!res.ok) throw new Error('다운로드 ' + res.status);
      const buf = Buffer.from(await res.arrayBuffer());
      const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dooray-skin-'));
      const zip = path.join(dir, 'DooraySkin-mac.zip');
      fs.writeFileSync(zip, buf);
      cp.execFileSync('/usr/bin/ditto', ['-x', '-k', zip, dir]);
      const app = path.join(dir, 'Dooray Skin.app');
      if (!fs.existsSync(path.join(app, 'Contents', 'MacOS', 'DooraySkin'))) throw new Error('zip 안에 Dooray Skin.app 이 없습니다');
      // 혹시 다운로드 표시(quarantine)가 붙어 있으면 실행 전에 제거 (붙어 있으면 Gatekeeper 가 새 앱 실행을 막는다)
      try {
        cp.execFileSync('/usr/bin/xattr', ['-dr', 'com.apple.quarantine', app]);
      } catch {}
      hlog('update downloaded', buf.length, app);
      cp.spawn('/usr/bin/open', ['-n', app], { detached: true, stdio: 'ignore' }).unref();
    } catch (e) {
      updating = false;
      const msg = String((e && e.message) || e);
      hlog('update error', msg);
      notifyPages(`window.__drbSkin && window.__drbSkin.updateFailed && window.__drbSkin.updateFailed(${JSON.stringify(msg)})`);
    }
  };
  const onConsole = (...args) => {
    const e = args[0];
    const msg = (e && typeof e.message === 'string' && e.message) || args[2];
    if (typeof msg !== 'string' || !msg.startsWith('__DRB__:')) return;
    try {
      const m = JSON.parse(msg.slice(8));
      if (m.update && typeof m.update.url === 'string') doUpdate(m.update);
      if ('early' in m) saveEarly(m.early);
      if (typeof m.windowOpacity === 'number') {
        opacity = Math.max(0.3, Math.min(1, m.windowOpacity));
        BrowserWindow.getAllWindows().forEach(applyOpacity);
      }
      // 다크 모드: 창 제목 표시줄·테두리(macOS 창 크롬, 시스템 메뉴)를 어둡게. 끄면 OS 설정을 따른다
      if (typeof m.dark === 'boolean' && nativeTheme) {
        try {
          nativeTheme.themeSource = m.dark ? 'dark' : 'system';
        } catch (err) {
          hlog('nativeTheme error', String(err && err.message));
        }
      }
    } catch {}
  };
  const attach = (wc) => {
    if (wc.__drb) return;
    wc.__drb = true;
    hlog('attach', wc.id, wc.getURL().slice(0, 80), 'loading=' + wc.isLoading());
    wc.on('did-navigate', (_e, url) => putEarly(wc, url));
    wc.on('dom-ready', () => inject(wc, 'dom-ready'));
    wc.on('did-navigate-in-page', () => inject(wc, 'in-page'));
    wc.on('console-message', onConsole);
    if (!wc.isLoading()) inject(wc, 'existing');
  };
  webContents.getAllWebContents().forEach(attach);
  app.on('web-contents-created', (_e, wc) => attach(wc));
  // 새 창은 만들어질 때 주소가 비어 있으므로, 주소가 정해진 뒤(did-navigate)에 다시 적용해 미리보기 창을 불투명으로 돌린다
  app.on('browser-window-created', (_e, w) => {
    applyOpacity(w);
    try {
      w.webContents.on('did-navigate', () => applyOpacity(w));
      w.webContents.on('did-navigate-in-page', () => applyOpacity(w));
    } catch {}
  });
  return JSON.stringify({ ok: true, pid: process.pid, wc: webContents.getAllWebContents().length });
}

async function cdpEvaluate(port, expression) {
  let target;
  for (let i = 0; i < 120 && !target; i++) {
    try {
      const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
      target = list.find((t) => t.webSocketDebuggerUrl);
    } catch {}
    if (!target) await sleep(250);
  }
  if (!target) throw new Error('Dooray 디버거 포트에 연결하지 못했습니다(30초 초과).');
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((res, rej) => {
    ws.onopen = res;
    ws.onerror = () => rej(new Error('WebSocket 연결 실패'));
  });
  let id = 0;
  const pending = new Map();
  ws.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) {
      pending.get(m.id)(m);
      pending.delete(m.id);
    }
  };
  const send = (method, params = {}) =>
    new Promise((res) => {
      const i = ++id;
      pending.set(i, res);
      ws.send(JSON.stringify({ id: i, method, params }));
    });
  await send('Runtime.enable');
  // app ready 이후에 훅을 심기 위해 잠깐 기다린다.
  const readyExpr = `(()=>{try{const r=typeof require==='function'?require:process.mainModule.require;return r('electron').app.isReady()}catch(e){return 'ERR:'+e.message}})()`;
  for (let i = 0; i < 60; i++) {
    const r = await send('Runtime.evaluate', { expression: readyExpr, includeCommandLineAPI: true, returnByValue: true });
    if (r.result?.result?.value === true) break;
    await sleep(250);
  }
  const res = await send('Runtime.evaluate', { expression, includeCommandLineAPI: true, returnByValue: true, awaitPromise: true });
  // 디버거 포트 닫기
  await send('Runtime.evaluate', {
    expression: `(()=>{const i=(typeof require==='function'?require:process.mainModule.require)('inspector');setTimeout(()=>{try{i.close()}catch(e){}},300);return 'closing'})()`,
    includeCommandLineAPI: true,
  });
  ws.close();
  if (res.result?.exceptionDetails) throw new Error('훅 실행 오류: ' + JSON.stringify(res.result.exceptionDetails).slice(0, 500));
  return res.result?.result?.value;
}

async function main() {
  log(`launcher start · ${os.platform()} · Dooray=${DOORAY_BIN} · node=${process.versions.node} · electron=${process.versions.electron}`);
  if (typeof WebSocket !== 'function') throw new Error('이 Dooray 버전은 WebSocket 미지원 Node 를 사용합니다(지원 불가).');

  // 1) 이미 주입된 인스턴스가 살아 있으면 포커스만
  let state = {};
  try {
    state = JSON.parse(fs.readFileSync(STATE, 'utf8'));
  } catch {}
  const running = listDoorayPids();
  const coreVer = (CORE.match(/VERSION = '([\d.]+)'/) || [])[1] || '?';
  if (state.pid && state.version === coreVer && running.includes(state.pid) && alive(state.pid)) {
    log('이미 Skin 이 적용된 Dooray 실행 중 → 창만 활성화', state.pid);
    launchDooray();
    return;
  }

  // 2) 주입 안 된 Dooray 종료
  await stopDooray();

  // 3) inspect 모드로 실행 후 훅 주입
  const port = await freePort();
  log('Dooray 실행 (inspect port', port, ')');
  launchDooray([`--inspect=127.0.0.1:${port}`]);
  const expr = `(${mainHook.toString()})(${JSON.stringify(CORE)}, ${JSON.stringify(path.join(DATA_DIR, 'hook.log'))}, ${JSON.stringify(path.join(DATA_DIR, 'early.json'))})`;
  const out = await cdpEvaluate(port, expr);
  log('hook result', out);
  const parsed = JSON.parse(out || '{}');
  if (!parsed.ok) throw new Error('훅 주입 실패: ' + out);
  fs.writeFileSync(STATE, JSON.stringify({ pid: parsed.pid, version: coreVer, at: new Date().toISOString() }));
  log('완료');
}

module.exports = { mainHook, cdpEvaluate };
if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch((e) => {
      log('ERROR', e.stack || String(e));
      process.exit(1);
    });
}
