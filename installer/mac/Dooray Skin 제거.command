#!/bin/bash
# Dooray Skin 제거 (macOS): Dock 을 원래 Dooray Messenger 로 되돌리고 앱/데이터 삭제.
# 배경 설정 값(Dooray 앱 저장소)은 남지만 Skin 없이 실행하면 적용되지 않습니다.
SKIN="$HOME/Applications/Dooray Skin.app"
APP=""
for p in "/Applications/Dooray Messenger.app" "$HOME/Applications/Dooray Messenger.app"; do [ -d "$p" ] && APP="$p" && break; done
[ -z "$APP" ] && APP="/Applications/Dooray Messenger.app"
if [ -f "$SKIN/Contents/Resources/dock.sh" ]; then
  /bin/bash "$SKIN/Contents/Resources/dock.sh" apply-restore "$APP" >/dev/null 2>&1 || true
fi
rm -rf "$SKIN" "$HOME/Library/Application Support/DooraySkin"
echo "Dooray Skin 을 제거했습니다. Dock 은 Dooray Messenger 로 되돌렸습니다."
echo "실행 중인 Dooray 를 종료 후 다시 켜면 원래 상태가 됩니다."
read -r -t 20 -p "엔터를 누르면 닫힙니다." _ || true
