/*
 * Dooray Skin 시작 덮개 (웹 확장 document_start, Windows 는 CDP Page.addScriptToEvaluateOnNewDocument)
 *
 * 다크 모드 사용자가 Dooray 를 켜거나 새로고침할 때 밝은 화면이 번쩍이지 않도록, 페이지가 그려지기 전에
 * 다크 모드 배경색 덮개를 깔고 core.js 가 다크 모드를 적용하면(html[data-drb-ready]) 걷는다.
 *  - 설정은 core.js 가 localStorage 'drb-early' 에 남긴 { bg } 만 읽는다(동기, IndexedDB 를 기다리지 않음)
 *  - 대화 화면(/messenger, 따로 띄운 채팅 창)에서만 쓴다. 미리보기 창 등에는 깔지 않는다
 *  - core.js 가 어떤 이유로든 신호를 못 주면 4초 뒤 CSS 만으로 스스로 사라진다
 *  - 다크 모드를 끄면 core.js 가 html[data-drb-light] 를 붙여 배경색도 즉시 무효화한다
 * macOS 앱은 메인 프로세스 훅(launcher.js)이 같은 CSS 를 insertCSS 로 넣는다(earlyCss 와 같은 내용 유지).
 */
(() => {
  try {
    if (window.__drbEarly) return;
    window.__drbEarly = true;
    if (!/^\/messenger(?:\/?$|\/(?:popup|channels)\/\d+)/.test(location.pathname)) return;
    const e = JSON.parse(localStorage.getItem('drb-early') || 'null');
    if (!e || !/^#[0-9a-f]{6}$/i.test(e.bg)) return;
    const bg = e.bg;
    const css =
      `html:not([data-drb-light]){background:${bg}!important;color-scheme:dark}` +
      `html:not([data-drb-light])::after{content:"";position:fixed;inset:0;z-index:2147483647;background:${bg};pointer-events:none;` +
      `transition:opacity .25s,visibility .25s;animation:drb-early-out .3s ease 4s forwards}` +
      `html[data-drb-ready]::after{opacity:0;visibility:hidden}` +
      `@keyframes drb-early-out{to{opacity:0;visibility:hidden}}`;
    const put = () => {
      const s = document.createElement('style');
      s.id = 'drb-early';
      s.textContent = css;
      (document.head || document.documentElement).appendChild(s);
    };
    if (document.documentElement) put();
    else
      new MutationObserver((_, o) => {
        if (!document.documentElement) return;
        o.disconnect();
        put();
      }).observe(document, { childList: true });
  } catch {}
})();
