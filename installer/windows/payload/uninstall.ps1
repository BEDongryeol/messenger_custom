# Dooray Skin 제거 (Windows): 감시자 종료, 바로가기·자동실행을 원래 Dooray 로 되돌리고 파일·앱 목록 등록 삭제
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$data = Join-Path $env:APPDATA 'DooraySkin'
$me = $PID
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -match '(?i)DooraySkin\\(launch|toast-host)\.ps1' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
$shell = New-Object -ComObject WScript.Shell
$restored = 0
$bp = Join-Path $data 'shortcut-backup.json'
if (Test-Path $bp) {
  $b = Get-Content $bp -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($p in $b.psobject.Properties) {
    if (-not (Test-Path -LiteralPath $p.Name)) { continue }
    try {
      $lnk = $shell.CreateShortcut($p.Name)
      $lnk.TargetPath = $p.Value.Target; $lnk.Arguments = $p.Value.Args
      if ($p.Value.Icon) { $lnk.IconLocation = $p.Value.Icon }
      $lnk.WorkingDirectory = $p.Value.Dir
      $lnk.Save(); $restored++
    } catch {}
  }
}
$rb = Join-Path $data 'run-backup.json'
if (Test-Path $rb) {
  $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
  (Get-Content $rb -Raw -Encoding UTF8 | ConvertFrom-Json).psobject.Properties | ForEach-Object { Set-ItemProperty -Path $runKey -Name $_.Name -Value $_.Value }
}
$programs = [Environment]::GetFolderPath('Programs')
$desktop = [Environment]::GetFolderPath('Desktop')
Remove-Item (Join-Path $desktop 'Dooray Skin.lnk'), (Join-Path $programs 'Dooray Skin.lnk'), (Join-Path $programs 'Dooray Skin 제거.lnk') -ErrorAction SilentlyContinue
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DooraySkin' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $data -Recurse -Force -ErrorAction SilentlyContinue
$msg = "Dooray Skin 을 제거했습니다.`n바로가기 $restored 개를 원래 Dooray 로 되돌렸습니다.`nDooray 를 종료 후 다시 켜면 원래 상태가 됩니다."
Write-Host $msg
if (-not $env:DRB_SETUP_EXE) {   # 시작 메뉴 "Dooray Skin 제거"(숨김 창)로 실행됐을 때만 알림 창
  Add-Type -AssemblyName PresentationFramework
  [System.Windows.MessageBox]::Show($msg, 'Dooray Skin') | Out-Null
}
exit 0
