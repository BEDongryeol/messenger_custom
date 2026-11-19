#!/bin/bash
# Mac 의 Dooray 상태 점검: Dooray 가 업데이트됐을 때 Dooray Skin 이 어떤 방식으로 붙을 수 있는지 보여 준다.
#   사용: bash tools/check-dooray-mac.sh ["/Applications/Dooray Messenger.app"]
# 읽기만 한다 (아무것도 바꾸거나 실행하지 않는다).
APP="${1:-/Applications/Dooray Messenger.app}"
DATA="$HOME/Library/Application Support/DooraySkin"
[ -d "$APP" ] || { echo "Dooray 앱을 찾지 못했습니다: $APP"; exit 1; }
VER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null)"
FW="$(ls -d "$APP"/Contents/Frameworks/Electron\ Framework.framework/Versions/*/Electron\ Framework 2>/dev/null | head -1)"
ELEC=""
[ -n "$FW" ] && [ -f "$(dirname "$FW")/Resources/Info.plist" ] && ELEC="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$(dirname "$FW")/Resources/Info.plist" 2>/dev/null)"
OFF="$(LC_ALL=C /usr/bin/grep -a -b -o -m1 'dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX' "$FW" 2>/dev/null | head -1 | cut -d: -f1)"
FUSE="unknown"
if [ -n "$OFF" ]; then
  B="$(/bin/dd if="$FW" bs=1 skip=$((OFF + 34)) count=4 2>/dev/null | LC_ALL=C /usr/bin/od -An -c | tr -d ' ')"
  FUSE="RunAsNode=${B:0:1} NodeOptions=${B:2:1} Inspect=${B:3:1}"
fi
case "$FUSE" in
  *"RunAsNode=1"*"Inspect=1"*) STRAT="node-hook   (메인 프로세스 훅: 창 투명도 포함 전체 기능)" ;;
  unknown) STRAT="node-hook   (fuse 를 읽지 못함: 구형 Electron 으로 보고 예전 방식)" ;;
  *) STRAT="cdp-port    (Chromium 디버그 포트 + Ruby 주입기: 창 투명도·제목 표시줄 다크 불가)" ;;
esac
echo "Dooray 앱 버전      : $VER"
echo "Electron            : ${ELEC:-?}"
echo "Electron 보안 설정  : $FUSE   ('1' 켜짐 / '0' 꺼짐)"
echo "Skin 이 붙는 방식   : $STRAT"
echo "앱 파일 시각        : $(/usr/bin/stat -f '%Sm' -t '%F %T' "$APP/Contents/Info.plist")  (자체 업데이트는 빌드 시각을 유지하므로 설치 시각과 다를 수 있음)"
SHIP="$HOME/Library/Caches/com.dooray.messenger.ShipIt/ShipIt_stderr.log"
if [ -f "$SHIP" ]; then
  echo "Dooray 자체 업데이트: $(grep -a 'Installation completed successfully' "$SHIP" | tail -1 | cut -c1-23)  (ShipIt 마지막 설치 완료)"
fi
echo "---"
if [ -f "$DATA/compat-state.json" ]; then echo "Skin 마지막 실행 판단: $(cat "$DATA/compat-state.json")"; else echo "Skin 이 아직 실행된 적 없음(compat-state.json 없음)"; fi
SK="$HOME/Applications/Dooray Skin.app/Contents/Resources/core.js"
[ -f "$SK" ] && echo "설치된 Skin 버전    : $(grep -o "VERSION = '[0-9.]*'" "$SK" | grep -o '[0-9.]*')" || echo "설치된 Skin 없음"
if [ -f "$DATA/launcher.log" ]; then echo "launcher.log 마지막 : $(tail -1 "$DATA/launcher.log" | cut -c1-140)"; fi
