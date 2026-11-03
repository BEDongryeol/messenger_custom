# Dooray Skin 런처 + 감시자 (Windows). launch.vbs 가 숨김 창으로 실행한다.
#  1) 이미 감시자가 돌고 있으면 Dooray 창만 앞으로 (끝)
#  2) Skin 없이 떠 있는 Dooray 는 종료 후, 디버그 포트를 연 상태로 다시 실행
#  3) Dooray 가 꺼질 때까지: 새 화면/새로고침마다 core.js 주입, 창 투명도 적용
$ErrorActionPreference = 'Continue'
. (Join-Path $env:APPDATA 'DooraySkin\common.ps1')
[System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy   # 사내 프록시가 localhost 를 가로채지 않게

$data = $script:DrbData
$exe = Find-DoorayExe
if (-not $exe) {
  Add-Type -AssemblyName PresentationFramework
  [System.Windows.MessageBox]::Show('Dooray Messenger 실행 파일을 찾지 못했습니다. 설치 파일(DooraySkin-Setup.cmd)을 다시 실행해 주세요.', 'Dooray Skin') | Out-Null
  exit 1
}
$portFile = Join-Path $data 'port.txt'
if (-not (Test-Path $portFile)) { Set-Content $portFile (Get-Random -Minimum 20000 -Maximum 45000) }
$port = [int](Get-Content $portFile -Raw).Trim()

$mutex = New-Object System.Threading.Mutex($false, 'Local\DooraySkinWatcher')
if (-not $mutex.WaitOne(0)) {
  Write-DrbLog 'watcher already running -> focus Dooray'
  Start-Process -FilePath $exe
  exit 0
}

Write-DrbLog "launch start exe=$exe port=$port"
Update-DrbRunKey | Out-Null

$running = Get-Process -Name DoorayMessenger -ErrorAction SilentlyContinue
$portUp = [bool](Get-DrbTargets $port)
if ($running -and -not $portUp) {
  Write-DrbLog 'stop plain Dooray'
  $running | Stop-Process -Force -ErrorAction SilentlyContinue
  for ($i = 0; $i -lt 40 -and (Get-Process -Name DoorayMessenger -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 250 }
  # 이전 Dooray 의 WebView2 프로세스가 남아 있으면 새 설정이 무시되므로 정리
  for ($i = 0; $i -lt 40; $i++) {
    $left = Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match '(?i)dooray' }
    if (-not $left) { break }
    if ($i -eq 20) { $left | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }
    Start-Sleep -Milliseconds 250
  }
}
if (-not ($running -and $portUp)) {
  $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=$port"
  Start-Process -FilePath $exe
  Remove-Item Env:\WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS
  Write-DrbLog 'Dooray started with debug port'
}

$core = [IO.File]::ReadAllText((Join-Path $data 'core.js'), [Text.Encoding]::UTF8)
$injectExpr = "window.__DRB_HOST='desktop';`n" + $core + "`n;'injected'"
# 시작 덮개(다크 모드 깜빡임 방지): 새 문서마다 페이지보다 먼저 실행 (이벤트 방식에서만 등록 가능)
$earlyPath = Join-Path $data 'early.js'
$earlySrc = if (Test-Path $earlyPath) { [IO.File]::ReadAllText($earlyPath, [Text.Encoding]::UTF8) } else { $null }
# 페이지 상태: 창 투명도(op, 설정값), 창 안 이미지 보기 열림(vw), 다크 모드(제목 표시줄), 메뉴 바 숨기기, 업데이트 요청, 알림창 대기열
$checkExpr = "JSON.stringify((g=>({core: !!window.__drbCore, rs: document.readyState, op: (g&&g.windowOpacity)||100, vw: !!(window.__drbSkin&&window.__drbSkin.effectiveOpacity&&window.__drbSkin.effectiveOpacity()===100), dark: !!(g&&g.dark&&g.dark.enabled&&g.dark.titleBar!==false), level: (g&&g.dark&&g.dark.level)||11, hideMenu: !!(g&&g.hideMenu), btn: !!document.querySelector('[data-drb-sidebar-btn]'), upd: window.__drbUpdateRequest||null, alive: (window.__drbWatcherAlive=Date.now(), 1), toasts: (window.__drbToastQueue||[]).splice(0)}))(window.__drbSkin&&window.__drbSkin.config&&window.__drbSkin.config.global))"
$doorayRe = '^https://([a-z0-9-]+\.)*dooray\.com/'
# 투명도는 대화 창(메신저 화면, 따로 띄운 채팅 창)에만. 나머지(이미지·파일·메일 미리보기, 작성 창 등)는 불투명.
$chatRe = '^https://[^/]+/messenger/?([?#]|$)|^https://[^/]+/messenger/(popup|channels)/\d+(/threads/\d+)?/?([?#]|$)'

# 다크 모드 알림창: 페이지가 가로챈 알림(window.__drbToastQueue)을 toast-host.ps1 에 파일로 넘기고, 클릭 결과를 받아 그 대화방을 연다
$toastIn = Join-Path $data 'toast\in'
$toastClick = Join-Path $data 'toast\click'
New-Item -ItemType Directory -Force -Path $toastIn, $toastClick | Out-Null
function Start-DrbToastHost {
  $m = $null
  if ([System.Threading.Mutex]::TryOpenExisting('Local\DooraySkinToastHost', [ref]$m)) { $m.Dispose(); return }
  $hostPs1 = Join-Path $data 'toast-host.ps1'
  if (-not (Test-Path $hostPs1)) { return }
  Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + $hostPs1 + '"')
  Write-DrbLog 'toast host started'
}
function Send-DrbToasts($items) {
  Start-DrbToastHost
  foreach ($it in @($items)) {
    $name = '{0:D19}-{1}' -f [DateTime]::UtcNow.Ticks, (Get-Random -Maximum 99999)
    $tmp = Join-Path $toastIn ($name + '.tmp')
    [IO.File]::WriteAllText($tmp, ($it | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item $tmp (Join-Path $toastIn ($name + '.json')) -Force
  }
}
# 알림창에서 누른 대화방 id 목록 (파일은 읽고 지운다)
function Read-DrbToastClicks {
  $ids = @()
  foreach ($f in [IO.Directory]::GetFiles($toastClick, '*.json')) {
    try {
      $cid = (([IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | ConvertFrom-Json).channelId -replace '[^\w-]', '')
      if ($cid) { $ids += $cid }
    } catch {}
    Remove-Item $f -Force -ErrorAction SilentlyContinue
  }
  return , $ids
}

# 자동 업데이트: 페이지에서 [업데이트] 를 누르면 window.__drbUpdateRequest = { url, version } 가 생긴다.
# Setup 을 받아 실행하면 setup.ps1 이 이 감시자와 Dooray 를 끄고 덮어쓴 뒤 다시 실행한다.
# PowerShell 로 받은 파일에는 인터넷 표시(MOTW)가 붙지 않아 SmartScreen 경고가 없다.
# 반환: 성공 $null, 실패 시 페이지에 보여 줄 메시지
function Start-DrbUpdate($upd) {
  $url = [string]$upd.url
  if ($url -notmatch '^https://github\.com/BEDongryeol/messenger_custom/releases/download/[^/]+/DooraySkin-Setup\.(exe|cmd)$') {
    Write-DrbLog "update url rejected: $url"
    return '허용되지 않은 주소'
  }
  $ext = [IO.Path]::GetExtension($url)
  $dst = Join-Path $env:TEMP ('DooraySkin-Setup-' + ([string]$upd.version -replace '[^\d.]', '') + $ext)
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $wc = New-Object System.Net.WebClient
    $wc.Proxy = [System.Net.WebRequest]::GetSystemWebProxy()   # 인터넷 다운로드는 사내 프록시를 따른다 (localhost 용 빈 프록시와 별개)
    $wc.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
    Write-DrbLog "update download $url"
    $wc.DownloadFile($url, $dst)
  } catch {
    Write-DrbLog ("update download failed: " + $_.Exception.Message)
    return '다운로드 실패'
  }
  Write-DrbLog "update run $dst"
  if ($ext -eq '.exe') { Start-Process -FilePath $dst }
  else { Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c "' + $dst + '"') }
  return $null
}
function Get-DrbFailExpr([string]$msg) { return "window.__drbSkin&&window.__drbSkin.updateFailed&&window.__drbSkin.updateFailed(" + ($msg | ConvertTo-Json) + ")" }

# ---------------- 페이지 상태 → 창 적용 (두 방식 공통) ----------------
$script:op = $null
$script:lastOp = 100
$script:chrome = $null
$script:updating = $false
$script:seen = @{}
# 상태 하나 처리. 업데이트 실패 시 페이지에 보낼 메시지를 돌려준다
function Use-DrbState($state, [string]$label) {
  $script:op = [int]$state.op
  $script:chrome = @{ dark = [bool]$state.dark; level = [int]$state.level; menu = [bool]$state.hideMenu }
  if (-not $script:seen.ContainsKey($label)) { $script:seen[$label] = 1; Write-DrbLog ("active " + $label + " btn=" + $state.btn) }
  if ($state.toasts -and @($state.toasts).Count) { Send-DrbToasts $state.toasts; Write-DrbLog ("toast x" + @($state.toasts).Count) }
  if ($state.upd -and -not $script:updating) {
    $script:updating = $true
    $err = Start-DrbUpdate $state.upd
    if ($err) { $script:updating = $false; return $err }
  }
  return $null
}
# pages: @{ url; title; vw } 목록. 대화 창이 아니거나 창 안 이미지 보기가 열린 창의 제목은 불투명 목록으로.
# Win32 창과는 제목으로 짝짓는다. 투명해야 할 대화 창과 제목이 같은 창은 그 대화 창을 지키기 위해 제외하지 않는다.
function Get-DrbOpaqueTitles($pages) {
  $chat = @($pages | Where-Object { $_.title -and $_.url -match $chatRe -and -not $_.vw } | ForEach-Object { [string]$_.title })
  return , @($pages | Where-Object { $_.title -and ($_.url -notmatch $chatRe -or $_.vw) -and $chat -notcontains [string]$_.title } | ForEach-Object { [string]$_.title })
}
function Update-DrbWindows($pages, [bool]$force) {
  # 바뀌었으면 바로, 투명 상태(100% 미만)면 force 때마다 다시 적용(새로 뜬 창 반영)
  if ($null -ne $script:op -and ($script:op -ne $script:lastOp -or ($force -and $script:op -lt 100))) {
    $n = Set-DrbOpacity $script:op (Get-DrbOpaqueTitles $pages)
    if ($script:op -ne $script:lastOp) { Write-DrbLog "opacity $($script:op)% -> $n window(s)" }
    $script:lastOp = $script:op
  }
  if ($script:chrome) {
    $n = Set-DrbWindowChrome $script:chrome.dark $script:chrome.level $script:chrome.menu
    if ($n) { Write-DrbLog "chrome dark=$($script:chrome.dark) level=$($script:chrome.level)% hideMenu=$($script:chrome.menu) -> $n change(s)" }
  }
}
function Test-DrbDoorayAlive { return [bool](Get-Process -Name DoorayMessenger -ErrorAction SilentlyContinue) }

# ---------------- 방식 1: 이벤트 (브라우저 CDP 연결 하나 유지) ----------------
# Target.setDiscoverTargets 로 창 생성·주소 변경·닫힘을 이벤트로 받고, 각 화면에 flatten 세션으로 붙어
# Runtime.addBinding('__drbNotify') 를 단다. core.js 가 상태가 바뀔 때 __drbNotify() 를 부르면 즉시 상태를 읽는다.
# 바인딩 동작이 확인되기 전에는 1초, 확인된 뒤에는 2.5초마다 확인(안전망·하트비트).
function New-DrbCdp([string]$url) {
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  try {
    if (-not $ws.ConnectAsync([Uri]$url, [Threading.CancellationToken]::None).Wait(5000)) { $ws.Dispose(); return $null }
  } catch { Write-DrbLog ('cdp connect error: ' + $_.Exception.GetBaseException().Message); $ws.Dispose(); return $null }
  $buf = New-Object byte[] 262144
  return @{ ws = $ws; buf = $buf; seg = (New-Object 'ArraySegment[byte]' (, $buf)); ms = (New-Object IO.MemoryStream); recv = $null; id = 0; pend = @{} }
}
function Send-DrbCdp($c, [string]$method, $params, [string]$sid, $tag) {
  $c.id = $c.id + 1
  if ($null -eq $params) { $params = @{} }
  $m = @{ id = $c.id; method = $method; params = $params }
  if ($sid) { $m.sessionId = $sid }
  if ($null -ne $tag) { $c.pend[$c.id] = $tag }
  $bytes = [Text.Encoding]::UTF8.GetBytes(($m | ConvertTo-Json -Depth 8 -Compress))
  $seg = New-Object 'ArraySegment[byte]' (, $bytes)
  if (-not $c.ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait(5000)) { throw 'cdp send timeout' }
  return $c.id
}
# 최대 waitMs 동안 받은 메시지(문자열) 목록. 받는 중인 작업은 다음 호출로 이어진다
function Read-DrbCdp($c, [int]$waitMs) {
  $out = New-Object System.Collections.Generic.List[string]
  $deadline = [DateTime]::UtcNow.AddMilliseconds($waitMs)
  while ($out.Count -lt 200) {
    if ($null -eq $c.recv) { $c.recv = $c.ws.ReceiveAsync($c.seg, [Threading.CancellationToken]::None) }
    $left = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
    if (-not $c.recv.Wait($left)) { break }
    $r = $c.recv.Result
    $c.recv = $null
    if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { throw 'cdp closed' }
    $c.ms.Write($c.buf, 0, $r.Count)
    if ($r.EndOfMessage) { $out.Add([Text.Encoding]::UTF8.GetString($c.ms.ToArray())); $c.ms.SetLength(0) }
  }
  return , $out
}
function Close-DrbCdp($c) {
  if (-not $c) { return }
  try { $c.ws.Abort() } catch {}
  try { $c.ws.Dispose() } catch {}
}
function Invoke-DrbEventLoop([int]$port) {
  $ver = $null
  try { $ver = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/version" -TimeoutSec 3 } catch {}
  $script:loopResult = 'fallback'
  if (-not $ver -or -not $ver.webSocketDebuggerUrl) { Write-DrbLog 'cdp: browser endpoint not found'; return }
  $c = New-DrbCdp ([string]$ver.webSocketDebuggerUrl)
  if (-not $c) { return }
  Write-DrbLog 'cdp connected (event mode)'
  $tg = @{}     # targetId -> @{ url; title; sid; attaching; due; vw }
  $sids = @{}   # sessionId -> targetId
  $bindingOk = $false
  $nextWin = 0
  $nextAlive = 0
  $winDirty = $false
  $startedAt = [long]([DateTime]::UtcNow.Ticks / 10000)
  $goodChecks = 0
  try {
    Send-DrbCdp $c 'Target.setDiscoverTargets' @{ discover = $true } $null @{ k = 'discover' } | Out-Null
    while ($true) {
      $now = [long]([DateTime]::UtcNow.Ticks / 10000)
      foreach ($txt in (Read-DrbCdp $c 150)) {
        # 필요 없는 이벤트(Page.* 등)는 JSON 해석 없이 건너뛴다
        if ($txt.StartsWith('{"method":"') -and -not ($txt.StartsWith('{"method":"Target.') -or $txt.StartsWith('{"method":"Runtime.bindingCalled"'))) { continue }
        $o = $null
        try { $o = $txt | ConvertFrom-Json } catch { continue }
        if ($o.method) {
          switch ($o.method) {
            { $_ -eq 'Target.targetCreated' -or $_ -eq 'Target.targetInfoChanged' } {
              $i = $o.params.targetInfo
              if ($i.type -ne 'page') { break }
              $t = $tg[$i.targetId]
              if (-not $t) { $t = @{ url = ''; title = ''; sid = $null; attaching = $false; due = 0; vw = $false }; $tg[$i.targetId] = $t }
              if ($t.url -ne $i.url) { $t.url = [string]$i.url; $t.due = $now + 300; $t.vw = $false; $winDirty = $true }
              if ($t.title -ne $i.title) { $t.title = [string]$i.title; $winDirty = $true }
              if (-not $t.sid -and -not $t.attaching) {
                $t.attaching = $true
                Send-DrbCdp $c 'Target.attachToTarget' @{ targetId = $i.targetId; flatten = $true } $null @{ k = 'attach'; tid = $i.targetId } | Out-Null
              }
            }
            'Target.targetDestroyed' {
              $tid = $o.params.targetId
              if ($tg.ContainsKey($tid)) { if ($tg[$tid].sid) { $sids.Remove($tg[$tid].sid) }; $tg.Remove($tid); $winDirty = $true }
            }
            'Target.detachedFromTarget' {
              $sid = $o.params.sessionId
              if ($sids.ContainsKey($sid)) { $tid = $sids[$sid]; $sids.Remove($sid); if ($tg.ContainsKey($tid)) { $tg[$tid].sid = $null; $tg[$tid].attaching = $false } }
            }
            'Runtime.bindingCalled' {
              if ($o.params.name -eq '__drbNotify' -and $sids.ContainsKey($o.sessionId)) {
                $tg[$sids[$o.sessionId]].due = 0
                if (-not $bindingOk) { $bindingOk = $true; Write-DrbLog 'binding ok (instant updates)' }
              }
            }
          }
          continue
        }
        if (-not $o.id -or -not $c.pend.ContainsKey([int]$o.id)) { continue }
        $tag = $c.pend[[int]$o.id]
        $c.pend.Remove([int]$o.id)
        $t = if ($tag.tid) { $tg[$tag.tid] } else { $null }
        switch ($tag.k) {
          'attach' {
            if (-not $t) { break }
            $t.attaching = $false
            $sid = [string]$o.result.sessionId
            if (-not $sid) { Write-DrbLog ('cdp attach failed ' + $tag.tid + ' ' + ($o.error | ConvertTo-Json -Compress)); break }
            $t.sid = $sid
            $sids[$sid] = $tag.tid
            Send-DrbCdp $c 'Page.enable' @{} $sid $null | Out-Null
            Send-DrbCdp $c 'Runtime.addBinding' @{ name = '__drbNotify' } $sid $null | Out-Null
            if ($earlySrc) { Send-DrbCdp $c 'Page.addScriptToEvaluateOnNewDocument' @{ source = $earlySrc } $sid $null | Out-Null }
            $t.due = 0
          }
          'check' {
            if (-not $t) { break }
            $v = $o.result.result.value
            if (-not $v) { break }
            $state = $v | ConvertFrom-Json
            $goodChecks++
            if (-not $state.core) {
              if ($state.rs -ne 'loading') {
                Send-DrbCdp $c 'Runtime.evaluate' @{ expression = $injectExpr; returnByValue = $true } $t.sid @{ k = 'inject'; tid = $tag.tid } | Out-Null
                $t.due = $now + 1500
              } else { $t.due = $now + 300 }
              break
            }
            if ($t.url -notmatch $chatRe) { break }   # 미리보기 창 등은 상태를 쓰지 않는다
            if ([bool]$state.vw -ne $t.vw -or [int]$state.op -ne $script:lastOp) { $winDirty = $true }
            $t.vw = [bool]$state.vw
            $err = Use-DrbState $state $t.url
            if ($err) { Send-DrbCdp $c 'Runtime.evaluate' @{ expression = (Get-DrbFailExpr $err) } $t.sid $null | Out-Null }
          }
          'inject' { Write-DrbLog ('inject ' + $tag.tid + ' ' + $t.url + ' -> ' + $o.result.result.value) }
        }
      }
      # 상태 확인 (바인딩으로 당겨진 화면은 즉시)
      $every = if ($bindingOk) { 2500 } else { 1000 }
      foreach ($tid in @($tg.Keys)) {
        $t = $tg[$tid]
        if ($t.sid -and $t.url -match $doorayRe -and $now -ge $t.due) {
          Send-DrbCdp $c 'Runtime.evaluate' @{ expression = $checkExpr; returnByValue = $true } $t.sid @{ k = 'check'; tid = $tid } | Out-Null
          $t.due = $now + $every
        }
      }
      # 알림창 클릭 → 대화 화면에서 그 방 열기
      $clicks = Read-DrbToastClicks
      if ($clicks.Count) {
        $main = @($tg.Values | Where-Object { $_.sid -and $_.url -match $chatRe } | Sort-Object { if ($_.url -match '/messenger/?([?#]|$)') { 0 } else { 1 } }) | Select-Object -First 1
        foreach ($cid in $clicks) {
          if ($main) { Send-DrbCdp $c 'Runtime.evaluate' @{ expression = "window.__drbSkin&&window.__drbSkin.showChannel('$cid')" } $main.sid $null | Out-Null; Write-DrbLog "toast click $cid" }
        }
      }
      # 창 투명도·제목 표시줄: 바뀌면 바로, 아니면 2초마다 (새로 뜬 창 반영)
      if ($winDirty -or $now -ge $nextWin) {
        $pages = @($tg.Values | Where-Object { $_.url -match $doorayRe } | ForEach-Object { [pscustomobject]@{ url = $_.url; title = $_.title; vw = $_.vw } })
        Update-DrbWindows $pages $true
        $winDirty = $false
        $nextWin = $now + 2000
      }
      if ($now -ge $nextAlive) {
        if (-not (Test-DrbDoorayAlive)) { $script:loopResult = 'exit'; return }
        $nextAlive = $now + 2000
        # 연결은 됐는데 12초 동안 화면 상태를 한 번도 못 읽었으면(붙기 거부 등) 0.8초 확인 방식으로 넘어간다
        if ($goodChecks -eq 0 -and $now - $startedAt -gt 12000) {
          $pg = @(Get-DrbTargets $port | Where-Object { $_.type -eq 'page' -and $_.url -match $doorayRe })
          if ($pg.Count) { Write-DrbLog ('event mode got no page state (targets=' + $tg.Count + ') -> polling'); $script:loopResult = 'fallback'; return }
        }
      }
    }
  } catch {
    Write-DrbLog ('cdp loop error: ' + $_.Exception.Message)
    $script:loopResult = 'reconnect'
  } finally { Close-DrbCdp $c }
}

# ---------------- 방식 2: 0.8초 확인 (이벤트 연결이 안 될 때) ----------------
function Invoke-DrbPollLoop([int]$port) {
  Write-DrbLog 'polling mode'
  $noTargets = 0
  while (Test-DrbDoorayAlive) {
    $targets = Get-DrbTargets $port
    if (-not $targets) {
      $noTargets++
      if ($noTargets -eq 30) { Write-DrbLog "debug port $port not responding (WebView2 policy may block remote debugging)" }
      Start-Sleep -Seconds 2; continue
    }
    $pages = @()
    $main = $null
    foreach ($t in @($targets)) {
      if ($t.type -ne 'page' -or $t.url -notmatch $doorayRe -or -not $t.webSocketDebuggerUrl) { continue }
      $vw = $false
      $r = Invoke-DrbEvaluate $t.webSocketDebuggerUrl @($checkExpr)
      if ($r -and $r[0]) {
        $state = $r[0] | ConvertFrom-Json
        if (-not $state.core) {
          if ($state.rs -ne 'loading') {
            $res = Invoke-DrbEvaluate $t.webSocketDebuggerUrl @($injectExpr)
            Write-DrbLog ("inject " + $t.id + " " + $t.url + " -> " + ($res -join ','))
          }
        } elseif ($t.url -match $chatRe) {
          $vw = [bool]$state.vw
          if (-not $main) { $main = $t }
          $err = Use-DrbState $state $t.url
          if ($err) { Invoke-DrbEvaluate $t.webSocketDebuggerUrl @((Get-DrbFailExpr $err)) | Out-Null }
        }
      }
      $pages += [pscustomobject]@{ url = [string]$t.url; title = [string]$t.title; vw = $vw }
    }
    if ($main) {
      foreach ($cid in (Read-DrbToastClicks)) {
        $r2 = Invoke-DrbEvaluate $main.webSocketDebuggerUrl @("window.__drbSkin&&window.__drbSkin.showChannel('$cid')")
        Write-DrbLog "toast click $cid -> $($r2 -join ',')"
      }
    }
    Update-DrbWindows $pages $true
    Start-Sleep -Milliseconds 800
  }
}

# ---------------- 실행 ----------------
Start-Sleep -Seconds 2
$tries = 0
$mode = 'reconnect'
while ($mode -eq 'reconnect' -and $tries -lt 4 -and (Test-DrbDoorayAlive)) {
  $tries++
  Invoke-DrbEventLoop $port | Out-Null
  $mode = $script:loopResult
  if ($mode -eq 'reconnect') { Start-Sleep -Seconds 2 }
}
if ($mode -ne 'exit' -and (Test-DrbDoorayAlive)) { Invoke-DrbPollLoop $port }
Write-DrbLog 'Dooray exited, watcher stop'
$mutex.ReleaseMutex()
