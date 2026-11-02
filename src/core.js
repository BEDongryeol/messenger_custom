/*
 * Dooray Skin core (웹 Chrome 확장 + Dooray 데스크톱 앱 공용)
 * - 반드시 페이지 MAIN world 에서 실행 (React props 에서 channelId 를 읽기 때문)
 * - 저장소: IndexedDB 'dooray-skin' (origin 별). 창/탭 간 동기화는 BroadcastChannel.
 * - 데스크톱 앱에서는 launcher 가 window.__DRB_HOST = 'desktop' 을 먼저 설정하고 주입한다.
 *   창 투명도는 console.debug('__DRB__:{...}') 로 메인 프로세스 훅에 전달한다.
 */
(() => {
  if (window.__drbCore) return;
  window.__drbCore = true;

  const VERSION = '0.2.1';
  // 런처가 넣는 표식 + Electron 앱 자체 판별(이중 안전장치)
  const IS_DESKTOP =
    window.__DRB_HOST === 'desktop' || /Electron\//.test(navigator.userAgent) || !!window.macBridge || !!window.winBridge;
  const root = document.documentElement;
  const STYLE_ID = 'drb-style';
  const MAX_EDGE = 2560;
  const WRAP = '#main-contents div:has(> .js-scroll-area)';
  const BG_DEFAULTS = { image: '', fit: 'cover', opacity: 100, blur: 0, veil: 0, enabled: true };
  const FIT_CSS = {
    cover: 'center / cover no-repeat',
    contain: 'center / contain no-repeat',
    center: 'center / auto no-repeat',
    tile: 'top left / auto repeat',
  };
  // 우측 사이드바 버튼 앵커 (ko / en)
  const ANCHOR_LAST = ['링크 모아보기', 'Links', 'Link'];
  const ANCHOR_FIRST = ['검색', 'Search'];

  // ---------------- storage ----------------
  const idb = (() => {
    let dbp;
    const open = () =>
      dbp ||
      (dbp = new Promise((res, rej) => {
        const r = indexedDB.open('dooray-skin', 1);
        r.onupgradeneeded = () => r.result.createObjectStore('kv');
        r.onsuccess = () => res(r.result);
        r.onerror = () => rej(r.error);
      }));
    const tx = async (mode, fn) => {
      const db = await open();
      return new Promise((res, rej) => {
        const t = db.transaction('kv', mode);
        const out = fn(t.objectStore('kv'));
        t.oncomplete = () => res(out && 'result' in out ? out.result : undefined);
        t.onerror = () => rej(t.error);
      });
    };
    return {
      get: (k) => tx('readonly', (s) => s.get(k)),
      set: (k, v) => tx('readwrite', (s) => s.put(v, k)),
    };
  })();

  const freshConfig = () => ({ version: 2, global: { windowOpacity: 100, defaultBg: { ...BG_DEFAULTS, enabled: false } }, rooms: {} });
  let config = freshConfig();
  const bc = 'BroadcastChannel' in window ? new BroadcastChannel('dooray-skin') : null;

  const normalize = (c) => {
    const base = freshConfig();
    if (!c || typeof c !== 'object') return base;
    // v1(확장 0.1) 형식: { rooms } 또는 rooms map 자체
    const rooms = c.rooms && typeof c.rooms === 'object' ? c.rooms : c.version ? {} : c;
    return {
      version: 2,
      global: {
        windowOpacity: Number(c.global?.windowOpacity) || 100,
        defaultBg: { ...base.global.defaultBg, ...(c.global?.defaultBg || {}) },
      },
      rooms: { ...rooms },
    };
  };

  const load = async () => {
    try {
      config = normalize(await idb.get('config'));
    } catch (e) {
      console.warn('[dooray-skin] load failed', e);
    }
  };
  let saveTimer = 0;
  const save = () => {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(async () => {
      try {
        await idb.set('config', config);
        bc?.postMessage({ type: 'changed' });
      } catch (e) {
        console.warn('[dooray-skin] save failed', e);
      }
    }, 200);
  };
  bc?.addEventListener('message', async (e) => {
    if (e.data?.type !== 'changed') return;
    await load();
    applyAll();
    render();
  });

  // ---------------- channel detection ----------------
  const readChannel = () => {
    const header = document.querySelector('[data-testid="channel-header-title"]');
    if (!header) return { id: '', name: '' };
    const name = header.textContent.trim();
    let id = null;
    const fk = Object.keys(header).find((k) => k.startsWith('__reactFiber'));
    let f = fk ? header[fk] : null;
    for (let i = 0; f && i < 80; i++, f = f.return) {
      const p = f.memoizedProps;
      if (p && (typeof p.channelId === 'string' || typeof p.channelId === 'number')) {
        id = String(p.channelId);
        break;
      }
    }
    return { id: id || `name:${name}`, name };
  };
  let channel = { id: '', name: '' };

  // ---------------- background ----------------
  const cssStr = (s) => JSON.stringify(String(s));
  const effectiveBg = () => {
    const room = channel.id ? config.rooms[channel.id] : null;
    if (room) return room.enabled !== false && room.image ? room : null; // 방 설정이 있으면 우선(꺼짐 포함)
    const d = config.global.defaultBg;
    return d.enabled !== false && d.image ? d : null;
  };
  const buildCss = (cfg) => {
    const c = { ...BG_DEFAULTS, ...cfg };
    const blur = Number(c.blur) || 0;
    return `
${WRAP}{position:relative;isolation:isolate;overflow:hidden;}
${WRAP}::before{content:"";position:absolute;inset:0;z-index:0;pointer-events:none;
  background:url(${cssStr(c.image)}) ${FIT_CSS[c.fit] || FIT_CSS.cover};
  opacity:${Math.max(0, Math.min(100, c.opacity)) / 100};
  ${blur ? `filter:blur(${blur}px);transform:scale(1.06);` : ''}}
${WRAP}::after{content:"";position:absolute;inset:0;z-index:0;pointer-events:none;
  background:rgba(255,255,255,${Math.max(0, Math.min(90, c.veil)) / 100});}
${WRAP} > .js-scroll-area{position:relative;z-index:1;}`;
  };
  const applyBg = () => {
    const cfg = effectiveBg();
    let st = document.getElementById(STYLE_ID);
    if (!cfg) return st?.remove();
    if (!st) {
      st = document.createElement('style');
      st.id = STYLE_ID;
      document.head.appendChild(st);
    }
    const text = buildCss(cfg);
    if (st.textContent !== text) st.textContent = text;
  };
  let lastOpacitySent = null;
  const applyWindowOpacity = () => {
    if (!IS_DESKTOP) return;
    const v = Math.max(30, Math.min(100, Number(config.global.windowOpacity) || 100));
    if (v === lastOpacitySent) return;
    lastOpacitySent = v;
    console.debug('__DRB__:' + JSON.stringify({ windowOpacity: v / 100 }));
  };
  const applyAll = () => {
    applyBg();
    applyWindowOpacity();
  };

  // ---------------- image ----------------
  const fileToDataUrl = (file) =>
    new Promise((res, rej) => {
      const fr = new FileReader();
      fr.onload = () => res(fr.result);
      fr.onerror = rej;
      fr.readAsDataURL(file);
    });
  const compress = async (file) => {
    if (file.type === 'image/gif') return fileToDataUrl(file);
    const bmp = await createImageBitmap(file);
    const s = Math.min(1, MAX_EDGE / Math.max(bmp.width, bmp.height));
    const c = document.createElement('canvas');
    c.width = Math.round(bmp.width * s);
    c.height = Math.round(bmp.height * s);
    c.getContext('2d').drawImage(bmp, 0, 0, c.width, c.height);
    bmp.close?.();
    return c.toDataURL('image/webp', 0.88);
  };

  // ---------------- sidebar button (#1) ----------------
  const ICON =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none"><rect x="3.6" y="4.6" width="16.8" height="14.8" rx="2.2" stroke="currentColor" stroke-width="1.2"/><circle cx="8.6" cy="9.4" r="1.7" stroke="currentColor" stroke-width="1.1"/><path d="M4.2 17.2l4.9-4.6 3.3 3 3.1-3.4 4.3 4.6" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"/></svg>';
  const findBtn = (labels) => {
    for (const l of labels) {
      const b = document.querySelector(`button[aria-label="${l}"]`);
      if (b) return b;
    }
    return null;
  };
  const ensureSidebarButton = () => {
    const existing = document.querySelector('[data-drb-sidebar-btn]');
    if (existing?.isConnected) return;
    const last = findBtn(ANCHOR_LAST);
    const first = findBtn(ANCHOR_FIRST);
    if (!last || !first) return;
    let item = last;
    while (item.parentElement && !item.parentElement.contains(first)) item = item.parentElement;
    if (!item.parentElement) return;
    const clone = item.cloneNode(true);
    clone.setAttribute('data-drb-sidebar-item', '1');
    const btn = clone.querySelector('button') || clone;
    btn.setAttribute('aria-label', '배경 설정');
    btn.setAttribute('title', '대화방 배경 설정 (Alt+Shift+B)');
    btn.setAttribute('data-drb-sidebar-btn', '1');
    const svg = btn.querySelector('svg');
    if (svg) svg.outerHTML = ICON;
    btn.addEventListener('click', (e) => {
      e.preventDefault();
      e.stopPropagation();
      togglePanel();
    });
    item.after(clone);
  };

  // ---------------- panel ----------------
  let host = null;
  let sr = null;
  let tab = 'room';

  const PANEL_CSS = `
:host{all:initial}
.p{position:fixed;z-index:2147483000;width:328px;max-height:calc(100vh - 32px);overflow:auto;box-sizing:border-box;
 background:#fff;color:#222;border:1px solid #ddd;border-radius:12px;box-shadow:0 8px 28px rgba(0,0,0,.18);
 font:13px/1.45 -apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo","Malgun Gothic",sans-serif;padding:14px 16px}
h1{font-size:14px;margin:0 0 8px;display:flex;justify-content:space-between;align-items:center}
.tabs{display:flex;gap:4px;margin:0 0 10px;border-bottom:1px solid #eee}
.tabs button{border:none;background:none;border-bottom:2px solid transparent;border-radius:0;padding:6px 10px;color:#666}
.tabs button.on{border-bottom-color:#2f6fed;color:#2f6fed;font-weight:600}
.sub{color:#666;margin:0 0 10px;word-break:break-all}
.win{background:#f3f6ff;border-radius:8px;padding:8px 10px;margin:0 0 10px}
.win .muted{margin:2px 0 0}
.row{margin:10px 0}
label.t{display:block;font-weight:600;margin-bottom:4px}
input[type=range]{width:100%}
input[type=text],select{width:100%;box-sizing:border-box;padding:6px 8px;border:1px solid #ccc;border-radius:6px;font:inherit}
.btns{display:flex;gap:6px;flex-wrap:wrap;align-items:center}
.nowrap{flex-wrap:nowrap}
button{font:inherit;white-space:nowrap;padding:6px 10px;border:1px solid #ccc;border-radius:6px;background:#f7f7f7;cursor:pointer;color:#222}
button.primary{background:#2f6fed;color:#fff;border-color:#2f6fed}
button.danger{color:#c62828}
button.x{border:none;background:none;font-size:18px;padding:0 4px;color:#888}
.chk{display:flex;align-items:center;gap:4px}
.preview{height:80px;border:1px dashed #ccc;border-radius:8px;background:#fafafa center/cover no-repeat;margin-top:6px}
.list{margin:0;padding:0;list-style:none}
.list li{display:flex;justify-content:space-between;align-items:center;padding:4px 0;border-bottom:1px solid #f0f0f0}
.list li span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:220px}
.muted{color:#888;font-size:12px;margin:4px 0}
hr{border:none;border-top:1px solid #eee;margin:12px 0}
.msg{color:#2f6fed;font-size:12px;min-height:16px;margin:6px 0 0}
[hidden]{display:none!important}`;

  const bgEditorHtml = (scope) => `
<div data-scope="${scope}">
  <div class="row">
    <label class="t">이미지</label>
    <div class="btns">
      <button class="primary" data-act="pick">파일 선택</button>
      <input type="file" accept="image/*" data-k="file" hidden>
      <label class="chk"><input type="checkbox" data-k="enabled"> 켜기</label>
    </div>
    <div class="row btns nowrap">
      <input type="text" placeholder="또는 이미지 URL (https://...)" data-k="url">
      <button data-act="url">적용</button>
    </div>
    <div class="preview" data-k="preview"></div>
  </div>
  <div class="row">
    <label class="t">맞춤</label>
    <select data-k="fit">
      <option value="cover">채우기(cover)</option>
      <option value="contain">전체 보이기(contain)</option>
      <option value="center">원본 크기 가운데</option>
      <option value="tile">바둑판(tile)</option>
    </select>
  </div>
  <div class="row"><label class="t">이미지 투명도 <span data-v="opacity"></span></label><input type="range" min="5" max="100" data-k="opacity"></div>
  <div class="row"><label class="t">블러 <span data-v="blur"></span></label><input type="range" min="0" max="20" data-k="blur"></div>
  <div class="row"><label class="t">흰색 가림막(가독성) <span data-v="veil"></span></label><input type="range" min="0" max="90" data-k="veil"></div>
</div>`;

  const PANEL_HTML = `
<style>${PANEL_CSS}</style>
<div class="p" data-ref="p">
  <h1>배경 설정 <button class="x" data-act="close" title="닫기">×</button></h1>
  <div class="row win" data-ref="winRow">
    <label class="t">두레이 창 투명도 <span data-v="windowOpacity"></span></label>
    <input type="range" min="30" max="100" data-g="windowOpacity">
    <p class="muted" data-ref="winNote"></p>
  </div>
  <div class="tabs">
    <button data-tab="room">이 방</button>
    <button data-tab="global">전체(Global)</button>
  </div>
  <section data-pane="room">
    <p class="sub" data-ref="room"></p>
    <div data-ref="roomEditor">
      <p class="muted" data-ref="roomMode"></p>
      ${bgEditorHtml('room')}
      <div class="btns"><button class="danger" data-act="removeRoom">이 방 설정 삭제(기본 배경 따르기)</button></div>
    </div>
    <p class="muted" data-ref="noroom" hidden>대화방을 먼저 열어 주세요.</p>
  </section>
  <section data-pane="global" hidden>
    <label class="t">기본 배경 (방별 설정이 없는 모든 방)</label>
    ${bgEditorHtml('global')}
    <hr>
    <label class="t">방별 설정 목록</label>
    <ul class="list" data-ref="list"></ul>
    <hr>
    <div class="btns">
      <button data-act="export">설정 내보내기</button>
      <button data-act="import">가져오기</button>
      <input type="file" accept="application/json" data-ref="importFile" hidden>
    </div>
    <p class="muted">방 키가 channelId 라서 같은 방이면 팀원끼리 JSON 공유 시 그대로 적용됩니다. v${VERSION}</p>
  </section>
  <p class="msg" data-ref="msg"></p>
</div>`;

  const $ = (sel) => sr?.querySelector(sel);
  const $$ = (sel) => (sr ? [...sr.querySelectorAll(sel)] : []);
  const flash = (t) => {
    const m = $('[data-ref=msg]');
    if (!m) return;
    m.textContent = t;
    clearTimeout(flash.t);
    flash.t = setTimeout(() => m.isConnected && (m.textContent = ''), 2500);
  };

  const getBg = (scope) =>
    scope === 'global' ? { ...BG_DEFAULTS, ...config.global.defaultBg } : { ...BG_DEFAULTS, ...(config.rooms[channel.id] || {}) };

  const patchBg = (scope, patch) => {
    if (scope === 'global') {
      config.global.defaultBg = { ...config.global.defaultBg, ...patch };
    } else {
      if (!channel.id) return;
      const prev = config.rooms[channel.id] || { ...BG_DEFAULTS };
      config.rooms[channel.id] = { ...prev, ...patch, name: channel.name, updatedAt: Date.now() };
    }
    applyAll();
    save();
    render();
  };

  const renderEditor = (scope) => {
    const box = $(`[data-scope=${scope}]`);
    if (!box) return;
    const c = getBg(scope);
    const q = (k) => box.querySelector(`[data-k=${k}]`);
    q('fit').value = c.fit;
    q('enabled').checked = c.enabled !== false;
    for (const k of ['opacity', 'blur', 'veil']) {
      q(k).value = c[k];
      box.querySelector(`[data-v=${k}]`).textContent = k === 'blur' ? `${c[k]}px` : `${c[k]}%`;
    }
    q('preview').style.backgroundImage = c.image ? `url(${cssStr(c.image)})` : 'none';
  };

  const render = () => {
    if (!sr) return;
    $$('.tabs button').forEach((b) => b.classList.toggle('on', b.dataset.tab === tab));
    $$('[data-pane]').forEach((p) => (p.hidden = p.dataset.pane !== tab));

    const hasRoom = !!channel.id;
    $('[data-ref=room]').textContent = hasRoom ? `${channel.name || '(이름 없음)'} · ${channel.id}` : '';
    $('[data-ref=roomEditor]').hidden = !hasRoom;
    $('[data-ref=noroom]').hidden = hasRoom;
    $('[data-ref=roomMode]').textContent = config.rooms[channel.id]
      ? '이 방 전용 설정을 사용 중입니다.'
      : config.global.defaultBg.image && config.global.defaultBg.enabled !== false
        ? '현재 기본 배경이 적용 중입니다. 아래에서 바꾸면 이 방 전용 설정이 생깁니다.'
        : '아래에서 설정하면 이 방에만 적용됩니다.';
    renderEditor('room');
    renderEditor('global');

    const w = $('[data-g=windowOpacity]');
    w.value = config.global.windowOpacity;
    $('[data-ref=winRow]').hidden = !IS_DESKTOP; // 브라우저에서는 창 투명도 자체가 불가능하므로 숨김
    $('[data-v=windowOpacity]').textContent = `${config.global.windowOpacity}%`;
    $('[data-ref=winNote]').textContent = '창 전체가 반투명해져 뒤 화면이 비칩니다. (최소 30%, 모든 Dooray 창 공통)';

    const list = $('[data-ref=list]');
    list.textContent = '';
    const entries = Object.entries(config.rooms).sort((a, b) => (b[1].updatedAt || 0) - (a[1].updatedAt || 0));
    if (!entries.length) list.innerHTML = '<li><span class="muted">아직 없음</span></li>';
    for (const [rid, r] of entries) {
      const li = document.createElement('li');
      const s = document.createElement('span');
      s.textContent = `${rid === channel.id ? '● ' : ''}${r.name || rid}${r.enabled === false ? ' (꺼짐)' : ''}`;
      s.title = rid;
      const del = document.createElement('button');
      del.className = 'x';
      del.textContent = '×';
      del.title = '삭제';
      del.onclick = () => {
        delete config.rooms[rid];
        applyAll();
        save();
        render();
      };
      li.append(s, del);
      list.appendChild(li);
    }
  };

  const positionPanel = () => {
    const p = $('[data-ref=p]');
    if (!p) return;
    const b = document.querySelector('[data-drb-sidebar-btn]');
    const r = b?.getBoundingClientRect();
    if (r && r.width) {
      const h = p.offsetHeight || 400;
      p.style.top = `${Math.max(16, Math.min(r.top - 40, window.innerHeight - h - 16))}px`;
      p.style.right = `${Math.max(8, window.innerWidth - r.left + 8)}px`;
    } else {
      p.style.top = '64px';
      p.style.right = '72px';
    }
  };

  const openPanel = () => {
    if (host) return;
    host = document.createElement('div');
    host.id = 'drb-panel-host';
    sr = host.attachShadow({ mode: 'open' });
    sr.innerHTML = PANEL_HTML;
    document.body.appendChild(host);
    positionPanel();

    sr.addEventListener('click', async (e) => {
      const t = e.target;
      const tabBtn = t.closest('[data-tab]');
      if (tabBtn) {
        tab = tabBtn.dataset.tab;
        render();
        return positionPanel();
      }
      const act = t.closest('[data-act]')?.dataset.act;
      if (!act) return;
      const scope = t.closest('[data-scope]')?.dataset.scope;
      const box = scope && $(`[data-scope=${scope}]`);
      if (act === 'close') closePanel();
      if (act === 'pick') box.querySelector('[data-k=file]').click();
      if (act === 'url') {
        const u = box.querySelector('[data-k=url]').value.trim();
        if (!/^https?:\/\//.test(u)) return flash('http(s) URL 을 입력해 주세요.');
        patchBg(scope, { image: u, enabled: true });
        flash('적용했습니다.');
      }
      if (act === 'removeRoom') {
        delete config.rooms[channel.id];
        applyAll();
        save();
        render();
        flash('이 방 설정을 삭제했습니다.');
      }
      if (act === 'export') {
        const blob = new Blob([JSON.stringify(config, null, 2)], { type: 'application/json' });
        const a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = `dooray-skin-${new Date().toISOString().slice(0, 10)}.json`;
        a.click();
        setTimeout(() => URL.revokeObjectURL(a.href), 1000);
      }
      if (act === 'import') $('[data-ref=importFile]').click();
    });

    sr.addEventListener('change', async (e) => {
      const t = e.target;
      const scope = t.closest('[data-scope]')?.dataset.scope;
      const k = t.dataset.k;
      if (scope && k === 'file') {
        const f = t.files?.[0];
        t.value = '';
        if (!f) return;
        try {
          flash('이미지 처리 중...');
          patchBg(scope, { image: await compress(f), enabled: true });
          flash('적용했습니다.');
        } catch (err) {
          flash(`이미지를 읽지 못했습니다: ${err.message}`);
        }
      } else if (scope && k === 'fit') patchBg(scope, { fit: t.value });
      else if (scope && k === 'enabled') patchBg(scope, { enabled: t.checked });
      else if (t.dataset.ref === 'importFile') {
        const f = t.files?.[0];
        t.value = '';
        if (!f) return;
        try {
          const inc = normalize(JSON.parse(await f.text()));
          config = { ...config, global: inc.global, rooms: { ...config.rooms, ...inc.rooms } };
          applyAll();
          save();
          render();
          flash(`${Object.keys(inc.rooms).length}개 방 설정을 가져왔습니다.`);
        } catch (err) {
          flash(`가져오기 실패: ${err.message}`);
        }
      }
    });

    sr.addEventListener('input', (e) => {
      const t = e.target;
      const scope = t.closest('[data-scope]')?.dataset.scope;
      if (scope && ['opacity', 'blur', 'veil'].includes(t.dataset.k)) patchBg(scope, { [t.dataset.k]: Number(t.value) });
      if (t.dataset.g === 'windowOpacity') {
        config.global.windowOpacity = Number(t.value);
        applyAll();
        save();
        render();
      }
    });

    render();
    positionPanel();
  };

  const closePanel = () => {
    host?.remove();
    host = null;
    sr = null;
  };
  const togglePanel = () => (host ? closePanel() : openPanel());

  // ---------------- wiring ----------------
  let timer = 0;
  const tick = () => {
    timer = 0;
    const ch = readChannel();
    if (ch.id !== channel.id || ch.name !== channel.name) {
      channel = ch;
      root.dataset.drbChannelId = ch.id;
      applyBg();
      render();
    }
    ensureSidebarButton();
  };
  new MutationObserver(() => {
    if (!timer) timer = setTimeout(tick, 150);
  }).observe(document.body, { childList: true, subtree: true, characterData: true });

  window.addEventListener('keydown', (e) => {
    if (e.altKey && e.shiftKey && !e.ctrlKey && !e.metaKey && e.code === 'KeyB') {
      e.preventDefault();
      togglePanel();
    }
    if (e.key === 'Escape' && host) closePanel();
  });
  window.addEventListener('resize', positionPanel);

  window.__drbSkin = { version: VERSION, toggle: togglePanel, get config() { return config; }, host: IS_DESKTOP ? 'desktop' : 'web' };

  load().then(() => {
    tick();
    applyAll();
  });
})();
