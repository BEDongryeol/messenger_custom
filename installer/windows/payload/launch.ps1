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
# 페이지의 설정(window.__drbSkin.config.global)에서 창 투명도, 다크 모드(제목 표시줄), 메뉴 바 숨기기를 읽는다
$checkExpr = "JSON.stringify((g=>({core: !!window.__drbCore, op: (window.__drbSkin&&window.__drbSkin.effectiveOpacity&&window.__drbSkin.effectiveOpacity())||(g&&g.windowOpacity)||100, dark: !!(g&&g.dark&&g.dark.enabled&&g.dark.titleBar!==false), level: (g&&g.dark&&g.dark.level)||11, hideMenu: !!(g&&g.hideMenu), btn: !!document.querySelector('[data-drb-sidebar-btn]'), upd: window.__drbUpdateRequest||null, alive: (window.__drbWatcherAlive=Date.now(), 1), toasts: (window.__drbToastQueue||[]).splice(0)}))(window.__drbSkin&&window.__drbSkin.config&&window.__drbSkin.config.global))"

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

# 자동 업데이트: 페이지에서 [업데이트] 를 누르면 window.__drbUpdateRequest = { url, version } 가 생긴다.
# Setup 을 받아 실행하면 setup.ps1 이 이 감시자와 Dooray 를 끄고 덮어쓴 뒤 다시 실행한다.
# PowerShell 로 받은 파일에는 인터넷 표시(MOTW)가 붙지 않아 SmartScreen 경고가 없다.
function Start-DrbUpdate($upd, [string]$wsUrl) {
  $url = [string]$upd.url
  if ($url -notmatch '^https://github\.com/BEDongryeol/messenger_custom/releases/download/[^/]+/DooraySkin-Setup\.(exe|cmd)$') {
    Write-DrbLog "update url rejected: $url"
    Invoke-DrbEvaluate $wsUrl @("window.__drbSkin&&window.__drbSkin.updateFailed&&window.__drbSkin.updateFailed('허용되지 않은 주소')") | Out-Null
    return $false
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
    Invoke-DrbEvaluate $wsUrl @("window.__drbSkin&&window.__drbSkin.updateFailed&&window.__drbSkin.updateFailed('다운로드 실패')") | Out-Null
    return $false
  }
  Write-DrbLog "update run $dst"
  if ($ext -eq '.exe') { Start-Process -FilePath $dst }
  else { Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c "' + $dst + '"') }
  return $true
}
$updating = $false

$seen = @{}
$lastOp = 100
$noTargets = 0
Start-Sleep -Seconds 2
while (Get-Process -Name DoorayMessenger -ErrorAction SilentlyContinue) {
  $targets = Get-DrbTargets $port
  if (-not $targets) {
    $noTargets++
    if ($noTargets -eq 30) { Write-DrbLog "debug port $port not responding (WebView2 policy may block remote debugging)" }
    Start-Sleep -Seconds 2; continue
  }
  $op = $null
  $chrome = $null
  # 이미지·파일 미리보기 창은 투명도에서 제외: 디버그 대상 제목으로 창을 찾는다
  $opaqueTitles = @(@($targets) | Where-Object { $_.url -match '/messenger/image/\d+/\d+|/preview-pages/' -and $_.title } | ForEach-Object { [string]$_.title })
  foreach ($t in @($targets)) {
    if ($t.type -ne 'page' -or $t.url -notmatch '^https://([a-z0-9-]+\.)*dooray\.com/' -or -not $t.webSocketDebuggerUrl) { continue }
    $r = Invoke-DrbEvaluate $t.webSocketDebuggerUrl @($checkExpr)
    if (-not $r -or -not $r[0]) { continue }
    $state = $r[0] | ConvertFrom-Json
    if (-not $state.core) {
      $res = Invoke-DrbEvaluate $t.webSocketDebuggerUrl @($injectExpr)
      Write-DrbLog ("inject " + $t.id + " " + $t.url + " -> " + ($res -join ','))
    } else {
      $op = [int]$state.op
      $chrome = @{ dark = [bool]$state.dark; level = [int]$state.level; menu = [bool]$state.hideMenu }
      if (-not $seen.ContainsKey($t.id)) { $seen[$t.id] = 1; Write-DrbLog ("active " + $t.url + " btn=" + $state.btn) }
      if ($state.upd -and -not $updating) { $updating = Start-DrbUpdate $state.upd $t.webSocketDebuggerUrl }
      if ($state.toasts -and @($state.toasts).Count) { Send-DrbToasts $state.toasts; Write-DrbLog ("toast x" + @($state.toasts).Count) }
      foreach ($cf in (Get-ChildItem $toastClick -Filter *.json -ErrorAction SilentlyContinue)) {
        try {
          $cid = ((Get-Content $cf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).channelId -replace '[^\w-]', '')
          Remove-Item $cf.FullName -Force -ErrorAction SilentlyContinue
          if ($cid) { $r2 = Invoke-DrbEvaluate $t.webSocketDebuggerUrl @("window.__drbSkin&&window.__drbSkin.showChannel('$cid')"); Write-DrbLog "toast click $cid -> $($r2 -join ',')" }
        } catch { Remove-Item $cf.FullName -Force -ErrorAction SilentlyContinue }
      }
    }
  }
  if ($null -ne $op -and ($op -ne $lastOp -or $op -lt 100)) {
    $n = Set-DrbOpacity $op $opaqueTitles
    if ($op -ne $lastOp) { Write-DrbLog "opacity $op% -> $n window(s)" }
    $lastOp = $op
  }
  if ($chrome) {
    $n = Set-DrbWindowChrome $chrome.dark $chrome.level $chrome.menu
    if ($n) { Write-DrbLog "chrome dark=$($chrome.dark) level=$($chrome.level)% hideMenu=$($chrome.menu) -> $n change(s)" }
  }
  Start-Sleep -Milliseconds 800   # 알림창 지연을 줄이려고 1.5초 → 0.8초
}
Write-DrbLog 'Dooray exited, watcher stop'
$mutex.ReleaseMutex()
