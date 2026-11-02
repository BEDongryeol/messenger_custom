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
$checkExpr = "JSON.stringify({core: !!window.__drbCore, op: (window.__drbSkin && window.__drbSkin.config && window.__drbSkin.config.global && window.__drbSkin.config.global.windowOpacity) || 100, btn: !!document.querySelector('[data-drb-sidebar-btn]')})"

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
      if (-not $seen.ContainsKey($t.id)) { $seen[$t.id] = 1; Write-DrbLog ("active " + $t.url + " btn=" + $state.btn) }
    }
  }
  if ($null -ne $op -and ($op -ne $lastOp -or $op -lt 100)) {
    $n = Set-DrbOpacity $op
    if ($op -ne $lastOp) { Write-DrbLog "opacity $op% -> $n window(s)" }
    $lastOp = $op
  }
  Start-Sleep -Milliseconds 1500
}
Write-DrbLog 'Dooray exited, watcher stop'
$mutex.ReleaseMutex()
