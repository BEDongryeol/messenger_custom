/*
 * Dooray Skin core (웹 Chrome 확장 + Dooray 데스크톱 앱 공용)
 * - 반드시 페이지 MAIN world 에서 실행 (React props 에서 channelId 를 읽기 때문)
 * - 저장소: IndexedDB 'dooray-skin' (origin 별). 창/탭 간 동기화는 BroadcastChannel.
 * - 데스크톱 앱에서는 launcher 가 window.__DRB_HOST = 'desktop' 을 먼저 설정하고 주입한다.
 *   창 투명도는 console.debug('__DRB__:{...}') 로 메인 프로세스 훅에 전달한다.
 * - 테마 색: 두레이 스타일시트의 파란 계열 색을 지정 색으로 옮긴 덮어쓰기 <style> 을 문서 끝에 둔다.
 */
(() => {
  if (window.__drbCore) return;
  window.__drbCore = true;

  const VERSION = '0.5.8';
  // 런처가 넣는 표식 + Electron 앱 자체 판별(이중 안전장치)
  const IS_DESKTOP =
    window.__DRB_HOST === 'desktop' || /Electron\//.test(navigator.userAgent) || !!window.macBridge || !!window.winBridge;
  const IS_WIN = /Windows/i.test(navigator.userAgent);
  // 업데이트 확인: 공개 저장소의 최신 GitHub Release (VERSION 이 올라간 main 커밋마다 Actions 가 만든다)
  const UPDATE_REPO = 'BEDongryeol/messenger_custom';
  // 1순위: GitHub Pages 의 latest.json (CDN 정적 파일, API 호출 한도 없음. Release 때마다 Actions 가 갱신)
  // 2순위: GitHub API (비로그인 IP 당 시간 60회 한도 → 같은 회사 IP 를 쓰면 막힐 수 있어 예비용)
  const UPDATE_MANIFEST = 'https://bedongryeol.github.io/messenger_custom/latest.json';
  const UPDATE_API = `https://api.github.com/repos/${UPDATE_REPO}/releases/latest`;
  const UPDATE_EVERY_MS = 60 * 60 * 1000; // 백그라운드 확인 주기
  const UPDATE_ON_OPEN_MS = 2 * 60 * 1000; // 패널을 열 때 마지막 확인이 이보다 오래됐으면 다시 확인
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
  // 테마 색: 두레이 메신저 기본 파랑(디자인 토큰 --color-background-service-messenger). 스타일시트에서 못 찾으면 이 값.
  const THEME_STYLE_ID = 'drb-theme';
  const THEME_BASE = '#1e84cc';
  const THEME_BASE_TOKEN = '--color-background-service-messenger';
  const THEME_HUE = [190, 250]; // 이 색상(hue) 범위 = 두레이가 쓰는 파란 계열. 보라(260~)/청록(~190) 은 제외
  const THEME_SAT_MIN = 0.25; // 채도가 낮은 푸른 회색(#9ca3af 등)은 제외
  const THEME_PRESETS = [
    ['Dooray 파랑', THEME_BASE],
    ['남보라', '#5b5bd6'],
    ['보라', '#8e44ad'],
    ['분홍', '#e04f8f'],
    ['빨강', '#e04343'],
    ['주황', '#f0862b'],
    ['초록', '#27a05f'],
    ['청록', '#0f9d9d'],
    ['회색', '#6b7280'],
  ];
  const isHex6 = (s) => /^#[0-9a-f]{6}$/i.test(s || '');
  // 다크 모드 배경 밝기(%): 흰색 배경이 이 명도로 바뀐다
  const DARK_LEVEL_DEFAULT = 11;
  const DARK_LEVEL_MIN = 4;
  const DARK_LEVEL_MAX = 22;

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

  const freshConfig = () => ({
    version: 2,
    global: {
      windowOpacity: 100,
      defaultBg: { ...BG_DEFAULTS, enabled: false },
      theme: { enabled: false, color: THEME_BASE },
      dark: { enabled: false, level: DARK_LEVEL_DEFAULT, titleBar: true, toast: true },
      hideMenu: false, // Windows 데스크톱: 상단 메뉴 바(파일·도구·보기…) 숨기기
    },
    rooms: {},
  });
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
        theme: {
          enabled: !!c.global?.theme?.enabled,
          color: isHex6(c.global?.theme?.color) ? c.global.theme.color.toLowerCase() : THEME_BASE,
        },
        dark: {
          enabled: !!c.global?.dark?.enabled,
          level: Math.max(DARK_LEVEL_MIN, Math.min(DARK_LEVEL_MAX, Number(c.global?.dark?.level) || DARK_LEVEL_DEFAULT)),
          titleBar: c.global?.dark?.titleBar !== false,
          toast: c.global?.dark?.toast !== false,
        },
        hideMenu: !!c.global?.hideMenu,
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
  background:rgba(${config.global.dark.enabled ? '0,0,0' : '255,255,255'},${Math.max(0, Math.min(90, c.veil)) / 100});}
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
  // 데스크톱 창 상태(투명도, 창 크롬 다크) 전달
  //  macOS: console 메시지를 메인 프로세스 훅이 받아 BrowserWindow.setOpacity / nativeTheme 적용
  //  Windows: 감시자(launch.ps1)가 window.__drbSkin.config 를 직접 읽어 Win32 로 적용 (메시지는 무시됨)
  let lastDesktopSent = '';
  // 창 안에 뜨는 이미지 확대 보기·이미지 편집 화면이 열려 있는 동안은 창을 불투명하게. 닫으면 원래 투명도로.
  // (창 투명도는 창 전체에 걸려 화면 일부만 불투명하게 할 수 없다. 파일·메일 미리보기는 별도 창이라 호스트가 처리)
  const VIEWER_SEL = ['IMAGE_PREVIEW', 'IMAGE_EDITOR'].map((t) => `[data-testid="${t}"]`).join(',');
  const imageViewerOpen = () => !!document.querySelector(VIEWER_SEL);
  const effectiveOpacity = () =>
    imageViewerOpen() ? 100 : Math.max(30, Math.min(100, Number(config.global.windowOpacity) || 100));
  const applyWindowOpacity = () => {
    if (!IS_DESKTOP) return;
    const v = effectiveOpacity();
    const msg = JSON.stringify({ windowOpacity: v / 100, dark: !!(config.global.dark.enabled && config.global.dark.titleBar) });
    if (msg === lastDesktopSent) return;
    lastDesktopSent = msg;
    console.debug('__DRB__:' + msg);
  };
  // ---------------- theme color (파란 계열 → 지정 색) ----------------
  // 두레이 CSS 는 디자인 토큰(--color-*)과 하드코딩 hex(#1e88e5, #125de6 ...)가 섞여 있어 변수만 바꿔서는 부족하다.
  // 모든 스타일시트(동일 출처)의 "색 관련 선언"을 원래 순서대로 복제하되, 파란 계열 색만 기준색→지정색으로
  // 색상(hue)·채도·명도를 옮겨 문서 맨 끝 <style> 로 덮어쓴다. 색 선언을 순서대로 전부 복제하므로
  // 원래 cascade(뒤 규칙·!important 가 이김)가 그대로 유지된다. styled-components 처럼 런타임에
  // insertRule 로 늘어나는 규칙은 주기적으로 규칙 수를 비교해 바뀐 시트만 다시 만든다.
  const COLOR_RE = /#(?:[0-9a-f]{8}|[0-9a-f]{6}|[0-9a-f]{3,4})\b|%23(?:[0-9a-f]{8}|[0-9a-f]{6}|[0-9a-f]{3,4})\b|\b(?:rgb|hsl)a?\(\s*[^()]*\)/gi;
  const COLOR_TEST = new RegExp(COLOR_RE.source, 'i');
  // 값에 색이 없어도(transparent, initial, none ...) cascade 유지를 위해 항상 복제하는 속성
  const COLOR_PROPS = new Set([
    'color', 'background-color', 'background-image', 'border-top-color', 'border-right-color', 'border-bottom-color',
    'border-left-color', 'border-block-start-color', 'border-block-end-color', 'border-inline-start-color',
    'border-inline-end-color', 'outline-color', 'fill', 'stroke', 'stop-color', 'flood-color', 'lighting-color',
    'box-shadow', 'text-shadow', 'text-decoration-color', 'text-emphasis-color', 'caret-color', 'column-rule-color',
    'accent-color', 'scrollbar-color', '-webkit-text-fill-color', '-webkit-text-stroke-color', '-webkit-tap-highlight-color',
  ]);
  const hex2 = (n) => n.toString(16).padStart(2, '0');
  // '#rgb' '#rrggbb(aa)' '%23rrggbb' 'rgb(a)(...)' 'hsl(a)(...)' → [r,g,b,a] | null
  const parseColor = (s) => {
    if (typeof s !== 'string') return null;
    s = s.trim();
    let m = s.match(/^(?:#|%23)([0-9a-f]{3,8})$/i);
    if (m) {
      let h = m[1];
      if (h.length === 3 || h.length === 4) h = [...h].map((c) => c + c).join('');
      if (h.length !== 6 && h.length !== 8) return null;
      const n = parseInt(h, 16);
      return h.length === 8
        ? [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, (n & 255) / 255]
        : [(n >> 16) & 255, (n >> 8) & 255, n & 255, 1];
    }
    m = s.match(/^(rgb|hsl)a?\(\s*([^()]*)\)$/i);
    if (!m) return null;
    const parts = m[2].trim().split(/\s*[,/]\s*|\s+/).filter(Boolean);
    if (parts.length < 3 || parts.length > 4) return null;
    const num = (x, max) => (x.endsWith('%') ? (parseFloat(x) / 100) * max : parseFloat(x));
    const a = parts.length === 4 ? num(parts[3], 1) : 1;
    let rgb;
    if (m[1].toLowerCase() === 'rgb') rgb = parts.slice(0, 3).map((p) => Math.round(Math.max(0, Math.min(255, num(p, 255)))));
    else rgb = hslToRgb(parseFloat(parts[0]), num(parts[1], 1), num(parts[2], 1));
    if (rgb.some(isNaN) || isNaN(a)) return null;
    return [...rgb, Math.max(0, Math.min(1, a))];
  };
  const rgbToHsl = ([r, g, b]) => {
    r /= 255; g /= 255; b /= 255;
    const mx = Math.max(r, g, b), mn = Math.min(r, g, b), l = (mx + mn) / 2, d = mx - mn;
    let h = 0, s = 0;
    if (d) {
      s = d / (1 - Math.abs(2 * l - 1));
      h = mx === r ? ((g - b) / d) % 6 : mx === g ? (b - r) / d + 2 : (r - g) / d + 4;
      h = (h * 60 + 360) % 360;
    }
    return { h, s, l };
  };
  const hslToRgb = (h, s, l) => {
    s = Math.max(0, Math.min(1, s)); l = Math.max(0, Math.min(1, l));
    const f = (n) => {
      const k = (n + h / 30) % 12;
      const a = s * Math.min(l, 1 - l);
      return Math.round(255 * (l - a * Math.max(-1, Math.min(k - 3, 9 - k, 1))));
    };
    return [f(0), f(8), f(4)];
  };
  const fmtColor = ([r, g, b, a], style) => {
    if (style === 'func') return a < 1 ? `rgba(${r}, ${g}, ${b}, ${+a.toFixed(3)})` : `rgb(${r}, ${g}, ${b})`;
    return (style === 'pct' ? '%23' : '#') + hex2(r) + hex2(g) + hex2(b) + (a < 1 ? hex2(Math.round(a * 255)) : '');
  };
  const inFamily = ({ h, s }) => s >= THEME_SAT_MIN && h >= THEME_HUE[0] && h <= THEME_HUE[1];
  // 기준색(base)→지정색(target) 의 색상 차이만큼 돌리고, 채도는 비율로, 명도는 base.l↔target.l 을 기준점으로 양쪽을 선형 보간
  // (밝은 틴트는 밝게, 어두운 톤은 어둡게 유지된다)
  const shiftColor = (rgba, base, target) => {
    const c = rgbToHsl(rgba);
    if (!inFamily(c)) return null;
    const h = (c.h + target.h - base.h + 360) % 360;
    const s = base.s ? c.s * (target.s / base.s) : c.s;
    const l = c.l <= base.l ? (target.l * c.l) / base.l : target.l + ((c.l - base.l) * (1 - target.l)) / (1 - base.l);
    return [...hslToRgb(h, s, l), rgba[3]];
  };
  let themeBaseHex = ''; // 원본 스타일시트의 :root 토큰에서 찾은 기본 파랑 (덮어쓴 값이 아니라 원본을 읽어야 함)
  const ownSheet = (sh) => !!sh.ownerNode?.id?.startsWith('drb-');
  const detectThemeBase = () => {
    if (themeBaseHex) return themeBaseHex;
    for (const sh of document.styleSheets) {
      if (ownSheet(sh)) continue;
      try {
        for (const r of sh.cssRules) {
          if (!(r instanceof CSSStyleRule) || r.selectorText !== ':root') continue;
          const c = parseColor(r.style.getPropertyValue(THEME_BASE_TOKEN));
          if (c) return (themeBaseHex = fmtColor([c[0], c[1], c[2], 1], 'hex'));
        }
      } catch {}
    }
    return THEME_BASE;
  };
  // 복제한 선언이 문서 위치에서 해석되므로 시트 기준 상대 url() 은 절대 경로로 바꾼다
  const URL_RE = /url\(\s*(['"]?)([^'")]+)\1\s*\)/gi;
  const absUrls = (v, href) =>
    href && v.includes('url(')
      ? v.replace(URL_RE, (m, q, u) => {
          if (/^(data:|blob:|https?:|\/\/|#)/i.test(u)) return m;
          try { return `url(${q}${new URL(u, href).href}${q})`; } catch { return m; }
        })
      : v;
  // ---------------- dark mode ----------------
  // Dark Reader 방식. 두레이에는 전역 다크 테마가 없고(메시지 본문용 .dooray-flavored-html-dark-mode 뿐) 색이 대부분
  // 하드코딩이라, 아래 복제 엔진에서 모든 색을 "역할"별로 변환한다.
  //  bg: 밝을수록 어둡게(흰색이 가장 어둡게), 어두운 배경·채도 있는 배경(버튼)은 유지
  //  fg: 어두운 글자는 밝게, 밝은 글자(버튼 위 흰 글자)는 유지, 색 있는 글자(링크)는 살짝 밝게
  //  border/shadow: 밝은 선은 어두운 선으로, 어두운 그림자는 유지
  //  CSS 변수: var(--x) 가 어떤 속성에서 쓰이는지 추적해 역할을 정하고, 못 찾으면 이름·명도로 추정
  //  이미지: 투명 배경 + 어두운 그림(아이콘 스프라이트)은 캔버스로 명도를 뒤집은 blob URL 로 교체
  const scale = (x, a, b, c, d) => c + ((Math.max(a, Math.min(b, x)) - a) / (b - a)) * (d - c);
  const ROLE_OF = {
    color: 'fg', fill: 'fg', stroke: 'fg', 'stop-color': 'fg', 'flood-color': 'fg', 'lighting-color': 'fg', 'caret-color': 'fg',
    'text-decoration-color': 'fg', 'text-emphasis-color': 'fg', '-webkit-text-fill-color': 'fg', '-webkit-text-stroke-color': 'fg',
    'background-color': 'bg', 'background-image': 'bg', 'outline-color': 'border', 'column-rule-color': 'border',
    'box-shadow': 'shadow', 'text-shadow': 'shadow', 'accent-color': 'keep', 'scrollbar-color': 'keep', '-webkit-tap-highlight-color': 'keep',
  };
  const roleOfProp = (p) => ROLE_OF[p] || (p.startsWith('border') && p.endsWith('-color') ? 'border' : 'shadow');
  const guessVarRole = (name) =>
    /background|bg|surface|fill/i.test(name) ? 'bg'
    : /content|text|fg|foreground|font|link/i.test(name) ? 'fg'
    : /border|line|divider|outline|stroke/i.test(name) ? 'border'
    : /shadow/i.test(name) ? 'shadow'
    : 'auto';
  const DARK_FG = 0.88;
  const darkMap = (rgba, role, dark) => {
    if (role === 'keep' || rgba[3] === 0) return null;
    const { h, s, l } = rgbToHsl(rgba);
    const neutral = s < 0.12;
    if (role === 'auto') role = l >= 0.7 ? 'bg' : l <= 0.35 ? 'fg' : 'keep';
    else if (role === 'both') role = neutral && l >= 0.6 ? 'bg' : 'fg';
    let ns = s, nl;
    if (role === 'bg') {
      if (l >= 0.5) nl = scale(l, 0.5, 1, 0.4, dark.bg);
      else if (neutral) nl = scale(l, 0, 0.5, 0, 0.4);
      else return null;
      if (neutral) ns = 0;
    } else if (role === 'fg') {
      if (neutral || l < 0.2) nl = l < 0.5 ? scale(l, 0, 0.5, DARK_FG, 0.62) : scale(l, 0.5, 1, 0.62, 0.92);
      else if (l < 0.5) nl = scale(l, 0, 0.5, 0.55, 0.62);
      else return null;
    } else if (role === 'border') {
      if (l >= 0.5) nl = scale(l, 0.5, 1, 0.45, 0.22);
      else if (neutral) nl = scale(l, 0, 0.5, 0.3, 0.45);
      else return null;
    } else if (role === 'shadow') {
      if (l >= 0.5 && neutral) nl = scale(l, 0.5, 1, 0.45, 0.22);
      else return null;
    } else return null;
    return [...hslToRgb(h, ns, nl), rgba[3]];
  };
  const transformColor = (rgba, role, ctx) => {
    let c = rgba, changed = false;
    if (ctx.theme) {
      const t = shiftColor(c, ctx.theme.base, ctx.theme.target);
      if (t) { c = t; changed = true; }
    }
    if (ctx.dark) {
      const d = darkMap(c, role, ctx.dark);
      if (d) { c = d; changed = true; }
    }
    return changed ? c : null;
  };
  const recolorValue = (v, ctx, role = 'auto') =>
    v.replace(COLOR_RE, (m) => {
      const key = role + '|' + m.toLowerCase();
      if (ctx.memo.has(key)) return ctx.memo.get(key) ?? m;
      const rgba = parseColor(m);
      const out = rgba && transformColor(rgba, role, ctx);
      const res = out ? fmtColor(out, m[0] === '%' ? 'pct' : m[0] === '#' ? 'hex' : 'func') : null;
      ctx.memo.set(key, res);
      return res ?? m;
    });

  // CSS 변수 역할 추적: color:var(--a) → a=fg, --a:var(--b) → b 도 a 의 역할
  const VAR_RE = /var\(\s*(--[\w-]+)/g;
  const varUseCache = new WeakMap(); // sheet → { n, uses: Map<var, Set<role>>, refs: Map<var, Set<var>> }
  const collectVarUses = (rules, uses, refs) => {
    const add = (map, k, v) => (map.get(k) || map.set(k, new Set()).get(k)).add(v);
    for (const r of rules) {
      if (r instanceof CSSStyleRule) {
        const st = r.style;
        for (let i = 0; i < st.length; i++) {
          const p = st[i];
          const v = st.getPropertyValue(p);
          if (!v.includes('var(')) continue;
          const isVar = p.startsWith('--');
          if (!isVar && !COLOR_PROPS.has(p)) continue;
          for (const m of v.matchAll(VAR_RE)) isVar ? add(refs, p, m[1]) : add(uses, m[1], roleOfProp(p));
        }
        if (r.cssRules?.length) collectVarUses(r.cssRules, uses, refs);
      } else if (r instanceof CSSGroupingRule) collectVarUses(r.cssRules, uses, refs);
    }
  };
  const computeVarRoles = () => {
    const uses = new Map(), refs = new Map();
    const merge = (dst, src) => {
      for (const [k, set] of src) {
        const d = dst.get(k) || dst.set(k, new Set()).get(k);
        for (const x of set) d.add(x);
      }
    };
    for (const sh of document.styleSheets) {
      if (ownSheet(sh)) continue;
      let n;
      try { n = sh.cssRules.length; } catch { continue; }
      let c = varUseCache.get(sh);
      if (!c || c.n !== n) {
        c = { n, uses: new Map(), refs: new Map() };
        try { collectVarUses(sh.cssRules, c.uses, c.refs); } catch {}
        varUseCache.set(sh, c);
      }
      merge(uses, c.uses);
      merge(refs, c.refs);
    }
    for (let iter = 0, changed = true; iter < 6 && changed; iter++) {
      changed = false;
      for (const [a, bs] of refs) {
        const ra = uses.get(a);
        if (!ra) continue;
        for (const b of bs) {
          const rb = uses.get(b) || uses.set(b, new Set()).get(b);
          for (const x of ra) if (!rb.has(x)) { rb.add(x); changed = true; }
        }
      }
    }
    const roles = new Map();
    // 배경과 글자 양쪽에 쓰이는 변수는 'both' → 값의 명도를 보고 결정(밝은 무채색이면 배경, 아니면 글자)
    for (const [name, set] of uses)
      roles.set(name, set.has('bg') && set.has('fg') ? 'both' : set.has('bg') ? 'bg' : set.has('fg') ? 'fg' : set.has('border') ? 'border' : [...set][0]);
    let hash = 0;
    for (const [k, v] of roles) for (const ch of k + v) hash = (hash * 31 + ch.charCodeAt(0)) | 0;
    return { roles, key: roles.size + ':' + hash };
  };

  // 어두운 아이콘 이미지 반전 (투명 배경 + 어두운 그림일 때만). 결과는 URL 별로 캐시
  const imgCache = new Map(); // url → { done, out }
  let imgEpoch = 0;
  const analyzeImage = (url) => {
    let e = imgCache.get(url);
    if (e) return e;
    e = { done: false, out: null };
    imgCache.set(url, e);
    const im = new Image();
    im.crossOrigin = 'anonymous';
    const finish = () => {
      e.done = true;
      imgEpoch++;
      scheduleTheme();
    };
    im.onload = () => {
      try {
        const w = im.naturalWidth, h = im.naturalHeight;
        if (w && h && w * h <= 3e6) {
          const c = document.createElement('canvas');
          c.width = w;
          c.height = h;
          const g = c.getContext('2d', { willReadFrequently: true });
          g.drawImage(im, 0, 0);
          const d = g.getImageData(0, 0, w, h);
          const px = d.data;
          const step = Math.max(1, Math.floor((w * h) / 20000)) * 4;
          let sampled = 0, opaque = 0, lum = 0, darkNeutral = 0;
          for (let i = 0; i < px.length; i += step) {
            sampled++;
            if (px[i + 3] > 12) {
              opaque++;
              const L = (0.2126 * px[i] + 0.7152 * px[i + 1] + 0.0722 * px[i + 2]) / 255;
              lum += L;
              if (L < 0.55 && Math.max(px[i], px[i + 1], px[i + 2]) - Math.min(px[i], px[i + 1], px[i + 2]) < 24) darkNeutral++;
            }
          }
          const transparent = 1 - opaque / sampled;
          const avg = opaque ? lum / opaque : 1;
          // 전체가 어두운 아이콘 이미지 → 전체 명도 반전
          const mostlyDark = transparent > 0.15 && avg < 0.5;
          // 회색·컴러·흰 아이콘이 섞인 스프라이트(예: 메시지 호버 도구 막대) → 어두운 무채색 픽셀만 밝게
          const mixedSprite = !mostlyDark && transparent > 0.15 && opaque && darkNeutral / opaque > 0.08;
          if (mostlyDark || mixedSprite) {
            for (let i = 0; i < px.length; i += 4) {
              if (!px[i + 3]) continue;
              const r = px[i], gg = px[i + 1], b = px[i + 2];
              const neutral = Math.max(r, gg, b) - Math.min(r, gg, b) < (mostlyDark ? 16 : 24);
              if (mixedSprite) {
                if (!neutral) continue;
                const L = (0.2126 * r + 0.7152 * gg + 0.0722 * b) / 255;
                if (L >= 0.55) continue;
                const v = Math.round(255 * Math.min(0.9, Math.max(0.68, 1 - L)));
                px[i] = px[i + 1] = px[i + 2] = v;
                continue;
              }
              if (neutral) { px[i] = 255 - r; px[i + 1] = 255 - gg; px[i + 2] = 255 - b; continue; }
              const { h: hh, s, l } = rgbToHsl([r, gg, b]);
              const o = hslToRgb(hh, s, 1 - l);
              px[i] = o[0]; px[i + 1] = o[1]; px[i + 2] = o[2];
            }
            g.putImageData(d, 0, 0);
            // data URL 은 스프라이트가 크면 스타일 텍스트가 수 MB 가 되므로 blob URL 로 넣는다
            c.toBlob((blob) => {
              if (blob) e.out = URL.createObjectURL(blob);
              finish();
            }, 'image/png');
            return;
          }
        }
      } catch {}
      finish();
    };
    im.onerror = () => { e.done = true; };
    im.src = url;
    return e;
  };
  const darkImages = (v) =>
    v.includes('url(') && !v.includes('gradient')
      ? v.replace(URL_RE, (m, q, u) => {
          if (/^(blob:|#)/.test(u)) return m;
          const e = analyzeImage(u);
          return e.done && e.out ? `url("${e.out}")` : m;
        })
      : v;

  const emitRules = (rules, ctx, out) => {
    for (const r of rules) {
      if (r instanceof CSSStyleRule) {
        const st = r.style;
        const decl = [];
        for (let i = 0; i < st.length; i++) {
          const p = st[i];
          const v = st.getPropertyValue(p);
          const isVar = p.startsWith('--');
          if (!(isVar || COLOR_PROPS.has(p) || COLOR_TEST.test(v))) continue;
          const role = isVar ? ctx.varRoles.get(p) || guessVarRole(p) : roleOfProp(p);
          let nv = absUrls(recolorValue(v, ctx, role), ctx.href);
          if (ctx.dark && (p === 'background-image' || isVar) && nv.includes('url(')) nv = darkImages(nv);
          decl.push(`${p}:${nv}${st.getPropertyPriority(p) ? ' !important' : ''}`);
        }
        const kids = [];
        if (r.cssRules?.length) emitRules(r.cssRules, ctx, kids); // CSS nesting
        if (decl.length || kids.length) out.push(`${r.selectorText}{${decl.join(';')};${kids.join('')}}`);
      } else if (r instanceof CSSKeyframesRule) {
        const t = r.cssText;
        const nt = recolorValue(t, ctx, 'auto');
        if (nt !== t) out.push(nt); // 같은 이름의 @keyframes 를 뒤에 다시 정의하면 그것이 쓰인다
      } else if (r instanceof CSSImportRule) {
        const kids = [];
        const href = ctx.href;
        try {
          ctx.href = r.styleSheet.href || href;
          emitRules(r.styleSheet.cssRules, ctx, kids);
        } catch {}
        ctx.href = href;
        if (kids.length) out.push(r.media?.mediaText ? `@media ${r.media.mediaText}{${kids.join('')}}` : kids.join(''));
      } else if (r instanceof CSSGroupingRule) {
        const head =
          r instanceof CSSMediaRule ? `@media ${r.conditionText}`
          : r instanceof CSSSupportsRule ? `@supports ${r.conditionText}`
          : window.CSSContainerRule && r instanceof CSSContainerRule ? `@container ${r.conditionText}`
          : window.CSSLayerBlockRule && r instanceof CSSLayerBlockRule ? `@layer ${r.name}`
          : '';
        if (!head) continue;
        const kids = [];
        emitRules(r.cssRules, ctx, kids);
        if (kids.length) out.push(`${head}{${kids.join('')}}`);
      }
    }
  };
  const themeCache = new WeakMap(); // sheet → { n(규칙 수), key, text }
  let themeCtx = null;
  // theme: { base, target } | null, dark: { bg } | null
  const buildSkin = (theme, dark) => {
    const colorKey = `${theme ? theme.base + '>' + theme.target : ''}|${dark ? dark.bg : ''}`;
    if (!themeCtx || themeCtx.colorKey !== colorKey) {
      let th = null;
      if (theme) {
        const base = rgbToHsl(parseColor(theme.base));
        base.l = Math.max(0.05, Math.min(0.95, base.l));
        th = { base, target: rgbToHsl(parseColor(theme.target)) };
      }
      themeCtx = { colorKey, theme: th, dark, memo: new Map(), varRoles: new Map() };
    }
    let rolesKey = '';
    if (dark) {
      const vr = computeVarRoles();
      themeCtx.varRoles = vr.roles;
      rolesKey = vr.key;
    }
    const key = `${colorKey}|${rolesKey}|${dark ? imgEpoch : ''}`;
    const parts = [];
    for (const sh of document.styleSheets) {
      if (ownSheet(sh)) continue;
      let n;
      try { n = sh.cssRules.length; } catch { continue; } // 다른 출처(CORS) 시트는 읽을 수 없음
      let c = themeCache.get(sh);
      if (!c || c.n !== n || c.key !== key) {
        const out = [];
        themeCtx.href = sh.href || location.href;
        try { emitRules(sh.cssRules, themeCtx, out); } catch (e) { console.warn('[dooray-skin] skin build failed', e); }
        c = { n, key, text: out.join('\n') };
        themeCache.set(sh, c);
      }
      if (c.text) parts.push(c.text);
    }
    return parts.join('\n');
  };
  let themeWatch = 0;
  let themeTimer = 0;
  const applyTheme = () => {
    const t = config.global.theme;
    const d = config.global.dark;
    const base = detectThemeBase();
    let st = document.getElementById(THEME_STYLE_ID);
    const themeOn = t.enabled && isHex6(t.color) && t.color.toLowerCase() !== base.toLowerCase();
    const darkOn = !!d.enabled;
    if (!themeOn && !darkOn) {
      st?.remove();
      clearInterval(themeWatch);
      themeWatch = 0;
      return;
    }
    const text =
      (darkOn ? 'html{color-scheme:dark}\n' : '') +
      buildSkin(themeOn ? { base, target: t.color.toLowerCase() } : null, darkOn ? { bg: d.level / 100 } : null);
    if (!st) {
      st = document.createElement('style');
      st.id = THEME_STYLE_ID;
    }
    if (st.textContent !== text) st.textContent = text;
    // 항상 문서 맨 끝(<html> 의 마지막 자식)에 두어 나중에 추가되는 <style>/<link> 보다 뒤에서 적용되게 한다
    const parent = document.body ? root : document.head;
    let after = st.nextElementSibling;
    while (after && !/^(style|link)$/i.test(after.tagName)) after = after.nextElementSibling;
    if (st.parentNode !== parent || after) parent.appendChild(st);
    if (!themeWatch) themeWatch = setInterval(applyTheme, 1500); // 런타임에 추가되는 규칙(styled-components 등) 반영
  };
  const scheduleTheme = () => {
    clearTimeout(themeTimer);
    themeTimer = setTimeout(() => {
      themeTimer = 0;
      applyTheme();
    }, 80);
  };
  new MutationObserver(() => themeWatch && scheduleTheme()).observe(document.head, { childList: true });

  const applyAll = () => {
    applyBg();
    applyWindowOpacity();
    applyTheme();
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
    if (existing?.isConnected) {
      if (existing.disabled) existing.disabled = false; // 이후 리렌더로 비활성이 되더라도 되돌린다
      return;
    }
    const last = findBtn(ANCHOR_LAST);
    const first = findBtn(ANCHOR_FIRST);
    if (!last || !first) return;
    let item = last;
    while (item.parentElement && !item.parentElement.contains(first)) item = item.parentElement;
    if (!item.parentElement) return;
    const clone = item.cloneNode(true);
    clone.setAttribute('data-drb-sidebar-item', '1');
    const btn = clone.querySelector('button') || clone;
    btn.setAttribute('aria-label', 'Dooray Skin 설정');
    btn.setAttribute('title', '대화방 배경 · 테마 색 설정 (Alt+Shift+B)');
    btn.setAttribute('data-drb-sidebar-btn', '1');
    // 원본(링크 모아보기)이 방에 따라 비활성인 채 복제되면 우리 버튼도 눌리지 않으므로 항상 활성화
    btn.disabled = false;
    btn.removeAttribute('aria-disabled');
    btn.removeAttribute('tabindex');
    const svg = btn.querySelector('svg');
    if (svg) svg.outerHTML = ICON;
    btn.addEventListener('click', (e) => {
      e.preventDefault();
      e.stopPropagation();
      togglePanel();
    });
    item.after(clone);
    if (update) markUpdate();
  };

  // ---------------- update ----------------
  // 새 Release 가 있으면 패널 맨 위 알림 + 사이드바 버튼 빨간 점. [업데이트] 를 누르면
  //  macOS 앱  : 메인 프로세스 훅(launcher.js)이 zip 을 받아 새 Dooray Skin.app 실행 → 자기 설치 후 Dooray 재시작
  //  Windows 앱: 감시자(launch.ps1)가 window.__drbUpdateRequest 를 읽어 Setup 을 받아 실행 → 덮어쓰기 설치 후 재시작
  //  웹 확장   : 자동 설치 불가(Chrome 정책) → 릴리스 페이지 안내
  let update = null; // { version, page, mac, winExe, winCmd, chrome }
  let updateBusy = false;
  let updateDismissed = false;
  const verParts = (v) => String(v || '').replace(/^v/, '').split('.').map((n) => parseInt(n, 10) || 0);
  const isNewer = (a, b) => {
    const x = verParts(a);
    const y = verParts(b);
    for (let i = 0; i < Math.max(x.length, y.length); i++) if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) > (y[i] || 0);
    return false;
  };
  const markUpdate = () => {
    const b = document.querySelector('[data-drb-sidebar-btn]');
    if (b) {
      let d = b.querySelector('[data-drb-dot]');
      if (update && !d) {
        d = document.createElement('span');
        d.setAttribute('data-drb-dot', '1');
        d.style.cssText = 'position:absolute;top:2px;right:2px;width:8px;height:8px;border-radius:50%;background:#e5484d;pointer-events:none';
        if (!b.style.position) b.style.position = 'relative';
        b.appendChild(d);
        b.setAttribute('title', `새 버전 v${update.version} 이 있습니다 · Dooray Skin (Alt+Shift+B)`);
      } else if (!update && d) d.remove();
    }
    render();
  };
  const fetchLatestInfo = async () => {
    try {
      const r = await fetch(UPDATE_MANIFEST, { cache: 'no-store' });
      if (r.ok) {
        const m = await r.json();
        if (m && m.version) return { version: String(m.version).replace(/^v/, ''), page: m.page, mac: m.mac, winExe: m.winExe, winCmd: m.winCmd, chrome: m.chrome };
      }
    } catch {}
    const r = await fetch(UPDATE_API, { headers: { Accept: 'application/vnd.github+json' }, cache: 'no-store' });
    if (!r.ok) return null;
    const rel = await r.json();
    const a = Object.fromEntries((rel.assets || []).map((x) => [x.name, x.browser_download_url]));
    return {
      version: String(rel.tag_name || '').replace(/^v/, ''),
      page: rel.html_url,
      mac: a['DooraySkin-mac.zip'],
      winExe: a['DooraySkin-Setup.exe'],
      winCmd: a['DooraySkin-Setup.cmd'],
      chrome: a['DooraySkin-chrome-extension.zip'],
    };
  };
  // maxAge: 마지막 확인이 이보다 최근이면 네트워크 없이 캐시 사용 (같은 PC 의 여러 창·탭이 localStorage 로 공유)
  const checkUpdate = async (force = false, maxAge = UPDATE_EVERY_MS) => {
    try {
      const last = Number(localStorage.getItem('drb-update-checked') || 0);
      if (!force && Date.now() - last < maxAge) {
        const cached = JSON.parse(localStorage.getItem('drb-update-info') || 'null');
        update = cached && isNewer(cached.version, VERSION) ? cached : null;
        return markUpdate();
      }
      localStorage.setItem('drb-update-checked', String(Date.now()));
      const info = await fetchLatestInfo();
      if (!info || !info.version) return;
      localStorage.setItem('drb-update-info', JSON.stringify(info));
      update = isNewer(info.version, VERSION) ? info : null;
      markUpdate();
    } catch (e) {
      console.warn('[dooray-skin] update check failed', e);
    }
  };
  const startUpdate = () => {
    if (!update || updateBusy) return;
    if (IS_DESKTOP && !IS_WIN) {
      if (!update.mac) return flash('이 릴리스에 Mac 설치 파일이 없습니다. 릴리스 페이지에서 받아 주세요.');
      updateBusy = true;
      console.debug('__DRB__:' + JSON.stringify({ update: { url: update.mac, version: update.version } }));
    } else if (IS_DESKTOP && IS_WIN) {
      const url = update.winExe || update.winCmd;
      if (!url) return flash('이 릴리스에 Windows 설치 파일이 없습니다. 릴리스 페이지에서 받아 주세요.');
      updateBusy = true;
      window.__drbUpdateRequest = { url, version: update.version };
    } else {
      window.open(update.page, '_blank', 'noopener');
      return flash('릴리스 페이지에서 DooraySkin-chrome-extension.zip 을 받아 기존 폴더에 덮어쓴 뒤, 확장 프로그램 화면에서 새로고침(↻) 하세요.');
    }
    render();
  };
  // 런처/감시자가 업데이트에 실패하면 호출한다
  const updateFailed = (msg) => {
    updateBusy = false;
    window.__drbUpdateRequest = null;
    render();
    flash(`업데이트 실패: ${msg || '알 수 없는 오류'}. 릴리스 페이지에서 직접 받아 주세요.`);
  };

  // ---------------- panel ----------------
  let host = null;
  let sr = null;
  let tab = 'room';

  const PANEL_CSS = `
:host{all:initial}
.p{--accent:#2f6fed;--bg:#fff;--fg:#222;--bd:#ccc;--bd2:#eee;--mut:#888;--sub:#666;--btn:#f7f7f7;--win:#f3f6ff;--inp:#fff;
 position:fixed;z-index:2147483000;width:328px;max-height:calc(100vh - 32px);overflow:auto;box-sizing:border-box;
 background:var(--bg);color:var(--fg);border:1px solid var(--bd2);border-radius:12px;box-shadow:0 8px 28px rgba(0,0,0,.18);
 font:13px/1.45 -apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo","Malgun Gothic",sans-serif;padding:14px 16px;color-scheme:light}
.p.dark{--bg:#1f2123;--fg:#e4e4e4;--bd:#4a4d50;--bd2:#33363a;--mut:#9a9a9a;--sub:#b8b8b8;--btn:#2b2e31;--win:#272b33;--inp:#17191b;color-scheme:dark}
h1{font-size:14px;margin:0 0 8px;display:flex;justify-content:space-between;align-items:center}
.tabs{display:flex;gap:4px;margin:0 0 10px;border-bottom:1px solid var(--bd2)}
.tabs button{border:none;background:none;border-bottom:2px solid transparent;border-radius:0;padding:6px 10px;color:var(--sub)}
.tabs button.on{border-bottom-color:var(--accent);color:var(--accent);font-weight:600}
.sub{color:var(--sub);margin:0 0 10px;word-break:break-all}
.win{background:var(--win);border-radius:8px;padding:8px 10px;margin:0 0 10px}
.win .muted{margin:2px 0 0}
.row{margin:10px 0}
label.t{display:block;font-weight:600;margin-bottom:4px}
input[type=range]{width:100%}
input[type=range],input[type=checkbox]{accent-color:var(--accent)}
input[type=text],select{width:100%;box-sizing:border-box;padding:6px 8px;border:1px solid var(--bd);border-radius:6px;font:inherit;background:var(--inp);color:var(--fg)}
.btns{display:flex;gap:6px;flex-wrap:wrap;align-items:center}
.nowrap{flex-wrap:nowrap}
button{font:inherit;white-space:nowrap;padding:6px 10px;border:1px solid var(--bd);border-radius:6px;background:var(--btn);cursor:pointer;color:var(--fg)}
button.primary{background:var(--accent);color:#fff;border-color:var(--accent)}
button.danger{color:#e05252}
button.x{border:none;background:none;font-size:18px;padding:0 4px;color:var(--mut)}
.chk{display:flex;align-items:center;gap:4px}
input[type=color]{width:46px;height:32px;padding:2px;border:1px solid var(--bd);border-radius:6px;background:var(--inp);cursor:pointer;flex:none}
input.hex{width:88px;flex:none;font-family:ui-monospace,Consolas,monospace}
button.eye{display:inline-flex;align-items:center;gap:4px}
button.eye svg{width:14px;height:14px}
.swatches{display:flex;gap:7px;flex-wrap:wrap;margin-top:8px}
.swatches button{width:24px;height:24px;padding:0;border-radius:50%;border:2px solid var(--bg);box-shadow:0 0 0 1px var(--bd)}
.swatches button.on{box-shadow:0 0 0 2px var(--fg)}
.sample{display:flex;gap:8px;align-items:center;margin:10px 0 2px;font-size:12px}
.sample .sbtn{background:var(--accent);color:#fff;padding:4px 10px;border-radius:6px}
.sample .slink{color:var(--accent);text-decoration:underline}
.sample .stint{background:color-mix(in srgb,var(--accent) 14%,var(--bg));color:var(--accent);padding:4px 8px;border-radius:6px}
.preview{height:80px;border:1px dashed var(--bd);border-radius:8px;background:var(--btn) center/cover no-repeat;margin-top:6px}
.list{margin:0;padding:0;list-style:none}
.list li{display:flex;justify-content:space-between;align-items:center;padding:4px 0;border-bottom:1px solid var(--bd2)}
.list li span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:220px}
.muted{color:var(--mut);font-size:12px;margin:4px 0}
hr{border:none;border-top:1px solid var(--bd2);margin:12px 0}
.msg{color:var(--accent);font-size:12px;min-height:16px;margin:6px 0 0}
.upd{background:color-mix(in srgb,var(--accent) 12%,var(--bg));border:1px solid var(--accent);border-radius:8px;padding:8px 10px;margin:0 0 10px}
.upd .btns{margin-top:6px}
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
  <div class="row"><label class="t">가림막(가독성, 다크 모드에선 검정) <span data-v="veil"></span></label><input type="range" min="0" max="90" data-k="veil"></div>
</div>`;

  const PANEL_HTML = `
<style>${PANEL_CSS}</style>
<div class="p" data-ref="p">
  <h1>Dooray Skin <button class="x" data-act="close" title="닫기">×</button></h1>
  <div class="upd" data-ref="upd" hidden>
    <div data-ref="updText"></div>
    <div class="btns"><button class="primary" data-act="update">업데이트</button><button data-act="updLater">나중에</button></div>
  </div>
  <div class="row win" data-ref="winRow">
    <label class="t">두레이 창 투명도 <span data-v="windowOpacity"></span></label>
    <input type="range" min="30" max="100" data-g="windowOpacity">
    <p class="muted" data-ref="winNote"></p>
    <label class="chk" data-ref="menuRow" style="margin-top:6px"><input type="checkbox" data-g="hideMenu"> 상단 메뉴 바(파일·도구·보기…) 숨기기</label>
  </div>
  <div class="tabs">
    <button data-tab="room">이 방</button>
    <button data-tab="global">전체(Global)</button>
    <button data-tab="theme">테마</button>
  </div>
  <section data-pane="theme" hidden>
    <div class="row win">
      <label class="chk"><input type="checkbox" data-d="enabled"> <b>다크 모드</b></label>
      <label class="chk" data-ref="titleRow" style="margin-top:4px"><input type="checkbox" data-d="titleBar"> 창 제목 표시줄도 어둡게</label>
      <label class="chk" data-ref="toastRow" style="margin-top:4px"><input type="checkbox" data-d="toast"> 새 메시지 알림창도 어둡게 (Windows 앱)</label>
      <label class="t" style="margin-top:8px">배경 밝기 <span data-v="darkLevel"></span></label>
      <input type="range" min="${DARK_LEVEL_MIN}" max="${DARK_LEVEL_MAX}" data-d="level">
      <p class="muted">흰색·회색 배경은 어둡게, 글자는 밝게, 버튼·링크 색은 유지합니다. 어두운 아이콘 이미지는 자동으로 반전됩니다.</p>
    </div>
    <label class="t">테마 색</label>
    <div class="row btns">
      <label class="chk"><input type="checkbox" data-t="enabled"> 테마 색 사용</label>
      <button data-act="themeReset" style="margin-left:auto">기본 파랑으로</button>
    </div>
    <div class="row">
      <label class="t">색 고르기</label>
      <div class="btns nowrap">
        <input type="color" data-t="picker" title="색 선택 창">
        <input type="text" class="hex" data-t="hex" placeholder="#1e84cc" maxlength="7" spellcheck="false" title="#rrggbb">
        <button class="eye" data-act="eyedrop" title="화면 어디든 클릭해 그 색을 가져옵니다"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m2 22 1-1h3l9-9"/><path d="M3 21v-3l9-9"/><path d="m15 6 3.4-3.4a2.1 2.1 0 1 1 3 3L18 9l.4.4a2.1 2.1 0 1 1-3 3l-3.8-3.8a2.1 2.1 0 1 1 3-3l.4.4Z"/></svg>스포이드</button>
      </div>
      <div class="swatches">${THEME_PRESETS.map(([n, c]) => `<button data-swatch="${c}" title="${n} ${c}" style="background:${c}"></button>`).join('')}</div>
      <div class="sample"><span class="sbtn">버튼</span><span class="slink">링크</span><span class="stint">선택 강조</span></div>
      <p class="muted" data-ref="themeState"></p>
    </div>
    <p class="muted">두레이 화면의 파란 계열(버튼, 링크, 탭 밑줄, 선택 강조, 배지 등)을 이 색 기준으로 바꿉니다. 밝기 차이는 그대로 유지되고, 이미지로 된 로고·아이콘은 바뀌지 않습니다.</p>
  </section>
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
    <p class="muted">방 키가 channelId 라서 같은 방이면 팀원끼리 JSON 공유 시 그대로 적용됩니다.</p>
    <div class="btns"><span class="muted">현재 v${VERSION}</span><button data-act="checkUpdate">업데이트 확인</button></div>
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
  const patchTheme = (patch) => {
    config.global.theme = { ...config.global.theme, ...patch };
    applyTheme();
    save();
    render();
  };
  const patchDark = (patch) => {
    config.global.dark = { ...config.global.dark, ...patch };
    applyAll(); // 배경 가림막 색(흰/검)도 다크 여부를 따르므로 전체 재적용
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
    const showUpd = !!update && !updateDismissed;
    $('[data-ref=upd]').hidden = !showUpd;
    if (showUpd) {
      $('[data-ref=updText]').textContent = updateBusy
        ? `v${update.version} 를 받아 설치하는 중입니다. Dooray 가 잠시 후 다시 시작됩니다.`
        : `새 버전 v${update.version} 이 있습니다 (현재 v${VERSION}). ` +
          (IS_DESKTOP ? '[업데이트]를 누르면 자동으로 설치되고 Dooray 가 다시 시작됩니다.' : '웹은 확장 프로그램 파일을 직접 교체해야 합니다.');
      $('[data-act=update]').hidden = updateBusy;
      $('[data-act=updLater]').hidden = updateBusy;
      $('[data-act=update]').textContent = IS_DESKTOP ? '업데이트' : '다운로드 페이지 열기';
    }
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
    $('[data-ref=menuRow]').hidden = !(IS_DESKTOP && IS_WIN); // 메뉴 바는 Windows 앱에만 있음 (macOS 는 시스템 메뉴)
    $('[data-g=hideMenu]').checked = !!config.global.hideMenu;

    const dk = config.global.dark;
    $('[data-d=enabled]').checked = !!dk.enabled;
    $('[data-ref=titleRow]').hidden = !IS_DESKTOP;
    $('[data-d=titleBar]').checked = dk.titleBar !== false;
    $('[data-d=titleBar]').disabled = !dk.enabled;
    $('[data-ref=toastRow]').hidden = !(IS_DESKTOP && IS_WIN); // Mac 은 macOS 기본 알림이라 시스템 화면 모드를 따름
    $('[data-d=toast]').checked = dk.toast !== false;
    $('[data-d=toast]').disabled = !dk.enabled;
    $('[data-d=level]').value = dk.level;
    $('[data-v=darkLevel]').textContent = `${dk.level}%`;
    $('[data-ref=p]').classList.toggle('dark', !!dk.enabled);

    const th = config.global.theme;
    const base = detectThemeBase();
    $('[data-t=enabled]').checked = !!th.enabled;
    const pk = $('[data-t=picker]');
    const pv = isHex6(th.color) ? th.color : base;
    if (pk.value !== pv) pk.value = pv; // 색 선택 창이 열린 채 드래그 중일 때 같은 값을 다시 쓰지 않는다
    const hx = $('[data-t=hex]');
    if (sr.activeElement !== hx) hx.value = th.color;
    $$('[data-swatch]').forEach((b) => b.classList.toggle('on', b.dataset.swatch === th.color.toLowerCase()));
    $('[data-act=eyedrop]').hidden = !('EyeDropper' in window);
    $('[data-ref=p]').style.setProperty('--accent', th.enabled && isHex6(th.color) ? th.color : '#2f6fed');
    $('[data-ref=themeState]').textContent = !th.enabled
      ? '꺼짐 · 색을 고르면 자동으로 켜집니다.' + ('EyeDropper' in window ? '' : ' (이 환경은 스포이드를 지원하지 않아 색 선택 창을 이용하세요)')
      : th.color.toLowerCase() === base.toLowerCase()
        ? '기본 파랑과 같은 색이라 바뀌는 것이 없습니다.'
        : `적용 중: ${th.color} (기본 ${base} 기준으로 옮김)`;

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
    checkUpdate(false, UPDATE_ON_OPEN_MS); // 패널을 열 때 2분 넘게 지났으면 다시 확인

    sr.addEventListener('click', async (e) => {
      const t = e.target;
      const tabBtn = t.closest('[data-tab]');
      if (tabBtn) {
        tab = tabBtn.dataset.tab;
        render();
        return positionPanel();
      }
      const sw = t.closest('[data-swatch]');
      if (sw) return patchTheme({ color: sw.dataset.swatch, enabled: true });
      const act = t.closest('[data-act]')?.dataset.act;
      if (!act) return;
      const scope = t.closest('[data-scope]')?.dataset.scope;
      const box = scope && $(`[data-scope=${scope}]`);
      if (act === 'close') closePanel();
      if (act === 'update') return startUpdate();
      if (act === 'updLater') {
        updateDismissed = true;
        return render();
      }
      if (act === 'checkUpdate') {
        flash('업데이트 확인 중...');
        await checkUpdate(true);
        updateDismissed = false;
        render();
        return flash(update ? `새 버전 v${update.version} 이 있습니다.` : `최신 버전입니다 (v${VERSION}).`);
      }
      if (act === 'eyedrop') {
        if (!('EyeDropper' in window)) return flash('이 환경은 스포이드를 지원하지 않습니다.');
        try {
          const r = await new EyeDropper().open(); // 사용자 클릭 직후(활성화 상태)에 호출해야 열린다
          const c = String(r.sRGBHex).toLowerCase();
          patchTheme({ color: c, enabled: true });
          flash(`${c} 를 가져와 적용했습니다.`);
        } catch {
          // Esc 로 취소
        }
      }
      if (act === 'themeReset') {
        patchTheme({ color: detectThemeBase(), enabled: false });
        flash('기본 파란색으로 되돌렸습니다.');
      }
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
      else if (t.dataset.d === 'enabled') patchDark({ enabled: t.checked });
      else if (t.dataset.d === 'titleBar') patchDark({ titleBar: t.checked });
      else if (t.dataset.d === 'toast') patchDark({ toast: t.checked });
      else if (t.dataset.g === 'hideMenu') {
        config.global.hideMenu = t.checked;
        save();
        render();
        flash(t.checked ? '감시자가 1~2초 안에 메뉴 바를 숨깁니다.' : '메뉴 바를 다시 표시합니다.');
      }
      else if (t.dataset.t === 'enabled') patchTheme({ enabled: t.checked });
      else if (t.dataset.t === 'hex') {
        const v = t.value.trim().replace(/^([0-9a-f]{6})$/i, '#$1').toLowerCase();
        if (!isHex6(v)) return flash('#rrggbb 형식(예: #27a05f)으로 입력해 주세요.');
        patchTheme({ color: v, enabled: true });
      } else if (t.dataset.ref === 'importFile') {
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
      if (t.dataset.d === 'level') {
        config.global.dark = { ...config.global.dark, level: Number(t.value) };
        scheduleTheme();
        save();
        render();
      }
      if (t.dataset.t === 'picker') {
        // 색 선택 창에서 드래그하는 동안 연속으로 들어오므로 적용은 살짝 미룬다(실시간 미리보기)
        config.global.theme = { ...config.global.theme, color: t.value.toLowerCase(), enabled: true };
        scheduleTheme();
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

  // ---------------- Windows: 새 메시지 알림창 다크 모드 ----------------
  // Windows Dooray 는 화면이 chrome.webview.postMessage({type:'application:notification', contents:{title,body,channelId}})
  // 로 넘긴 내용을 자체 창(DoorayMessenger.ToastWnd, GDI 로 직접 그림)에 밝게 그린다 → CSS 다크 모드가 닿지 않음.
  // 다크 모드 + 옵션이 켜져 있고 감시자(launch.ps1)가 살아 있을 때만 이 신호를 가로채 대기열에 넣고,
  // 감시자가 toast-host.ps1 로 어두운 알림창을 띄운다. 감시자가 없으면 원래 알림창이 그대로 뜬다(알림 유실 방지).
  const toastQueue = (window.__drbToastQueue = window.__drbToastQueue || []);
  let toastHookState = 'off';
  const toastColors = () => {
    const lvl = Math.max(4, Math.min(30, Number(config.global.dark.level) || 11));
    const v = Math.round((lvl + 5) * 2.55);
    const hex = (n) => n.toString(16).padStart(2, '0');
    return {
      bg: '#' + hex(v) + hex(v) + hex(v),
      fg: '#f0f0f0',
      sub: '#a9a9a9',
      accent: config.global.theme.enabled ? config.global.theme.color : '#2f8cff',
    };
  };
  const installToastHook = () => {
    const wv = window.chrome && window.chrome.webview;
    if (!IS_DESKTOP || !IS_WIN || !wv || typeof wv.postMessage !== 'function' || wv.__drbHooked) return;
    const orig = wv.postMessage;
    const hooked = function (msg, ...rest) {
      try {
        const dk = config.global.dark;
        const alive = Date.now() - (window.__drbWatcherAlive || 0) < 6000;
        if (dk.enabled && dk.toast !== false && alive && typeof msg === 'string' && msg.includes('application:notification')) {
          const m = JSON.parse(msg);
          if (m && m.type === 'application:notification' && m.contents) {
            const c = m.contents;
            toastQueue.push({ title: String(c.title || ''), body: String(c.body || ''), channelId: c.channelId != null ? String(c.channelId) : '', at: Date.now(), ...toastColors() });
            if (toastQueue.length > 20) toastQueue.splice(0, toastQueue.length - 20);
            return undefined;
          }
        }
      } catch {}
      return orig.call(wv, msg, ...rest);
    };
    try {
      wv.postMessage = hooked;
    } catch {}
    if (wv.postMessage !== hooked) {
      try {
        Object.defineProperty(wv, 'postMessage', { value: hooked, configurable: true, writable: true });
      } catch {}
    }
    toastHookState = wv.postMessage === hooked ? 'on' : 'failed';
    wv.__drbHooked = true;
  };
  // 알림창 클릭 → Windows 앱이 원래 보내는 'mainView:showChannel' 메시지를 흉내 내 그 대화방을 연다
  const showChannel = (channelId) => {
    const wv = window.chrome && window.chrome.webview;
    try {
      if (wv && typeof wv.dispatchEvent === 'function') {
        wv.dispatchEvent(new MessageEvent('message', { data: { type: 'mainView:showChannel', contents: { channelId: String(channelId) } } }));
        return 'dispatched';
      }
    } catch (e) {
      return 'error: ' + e.message;
    }
    return 'unsupported';
  };

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
    installToastHook();
    applyWindowOpacity();
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
  // 패널 바깥을 누르면 닫기. 패널 안(Shadow DOM)과 사이드바 버튼(토글 담당)은 제외.
  // 파일 선택 창·스포이드는 페이지로 pointerdown 이 오지 않아 영향 없음.
  document.addEventListener(
    'pointerdown',
    (e) => {
      if (!host) return;
      const pathEls = e.composedPath ? e.composedPath() : [];
      if (pathEls.includes(host)) return;
      if (pathEls.some((n) => n && n.nodeType === 1 && n.hasAttribute('data-drb-sidebar-btn'))) return;
      closePanel();
    },
    true,
  );

  window.__drbSkin = {
    version: VERSION,
    toggle: togglePanel,
    get config() { return config; },
    host: IS_DESKTOP ? 'desktop' : 'web',
    setTheme: (color, enabled = true) => patchTheme({ color: String(color).toLowerCase(), enabled }),
    setDark: (enabled = true, level) => patchDark(level ? { enabled, level: Number(level) } : { enabled }),
    get themeBase() { return detectThemeBase(); },
    get update() { return update; },
    showChannel,
    effectiveOpacity,
    get toastHook() { return toastHookState; },
    checkUpdate: () => checkUpdate(true),
    updateFailed,
  };

  load().then(() => {
    tick();
    applyAll();
    checkUpdate();
    setInterval(() => checkUpdate(), UPDATE_EVERY_MS);
  });
})();
