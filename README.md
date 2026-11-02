# Dooray Skin

Dooray 메신저 대화방별 배경 이미지 + 창 투명도 커스텀 도구.
**내 화면에만 적용**되며 Dooray 서버 설정이나 상대방 화면에는 영향이 없습니다.

## 기능
- 우측 사이드바(검색 / @ / 파일 / 링크) 아래 **배경 버튼** 추가 (단축키 `Alt+Shift+B`)
- **이 방**: 대화방별 배경 (파일/URL, 맞춤, 이미지 투명도, 블러, 흰색 가림막, 켜기/끄기)
- **전체**: 방별 설정이 없는 모든 방의 기본 배경, 설정 JSON 내보내기/가져오기
- **두레이 창 투명도** (데스크톱 앱 전용, 30~100%)

## 지원 환경과 동작 방식
| 환경 | Dooray 앱 구조 | 적용 방식 |
|-|-|-|
| macOS 데스크톱 | Electron | Dooray 실행 파일을 `ELECTRON_RUN_AS_NODE` 로 런처 실행 → `--inspect` 로 앱 실행 → 메인 프로세스에 훅 설치 후 디버그 포트 닫음. 창 투명도는 `BrowserWindow.setOpacity` |
| Windows 데스크톱 | C++ + WebView2 | `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port` 로 실행 → 숨김 PowerShell 이 CDP 로 주입·감시. 창 투명도는 `SetLayeredWindowAttributes` |
| 웹 (Chrome/Edge/Whale) | - | MV3 확장, `core.js` 를 MAIN world 로 주입 |

앱 파일(서명, app.asar, 설치 폴더)은 수정하지 않으므로 Dooray 업데이트 후에도 유지됩니다.

## 구조
```
src/core.js                 UI·배경 로직 (웹/데스크톱 공용). 채널 감지, 사이드바 버튼, 설정 패널, IndexedDB 저장
src/launcher.js             macOS 런처 (Electron 메인 프로세스 훅)
installer/mac/app/          Dooray Skin.app 실행 스크립트(자기 설치, Dock 타일 교체), dock.sh
installer/windows/          단일 설치 파일 DooraySkin-Setup.cmd 구성요소
  setup-head.cmd            cmd → PowerShell 부트스트랩
  setup-body.ps1            설치: 파일 풀기, Dooray 탐색, 바로가기/자동실행 교체(백업)
  payload/common.ps1        Dooray 탐색, CDP 클라이언트, Win32 투명도
  payload/launch.ps1        런처 + 감시자
  payload/launch.vbs        콘솔 창 없이 launch.ps1 실행
  payload/uninstall.ps1     제거 + 바로가기 복원
chrome-extension/           웹용 manifest
build.sh                    dist/ 배포 파일 생성 (macOS 에서 실행)
```

## 빌드
```bash
./build.sh
```
결과물 (`dist/`)
| 파일 | 사용자 동작 |
|-|-|
| `DooraySkin-mac.zip` | 압축 해제 → `Dooray Skin` 더블클릭 (~/Applications 자기 설치, Dock 의 Dooray 타일 자동 교체) |
| `DooraySkin-Setup.cmd` | 더블클릭 (작업표시줄 고정/시작메뉴/바탕화면/시작프로그램 바로가기 자동 교체) |
| `DooraySkin-windows.zip` | `.cmd` 첨부가 막힐 때 |
| `DooraySkin-chrome-extension.zip` | `chrome://extensions` → 개발자 모드 → 압축해제된 확장 로드 |

macOS 아이콘은 빌드 시 `/Applications/Dooray Messenger.app` 에서 복사합니다.

## 제거
- macOS: `Dooray Skin 제거.command` (Dock 원복)
- Windows: 시작 메뉴 → `Dooray Skin 제거` (바로가기·자동실행 원복)
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
