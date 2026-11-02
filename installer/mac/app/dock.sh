#!/bin/bash
# Dock 의 Dooray Messenger 타일을 Dooray Skin 으로 교체/복원한다.
#   dock.sh replace <plist> <skin.app 경로>   : plist 파일만 수정 (테스트용)
#   dock.sh restore <plist> <dooray.app 경로>
#   dock.sh apply-replace <skin.app>         : 실제 Dock 반영 (export → 수정 → import → Dock 재시작)
#   dock.sh apply-restore <dooray.app>
PB=/usr/libexec/PlistBuddy

file_url() { # 경로 → file:// URL (공백 등 최소 인코딩)
  local p="$1"; [[ "$p" != */ ]] && p="$p/"
  p="${p//%/%25}"; p="${p// /%20}"; p="${p//#/%23}"; p="${p//\?/%3F}"
  printf 'file://%s' "$p"
}

# $1=plist $2=찾을 URL 조각(정규식) $3=새 앱 경로 $4=새 라벨 $5=새 bundle id
swap_tiles() {
  local plist="$1" match="$2" newurl label="$4" bid="$5" i u changed=0
  newurl="$(file_url "$3")"
  for i in $(seq 0 200); do
    $PB -c "Print :persistent-apps:$i" "$plist" >/dev/null 2>&1 || break
    u="$($PB -c "Print :persistent-apps:$i:tile-data:file-data:_CFURLString" "$plist" 2>/dev/null)" || continue
    if printf '%s' "$u" | grep -Eqi "$match"; then
      $PB -c "Set :persistent-apps:$i:tile-data:file-data:_CFURLString $newurl" "$plist"
      $PB -c "Set :persistent-apps:$i:tile-data:file-label \"$label\"" "$plist" 2>/dev/null \
        || $PB -c "Add :persistent-apps:$i:tile-data:file-label string \"$label\"" "$plist"
      $PB -c "Set :persistent-apps:$i:tile-data:bundle-identifier $bid" "$plist" 2>/dev/null \
        || $PB -c "Add :persistent-apps:$i:tile-data:bundle-identifier string $bid" "$plist"
      # book(alias 북마크)이 남아 있으면 Dock 이 예전 앱으로 되돌아갈 수 있어 제거
      $PB -c "Delete :persistent-apps:$i:tile-data:book" "$plist" 2>/dev/null || true
      changed=$((changed + 1))
    fi
  done
  echo "$changed"
}

apply() { # $1=match $2=app $3=label $4=bid
  local tmp; tmp="$(mktemp -d)/dock.plist"
  defaults export com.apple.dock "$tmp" || return 1
  local n; n="$(swap_tiles "$tmp" "$1" "$2" "$3" "$4")"
  if [ "${n:-0}" -gt 0 ]; then
    defaults import com.apple.dock "$tmp" && killall Dock 2>/dev/null
  fi
  echo "$n"
}

case "$1" in
  replace)       swap_tiles "$2" '/Dooray%20Messenger\.app/?$' "$3" "Dooray Skin" "local.dooray-skin.launcher" ;;
  restore)       swap_tiles "$2" '/Dooray%20Skin\.app/?$' "$3" "Dooray Messenger" "com.dooray.messenger" ;;
  apply-replace) apply '/Dooray%20Messenger\.app/?$' "$2" "Dooray Skin" "local.dooray-skin.launcher" ;;
  apply-restore) apply '/Dooray%20Skin\.app/?$' "$2" "Dooray Messenger" "com.dooray.messenger" ;;
  *) echo "usage: dock.sh replace|restore|apply-replace|apply-restore ..." >&2; exit 2 ;;
esac
