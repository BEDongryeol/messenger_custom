# Dooray 버전과 Dooray Skin 호환성 관리

Dooray 는 **앱**(Mac/Windows 설치본)과 **웹**(서버가 배포하는 화면)이 따로 바뀝니다.
둘 중 어느 쪽이 바뀌어도 Skin 이 깨질 수 있어서, 버전 조합별로 "무엇이 되는지"를 기록하고 앱 안에서 보여 줍니다.

## 1. 무엇이 어디에 의존하나

| 층 | Skin 이 기대하는 것 | 바뀌면 생기는 일 | 누가 바꾸나 |
|-|-|-|-|
| **앱: 붙는 통로** | Mac: Dooray 실행 파일을 Node 로 실행(`RunAsNode`)하고 `--inspect` 로 메인 프로세스에 붙기 / Windows: WebView2 디버그 포트 | **전부 안 됨** (Dooray 4.0.4 에서 실제로 발생) | NHN, 앱 업데이트 때 |
| 앱: 창 규칙 | 창 주소 규칙(`/messenger/image/..`, `/preview-pages/..`, `/messenger/popup/..`) | 투명도 예외 창이 어긋남 | NHN, 앱 업데이트 때 |
| 앱: 자체 업데이트 | Squirrel(`quitAndInstall`)로 업데이트 후 **Skin 없이** 자동 재시작 | 업데이트 직후 Skin 이 풀림 | NHN |
| **웹: 화면 요소** | `#main-contents`, `.js-scroll-area`, `data-testid=channel-header-title`, 사이드바 버튼 이름("검색", "링크 모아보기"), React props 의 `channelId` | 배경/사이드바 버튼/방 인식이 부분적으로 안 됨 | NHN, **서버 배포 때(앱 업데이트 없이)** |

웹 화면은 서버가 배포하므로 앱 버전이 같아도 바뀔 수 있습니다. 웹 배포 단위는 `window._posthogReleaseId` 로 알 수 있습니다.

## 2. 세 가지 장치

1. **환경 수집** (`core.js` 의 `ENV`): Skin 버전, 플랫폼, Dooray 앱 버전, 웹 릴리스 ID, 붙는 방식(strategy), 주입 방식이 허용하는 기능(caps).
   앱 버전은 호스트가 알려 줍니다 (Mac 훅 `app.getVersion()`, Mac 주입기 `Info.plist`, Windows `DoorayMessenger.exe` 파일 버전).
2. **화면 자가 점검** (`__drbSkin.health`): 위 표의 웹 요소 8개가 지금도 있는지 확인하고, 실패하면 영향받는 기능 이름과 함께 패널에 표시합니다.
   결과는 호스트 로그(`hook.log`)에도 남아서 어느 Dooray 버전에서 무엇이 깨졌는지 추적할 수 있습니다.
3. **호환성 표** (`compat/dooray-compat.json` → GitHub Pages `compat.json`): 버전 조합별 상태와 "이 환경에서는 끄는 기능".
   **Skin 을 새로 릴리스하지 않고** 이 파일만 고쳐 올려도 모든 사용자에게 반영됩니다 (6시간마다 확인, 패널의 [다시 점검]으로 즉시).

패널 위치: Dooray Skin 패널 > **전체** 탭 > **호환성**. 상태가 `제한`/`동작 안 함`이거나 점검이 실패하면 패널 맨 위에 노란 알림이 뜹니다.

## 3. 현재 상태 (2026-11-19 기준)

| Dooray | 붙는 방식 | 되는 것 | 안 되는 것 | 확인 |
|-|-|-|-|-|
| Mac 4.0.3 이하 | `node-hook` (메인 프로세스 훅) | 전부 | - | 4.0.3 실사용 확인 |
| **Mac 4.0.4 이상** | `cdp-port` (Chromium 디버그 포트 + Ruby 주입기) | 배경, 테마 색, 다크 모드, 잠금, 사이드바 버튼/패널, 업데이트 알림·설치 | **창 투명도, 제목 표시줄 다크** (메인 프로세스에 접근 불가) | fuse·코드 분석, 가짜 CDP 테스트. **실제 4.0.4 앱 적용은 확인 전** |
| Windows 2.2.x | `webview2-port` | 전부 | - | 2.2.2 |
| 웹 확장 | 확장 프로그램 | 배경, 테마 색, 다크 모드, 잠금 | 창 투명도(브라우저라 불가) | 웹 릴리스 `01a1eddd…` 점검 8/8 |

### 2026-11-19 사건: Dooray Mac 4.0.4
- 09:16 Dooray 자체 업데이트(ShipIt)가 앱을 4.0.4 로 교체하고 자동 재시작 (Skin 없이).
- 4.0.4 의 Electron 보안 설정(fuse): `RunAsNode` 꺼짐, `EnableNodeOptionsEnvironmentVariable` 꺼짐, `EnableNodeCliInspectArguments` 꺼짐.
  Slack, Notion, Claude, Figma 등 일반적인 "잠근" Electron 앱과 같은 설정입니다 (특정 도구를 겨냥한 변경이 아님).
- 결과: `ELECTRON_RUN_AS_NODE=1 Dooray launcher.js` 가 무시되어 Dooray 가 그냥 실행되고 Skin 은 적용되지 않음.
- 확인한 것: 창 주소 규칙(URL_PATTERN)은 4.0.3 과 같음, 앱 코드에 Chromium 디버그 포트를 막는 부분 없음, 웹 화면 점검 8/8 통과.
- 대응: Skin 0.8.0 이 Windows 와 같은 방식(디버그 포트)으로 화면에만 붙는다. 메인 프로세스가 필요한 창 투명도는 불가.

## 4. 새 Dooray 버전이 나왔을 때 (대응 절차)

1. **알아채기**: Mac `bash tools/check-dooray-mac.sh` (Dooray 버전, Electron 보안 설정, 마지막 자체 업데이트 시각, Skin 판단). Windows 는 `%APPDATA%\DooraySkin\launcher.log` 의 `dooray app version`.
   웹은 Dooray 웹 탭에서 Skin 패널 > 전체 > 호환성 (웹 릴리스가 "새로 바뀜"이면 확인 목록에 없는 새 배포).
2. **확인하기**
   - 웹: Dooray 웹을 열고 개발자 도구 콘솔에서 `__drbSkin.health` (실패 항목 확인), `__drbSkin.env`.
   - Mac: `tools/check-dooray-mac.sh` 의 "Skin 이 붙는 방식"이 이전과 같은지. `Inspect=0` 이면 `cdp-port` 방식.
   - 직접 써 보기: 배경 설정, 다크 모드, (4.0.3 이하/Windows) 창 투명도, 이미지·파일 미리보기 창.
3. **기록하기**: `compat/dooray-compat.json` 수정
   - 문제 없음: `webVerified` 에 새 릴리스 ID 추가, 앱이면 `rules` 의 `verified` 에 버전 추가.
   - 기능 제한: 해당 조합 규칙을 위쪽에 추가하고 `disable` 에 끌 기능, `note` 에 사용자에게 보일 설명.
   - 동작 안 함: `status: "broken"` + `note`.
4. **올리기**: main 에 커밋하면 Actions 가 검증 후 Pages 에 게시합니다 (JSON 형식이 틀리면 게시되지 않음). 코드 수정이 필요하면 `VERSION` 을 올려 릴리스.

## 5. compat.json 규칙 문법

```json
{ "schema": 1, "updated": "2026-11-19",
  "rules": [
    { "id": "mac-4.0.4-plus", "platform": "mac", "strategy": "cdp-port", "app": ">=4.0.4", "skin": ">=0.8.0",
      "status": "limited", "disable": ["windowOpacity", "sidebarOpacity", "darkTitleBar"], "note": "사용자에게 보일 설명" }
  ],
  "webVerified": [ { "release": "01a1eddd-cda7-0000-bd20-eaba86cbeb00", "date": "2026-11-19", "skin": "0.8.0", "checks": "8/8" } ] }
```

- 규칙은 **위에서부터 처음 맞는 하나**만 적용됩니다.
- 조건: `platform`(mac | win | web), `strategy`(node-hook | cdp-port | webview2-port), `app`(앱 버전 범위), `skin`(Skin 버전 범위), `web`(웹 릴리스 ID 목록, 맞는 배포에만 적용).
  범위 문법: `>=4.0.4`, `<4.0.4`, `>=2.2.0 <3` (공백은 AND), `4.0.3`.
- 결과: `status`(verified | limited | broken), `disable`(끌 기능: `windowOpacity`, `sidebarOpacity`, `darkTitleBar`, `toast`), `note`.
- 맞는 규칙이 없으면 "미확인 버전"으로 표시하고 기능은 막지 않습니다 (화면 점검은 계속 동작).
- 웹 확장은 설치본 버전이 없어 `webVerified` 목록으로 "정상"을 판단합니다.

## 6. Mac `cdp-port` 방식 참고

- `Dooray Skin.app` 래퍼가 Dooray 버전과 Electron 보안 설정을 읽어 방식을 고릅니다 (`compat-state.json` 에 기록).
  `RunAsNode` 와 `Inspect` 가 모두 켜져 있으면 `node-hook`, 아니면 `cdp-port`, 읽지 못하면 `node-hook`(구형).
- `cdp-port` 는 macOS 기본 Ruby(`/usr/bin/ruby`, 개발자 도구 불필요)로 `cdp-injector.rb` 를 실행합니다. 표준 라이브러리만 사용 (`--disable-gems`).
- 디버그 포트는 `127.0.0.1` 에서만 열립니다. Windows 방식과 같은 위험 수준이지만, 같은 PC 의 다른 프로그램이 포트 번호(`port.txt`)를 알면 Dooray 화면을 조작할 수 있습니다.
- 감시: Dooray 가 Skin 없이 막 시작되면(자체 업데이트 직후 등, 시작 후 6~90초) 디버그 포트로 다시 실행합니다. 10분 안에 두 번 다시 시작하면 멈추고 알립니다.
  끄기: `~/Library/Application Support/DooraySkin/keeper.off` 파일 생성.
- 포트가 열리지 않으면(Dooray 가 막은 경우) Skin 은 적용되지 않고 알림과 `launcher.log` 에 기록됩니다.

## 7. 앞으로의 선택지 (창 투명도를 Mac 4.0.4+ 에서 쓰려면)

창 투명도는 Dooray 메인 프로세스에서만 설정할 수 있습니다. 가능한 방법은 Dooray 앱을 **복사해 보안 설정을 되돌리고 다시 서명**하는 것인데,
Keychain 접근 확인 창, 카메라/마이크 권한 재요청, Dooray 업데이트마다 재생성이 필요하고 NHN 이 의도적으로 잠근 설정을 푸는 일이라
회사 보안 정책 확인이 먼저입니다. 현재는 채택하지 않았습니다.
