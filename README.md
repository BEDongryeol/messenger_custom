# Dooray Skin

Dooray 메신저 대화방별 배경 이미지 + 창 투명도 + 테마 색 커스텀 도구.
**내 화면에만 적용**되며 Dooray 서버 설정이나 상대방 화면에는 영향이 없습니다.

## 기능
- 우측 사이드바(검색 / @ / 파일 / 링크) 아래 **Dooray Skin 버튼** 추가 (단축키 `Alt+Shift+B`)
- **이 방**: 대화방별 배경 (파일/URL, 맞춤, 이미지 투명도, 블러, 흰색 가림막, 켜기/끄기)
- **전체**: 방별 설정이 없는 모든 방의 기본 배경, 설정 JSON 내보내기/가져오기
- **테마 색**: 두레이의 파란 계열(버튼, 링크, 탭 밑줄, 선택 강조, 배지 등)을 원하는 색으로. 색 선택 창 / `#rrggbb` 입력 / **스포이드**(화면 어디든 클릭해 색 추출) / 프리셋 9종
- **다크 모드**: 두레이 전체를 어둡게 (배경 밝기 조절). 테마 색과 같이 쓸 수 있음
- **두레이 창 투명도** (데스크톱 앱 전용, 30~100%)

### 다크 모드 동작 방식
두레이에는 전역 다크 테마가 없어(메시지 본문용 `.dooray-flavored-html-dark-mode` 뿐) Dark Reader 와 같은 방식으로 만듭니다.
테마 색과 같은 복제 엔진에서 모든 색 선언을 역할별로 변환합니다.
- 배경: 밝을수록 어둡게(흰색이 가장 어둡게, "배경 밝기" 슬라이더로 조절). 어두운 배경과 채도 있는 배경(버튼)은 유지
- 글자: 어두운 글자는 밝게, 밝은 글자(버튼 위 흰 글자)는 유지, 링크 같은 색 글자는 살짝 밝게
- 테두리·그림자: 밝은 선은 어두운 선으로, 어두운 그림자는 유지
- CSS 변수: `var(--x)` 가 어떤 속성에 쓰이는지 추적해 역할을 정하고(변수→변수 참조도 전파), 못 찾으면 이름·명도로 추정
- 이미지: 투명 배경에 어두운 그림(아이콘 스프라이트)은 캔버스로 명도를 뒤집은 blob URL 로 교체. 사진·로고는 그대로
- `html{color-scheme:dark}` 로 스크롤바·입력창 같은 브라우저 기본 UI 도 어둡게. 설정 패널도 같이 어두워짐
- 창 제목 표시줄("창 제목 표시줄도 어둡게", 데스크톱): Windows 는 감시자가 `DwmSetWindowAttribute`(다크 모드 + 캡션 색을 배경 밝기에 맞춤) 를 외부에서 호출, macOS 는 메인 프로세스 훅이 `nativeTheme.themeSource` 를 바꿈
- Windows 의 상단 메뉴 바(파일·도구·보기…)는 다크로 칠할 공개 API 가 없어, 투명도 박스의 "상단 메뉴 바 숨기기" 옵션으로 `SetMenu(hwnd, null)` 로 떼어낸다(끄면 복원)

### 테마 색 동작 방식
두레이 CSS 는 디자인 토큰(`--color-*`)과 하드코딩 hex 가 섞여 있어 변수만 바꿔서는 부족합니다.
`core.js` 가 페이지의 모든 스타일시트에서 색 관련 선언을 원래 순서대로 복제하되, 파란 계열(hue 190~250°, 채도 25% 이상) 색만
기준색(`--color-background-service-messenger`, 보통 `#1e84cc`) → 지정 색으로 색상·채도·명도를 옮긴 뒤 문서 맨 끝 `<style id="drb-theme">` 로 덮어씁니다.
밝은 틴트는 밝게, 어두운 톤은 어둡게 상대 관계가 유지되고, `!important`/`@media` 도 그대로 따라갑니다.
styled-components 처럼 런타임에 늘어나는 규칙은 1.5초마다 규칙 수를 비교해 바뀐 시트만 다시 만듭니다 (첫 빌드 약 50ms, 이후 1~2ms).

## 지원 환경과 동작 방식
| 환경 | Dooray 앱 구조 | 적용 방식 |
|-|-|-|
| macOS 데스크톱 | Electron | Dooray 실행 파일을 `ELECTRON_RUN_AS_NODE` 로 런처 실행 → `--inspect` 로 앱 실행 → 메인 프로세스에 훅 설치 후 디버그 포트 닫음. 창 투명도는 `BrowserWindow.setOpacity` |
| Windows 데스크톱 | C++ + WebView2 | `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port` 로 실행 → 숨김 PowerShell 이 CDP 로 주입·감시. 창 투명도는 `SetLayeredWindowAttributes` |
| 웹 (Chrome/Edge/Whale) | - | MV3 확장, `core.js` 를 MAIN world 로 주입 |

앱 파일(서명, app.asar, 설치 폴더)은 수정하지 않으므로 Dooray 업데이트 후에도 유지됩니다.

## 구조
```
src/core.js                 UI·배경·테마 색 로직 (웹/데스크톱 공용). 채널 감지, 사이드바 버튼, 설정 패널, 스타일시트 재색칠, IndexedDB 저장
src/launcher.js             macOS 런처 (Electron 메인 프로세스 훅)
installer/mac/app/          Dooray Skin.app 실행 스크립트(자기 설치, Dock 타일 교체), dock.sh
installer/windows/          Windows 설치 파일 구성요소
  DooraySkinSetup.cs        DooraySkin-Setup.exe 스텁 (payload 를 리소스로 내장 → %APPDATA%\DooraySkin 에 풀고 setup.ps1 실행, 진행 창)
  setup-head.cmd            cmd 설치기 부트스트랩 (exe 가 막힌 PC 용)
  payload/setup.ps1         설치: 구버전 감시자·Dooray 종료, 파일 배치, Dooray 탐색, 바로가기/자동실행 교체(백업), 앱 목록 등록
  payload/common.ps1        Dooray 탐색, CDP 클라이언트, Win32 (투명도, 제목 표시줄 다크, 메뉴 바)
  payload/launch.ps1        런처 + 감시자
  payload/launch.vbs        콘솔 창 없이 launch.ps1 실행
  payload/uninstall.ps1     제거 + 바로가기 복원
chrome-extension/           웹용 manifest
build.sh                    macOS 에서 실행: mac 앱, cmd 설치기, 크롬 확장
build-windows.ps1           Windows 에서 실행: DooraySkin-Setup.exe (+ cmd, zip). 외부 도구 없이 내장 csc.exe 사용
.github/workflows/release.yml  VERSION 이 오른 main 커밋 → 자동 빌드·Release (자동 업데이트의 배포 원천)
```

## 빌드
```bash
bash build.sh            # macOS: DooraySkin-mac.zip, DooraySkin-Setup.cmd, DooraySkin-chrome-extension.zip
```
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File build-windows.ps1   # Windows: DooraySkin-Setup.exe, DooraySkin-Setup.cmd, DooraySkin-windows.zip
```
결과물 (`dist/`)
| 파일 | 사용자 동작 |
|-|-|
| `DooraySkin-mac.zip` | 압축 해제 → `Dooray Skin` 더블클릭 (~/Applications 자기 설치, Dock 의 Dooray 타일 자동 교체) |
| `DooraySkin-Setup.exe` | 더블클릭 (진행 창 표시, 작업표시줄 고정/시작메뉴/바탕화면/시작프로그램 바로가기 자동 교체, 앱 목록 등록). 구버전 위에 그대로 실행하면 업데이트 |
| `DooraySkin-Setup.cmd` | exe 실행이 막힌 PC 용, 같은 내용 |
| `DooraySkin-windows.zip` | exe + cmd + README (첨부가 막힐 때) |
| `DooraySkin-chrome-extension.zip` | `chrome://extensions` → 개발자 모드 → 압축해제된 확장 로드 |

아이콘은 빌드 PC 에 설치된 Dooray 에서 복사합니다 (macOS: `/Applications/Dooray Messenger.app`, Windows: `DoorayMessenger.exe`).

Windows 재설치/업데이트 시: `setup.ps1` 이 먼저 구버전 감시자(옛 `core.js` 를 메모리에 들고 계속 주입)와 Dooray 를 종료하고, 파일을 덮어쓴 뒤 다시 실행합니다.
이미 교체된 바로가기는 건드리지 않고, 바로가기 백업(`shortcut-backup.json`)은 처음 백업한 원본을 유지하므로 제거 시 원래 Dooray 로 돌아갑니다. 사용자 설정(IndexedDB)은 그대로 유지됩니다.

## 배포와 자동 업데이트
1. `src/core.js` 의 `VERSION` 을 올려서 main 에 커밋 (`chrome-extension/manifest.json` 의 version 도 같이)
2. GitHub Actions(`.github/workflows/release.yml`)가 macOS·Windows 러너에서 빌드해 Release `vX.Y.Z` 를 만든다
   (Mac 앱 zip, Setup.exe/cmd, windows zip, 크롬 확장 zip). 같은 버전 Release 가 있으면 건너뛰므로 문서 커밋은 배포되지 않는다
3. 사용자 PC 의 Dooray Skin 이 6시간마다 최신 Release 를 확인 → 새 버전이면 패널 맨 위 알림 + 사이드바 버튼 빨간 점
4. **[업데이트]**
   - macOS 앱: 메인 프로세스 훅이 `DooraySkin-mac.zip` 을 받아 새 `Dooray Skin.app` 실행 → 자기 설치 → Dooray 재시작
   - Windows 앱: 감시자가 `DooraySkin-Setup.exe`(없으면 .cmd)를 받아 실행 → 덮어쓰기 설치 → Dooray 재시작
   - 웹 확장: Chrome 정책상 자동 설치 불가 → 릴리스 페이지 안내
   - 다운로드 주소는 이 저장소의 Release 경로만 허용. 프로그램이 직접 받으므로 Gatekeeper/SmartScreen 경고가 없다
   - Mac 앱 아이콘은 재배포하지 않고 설치 시 사용자 Mac 의 Dooray 아이콘을 복사한다

> 주의: Release 를 만들 수 있는 사람(저장소 쓰기 권한)이 올린 코드가 모든 사용자의 Dooray 에서 실행된다.
> 쓰기 권한은 신뢰하는 사람에게만 주고, main 보호 규칙(PR 리뷰 필수)을 켜는 것을 권장한다.

## 제거
- macOS: `Dooray Skin 제거.command` (Dock 원복)
- Windows: 시작 메뉴 → `Dooray Skin 제거`, 또는 설정 → 앱 → Dooray Skin → 제거, 또는 `DooraySkin-Setup.exe /uninstall` (바로가기·자동실행 원복)
- 웹: 확장 프로그램 삭제

## 로그
- macOS: `~/Library/Application Support/DooraySkin/{app,launcher,hook}.log`
- Windows: `%APPDATA%\DooraySkin\launcher.log`

## 알려진 제약
- 서명되지 않은 사내 배포용: macOS 첫 실행 시 Gatekeeper 허용, Windows SmartScreen "추가 정보 → 실행" 필요
- Windows 는 Dooray 실행 중 localhost 디버그 포트가 열려 있음 (같은 PC 의 다른 프로세스가 접근 가능)
- 회사 정책이 PowerShell 실행이나 WebView2 원격 디버깅, 확장 개발자 모드를 막으면 동작하지 않음
- Dooray 프론트 구조(`data-testid="channel-header-title"`, `#main-contents`, `.js-scroll-area`, 사이드바 버튼 `aria-label`)가 바뀌면 일부 기능이 깨질 수 있음
- 배경 설정은 앱/브라우저별로 따로 저장됨 → 내보내기/가져오기로 이동
- 테마 색은 CSS 로 칠해진 색만 바뀜. 이미지로 된 로고·앱 아이콘, 두레이가 새로 추가한 파란색이 아닌 강조색은 그대로
- 다크 모드는 색을 규칙으로 추정하므로 일부 요소(인라인 스타일 색, 사진 안 글자, 다른 출처 이미지)는 어둡게 되지 않을 수 있음
- Windows 메뉴 바 숨기기는 감시자가 살아 있어야 복원됨 (감시자가 죽은 채로 옵션을 끄면 Dooray 재시작 시 복원). 캡션 색은 Windows 11 전용이고 Windows 10 은 다크/밝게만 바뀜
- 스포이드는 Chromium `EyeDropper` API 가 있는 환경(Chrome/Edge/Whale, WebView2, Electron)에서만 보임. 없으면 색 선택 창을 사용
