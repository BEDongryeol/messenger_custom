# ===== Dooray Skin 설치 (Windows) =====
# 두 가지 방법으로 실행된다.
#  - DooraySkin-Setup.exe : 리소스로 든 payload 를 %APPDATA%\DooraySkin 에 먼저 풀고 이 스크립트를 숨김 PowerShell 로 실행
#  - DooraySkin-Setup.cmd : 앞부분에서 $EmbeddedFiles(이름→base64) 를 정의한 뒤 이 본문을 이어서 실행
# 이미 설치된 PC 에 다시 설치(업데이트)해도 안전하다: 구버전 감시자를 먼저 끝내고 파일을 덮어쓰며,
# 바로가기 백업은 처음 백업한 원본을 그대로 유지한다.
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$Mode = if ($env:DRB_MODE) { $env:DRB_MODE } else { 'install' }
$data = Join-Path $env:APPDATA 'DooraySkin'

if ($Mode -eq 'uninstall') {
  $u = Join-Path $data 'uninstall.ps1'
  if (Test-Path $u) { & $u; exit 0 } else { Write-Host 'Dooray Skin 이 설치되어 있지 않습니다.'; exit 0 }
}

Write-Host '== Dooray Skin 설치 =='

# 0) 구버전 감시자(launch.ps1) 와 Dooray 종료: 옛 감시자가 살아 있으면 뮤텍스를 쥔 채 메모리의 옛 core.js 를 계속 주입한다
$me = $PID
$old = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -match '(?i)DooraySkin\\(launch|toast-host)\.ps1' }
if ($old) {
  $old | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Write-Host "이전 Dooray Skin 감시자 종료: $(@($old).Count)개"
}
$running = Get-Process -Name DoorayMessenger -ErrorAction SilentlyContinue
if ($running) {
  Write-Host 'Dooray 를 종료합니다 (설치 후 다시 실행됩니다)'
  $running | Stop-Process -Force -ErrorAction SilentlyContinue
  for ($i = 0; $i -lt 40 -and (Get-Process -Name DoorayMessenger -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 250 }
}

# 1) 파일 풀기 (cmd 방식일 때만; exe 는 이미 풀어 놓았다)
New-Item -ItemType Directory -Force -Path $data | Out-Null
if (Get-Variable EmbeddedFiles -ErrorAction SilentlyContinue) {
  foreach ($k in $EmbeddedFiles.Keys) {
    [IO.File]::WriteAllBytes((Join-Path $data $k), [Convert]::FromBase64String($EmbeddedFiles[$k]))
  }
}
foreach ($f in @('core.js', 'common.ps1', 'launch.ps1', 'launch.vbs', 'uninstall.ps1')) {
  if (-not (Test-Path (Join-Path $data $f))) { Write-Host "[실패] $f 가 없습니다. 설치 파일이 손상되었습니다."; exit 1 }
}
. (Join-Path $data 'common.ps1')
$ver = ([regex]::Match((Get-Content (Join-Path $data 'core.js') -Raw -Encoding UTF8), "VERSION = '([\d.]+)'")).Groups[1].Value
if (-not $ver) { $ver = '0' }
Set-Content (Join-Path $data 'version.txt') $ver -Encoding UTF8
Write-Host "버전: $ver"

# 2) Dooray 찾기 (못 찾으면 파일 선택 창)
$exe = Find-DoorayExe -AllowPicker
if (-not $exe) { Write-Host '[실패] Dooray Messenger(DoorayMessenger.exe)를 찾지 못했습니다.'; exit 1 }
Set-Content (Join-Path $data 'dooray-path.txt') $exe -Encoding UTF8
Write-Host "Dooray: $exe"
Write-DrbLog "setup v$ver exe=$exe"

# 3) 기존 Dooray 바로가기 → Dooray Skin 으로 교체 (원본은 백업. 이미 교체된 것은 건너뜀)
$shell = New-Object -ComObject WScript.Shell
$wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
$launchVbs = Join-Path $data 'launch.vbs'
$backupPath = Join-Path $data 'shortcut-backup.json'
$backup = @{}
if (Test-Path $backupPath) {
  (Get-Content $backupPath -Raw -Encoding UTF8 | ConvertFrom-Json).psobject.Properties | ForEach-Object { $backup[$_.Name] = $_.Value }
}
$replaced = @()
$already = 0
foreach ($d in (Get-DrbShortcutDirs)) {
  foreach ($f in (Get-ChildItem $d -Filter *.lnk -Recurse -ErrorAction SilentlyContinue)) {
    try {
      $lnk = $shell.CreateShortcut($f.FullName)
      if ($lnk.Arguments -match '(?i)launch\.vbs') { $already++; continue }            # 이미 교체됨
      if (-not (Test-IsDoorayTarget $lnk.TargetPath)) { continue }
      if ($f.Name -match '(?i)uninstall|제거') { continue }
      if (-not $backup.ContainsKey($f.FullName)) {
        $backup[$f.FullName] = @{ Target = $lnk.TargetPath; Args = $lnk.Arguments; Icon = $lnk.IconLocation; Dir = $lnk.WorkingDirectory }
      }
      $lnk.TargetPath = $wscript
      $lnk.Arguments = '"' + $launchVbs + '"'
      $lnk.IconLocation = "$exe,0"
      $lnk.WorkingDirectory = $data
      $lnk.Save()   # 작업 표시줄 고정 아이콘도 같은 .lnk 를 쓰므로 그대로 Dooray Skin 으로 동작
      $replaced += $f.FullName
    } catch {
      Write-Host "  (건너뜀: $($f.FullName) - 관리자 권한 필요 또는 접근 불가)"
    }
  }
}
$backup | ConvertTo-Json -Depth 4 | Set-Content $backupPath -Encoding UTF8
Write-Host "교체한 바로가기: $($replaced.Count)개" + $(if ($already) { " (이미 교체된 $already 개는 유지)" } else { '' })
$replaced | ForEach-Object { Write-Host "  - $_" }
$runN = Update-DrbRunKey
if ($runN) { Write-Host "로그인 자동 실행 항목 교체: $runN 개" }

# 4) Dooray Skin 전용 바로가기 (시작 메뉴 항상, 바탕화면은 교체된 게 없을 때만)
function New-Lnk($path, $target, $arguments, $desc) {
  $s = $shell.CreateShortcut($path)
  $s.TargetPath = $target; $s.Arguments = $arguments; $s.IconLocation = "$exe,0"; $s.WorkingDirectory = $data; $s.Description = $desc
  $s.Save()
}
$programs = [Environment]::GetFolderPath('Programs')
New-Lnk (Join-Path $programs 'Dooray Skin.lnk') $wscript ('"' + $launchVbs + '"') 'Dooray Messenger + 배경 · 테마 색 · 다크 모드'
New-Lnk (Join-Path $programs 'Dooray Skin 제거.lnk') 'powershell.exe' ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $data 'uninstall.ps1') + '"') 'Dooray Skin 제거'
$desktop = [Environment]::GetFolderPath('Desktop')
if (-not ($replaced | Where-Object { $_ -like "$desktop*" }) -and -not (Test-Path (Join-Path $desktop 'Dooray Skin.lnk'))) {
  $desktopHasDooray = Get-ChildItem $desktop -Filter *.lnk -ErrorAction SilentlyContinue | Where-Object { try { $shell.CreateShortcut($_.FullName).Arguments -match '(?i)launch\.vbs' } catch { $false } }
  if (-not $desktopHasDooray) { New-Lnk (Join-Path $desktop 'Dooray Skin.lnk') $wscript ('"' + $launchVbs + '"') 'Dooray Messenger + 배경 · 테마 색 · 다크 모드' }
}

# 5) 설정 > 앱 목록(프로그램 추가/제거)에 등록 (현재 사용자만, 관리자 권한 불필요)
try {
  $uk = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DooraySkin'
  New-Item -Path $uk -Force | Out-Null
  Set-ItemProperty $uk 'DisplayName' 'Dooray Skin'
  Set-ItemProperty $uk 'DisplayVersion' $ver
  Set-ItemProperty $uk 'Publisher' 'Dooray Skin (사내 배포)'
  Set-ItemProperty $uk 'InstallLocation' $data
  Set-ItemProperty $uk 'DisplayIcon' "$exe,0"
  Set-ItemProperty $uk 'UninstallString' ('powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $data 'uninstall.ps1') + '"')
  Set-ItemProperty $uk 'InstallDate' (Get-Date -Format 'yyyyMMdd')
  Set-ItemProperty $uk 'NoModify' 1 -Type DWord
  Set-ItemProperty $uk 'NoRepair' 1 -Type DWord
} catch { Write-Host "  (앱 목록 등록 건너뜀: $($_.Exception.Message))" }

Write-Host ''
Write-Host '설치 완료. 기존 Dooray 아이콘(작업 표시줄/바탕화면/시작 메뉴)으로 실행해도 Dooray Skin 이 적용됩니다.'
Write-Host 'Dooray 를 지금 다시 실행합니다...'
Start-Process -FilePath $wscript -ArgumentList ('"' + $launchVbs + '"')
exit 0
