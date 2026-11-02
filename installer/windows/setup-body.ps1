# ===== Dooray Skin Setup (Windows) 본문 =====
# DooraySkin-Setup.cmd 안에 포함되어 실행된다. 앞부분에서 $EmbeddedFiles(이름→base64)가 정의된다.
$ErrorActionPreference = 'Stop'
$Mode = if ($env:DRB_MODE) { $env:DRB_MODE } else { 'install' }
$data = Join-Path $env:APPDATA 'DooraySkin'

if ($Mode -eq 'uninstall') {
  $u = Join-Path $data 'uninstall.ps1'
  if (Test-Path $u) { & $u; exit 0 } else { Write-Host 'Dooray Skin 이 설치되어 있지 않습니다.'; exit 0 }
}

Write-Host '== Dooray Skin 설치 =='

# 1) 파일 풀기
New-Item -ItemType Directory -Force -Path $data | Out-Null
foreach ($k in $EmbeddedFiles.Keys) {
  [IO.File]::WriteAllBytes((Join-Path $data $k), [Convert]::FromBase64String($EmbeddedFiles[$k]))
}
. (Join-Path $data 'common.ps1')

# 2) Dooray 찾기 (못 찾으면 파일 선택 창)
$exe = Find-DoorayExe -AllowPicker
if (-not $exe) { Write-Host '[실패] Dooray Messenger(DoorayMessenger.exe)를 찾지 못했습니다.'; exit 1 }
Set-Content (Join-Path $data 'dooray-path.txt') $exe -Encoding UTF8
Write-Host "Dooray: $exe"
Write-DrbLog "setup exe=$exe"

# 3) 기존 Dooray 바로가기 → Dooray Skin 으로 교체 (원본은 백업)
$shell = New-Object -ComObject WScript.Shell
$wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
$launchVbs = Join-Path $data 'launch.vbs'
$backupPath = Join-Path $data 'shortcut-backup.json'
$backup = @{}
if (Test-Path $backupPath) {
  (Get-Content $backupPath -Raw -Encoding UTF8 | ConvertFrom-Json).psobject.Properties | ForEach-Object { $backup[$_.Name] = $_.Value }
}
$replaced = @()
foreach ($d in (Get-DrbShortcutDirs)) {
  foreach ($f in (Get-ChildItem $d -Filter *.lnk -Recurse -ErrorAction SilentlyContinue)) {
    try {
      $lnk = $shell.CreateShortcut($f.FullName)
      if ($lnk.Arguments -match '(?i)launch\.vbs') { continue }            # 이미 교체됨
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
Write-Host "교체한 바로가기: $($replaced.Count)개"
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
New-Lnk (Join-Path $programs 'Dooray Skin.lnk') $wscript ('"' + $launchVbs + '"') 'Dooray Messenger + 대화방 배경'
New-Lnk (Join-Path $programs 'Dooray Skin 제거.lnk') 'powershell.exe' ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $data 'uninstall.ps1') + '"') 'Dooray Skin 제거'
$desktop = [Environment]::GetFolderPath('Desktop')
if (-not ($replaced | Where-Object { $_ -like "$desktop*" })) {
  New-Lnk (Join-Path $desktop 'Dooray Skin.lnk') $wscript ('"' + $launchVbs + '"') 'Dooray Messenger + 대화방 배경'
}

Write-Host ''
Write-Host '설치 완료. 기존 Dooray 아이콘(작업 표시줄/바탕화면/시작 메뉴)으로 실행해도 배경 기능이 적용됩니다.'
Write-Host 'Dooray 를 지금 다시 실행합니다...'
Start-Process -FilePath $wscript -ArgumentList ('"' + $launchVbs + '"')
exit 0
