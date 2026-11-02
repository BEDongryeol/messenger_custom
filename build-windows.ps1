# Windows 배포 파일 빌드 (Windows 에서 실행. 외부 도구 없이 Windows 내장 csc.exe 사용)
#   powershell -NoProfile -ExecutionPolicy Bypass -File build-windows.ps1
# 결과 (dist\)
#   DooraySkin-Setup.exe      : 더블클릭 설치 프로그램 (payload 내장, 진행 창 표시, /uninstall 지원)
#   DooraySkin-Setup.cmd      : 같은 내용의 cmd 설치기 (exe 가 막힐 때)
#   DooraySkin-windows.zip    : exe + cmd + README.txt (메신저/메일이 exe 첨부를 막을 때)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$utf8 = New-Object System.Text.UTF8Encoding($false)
$utf8bom = New-Object System.Text.UTF8Encoding($true)
function Read-Text($p) { [IO.File]::ReadAllText($p, $utf8) }
function Crlf($s) { ($s -replace "`r?`n", "`r`n") }

$ver = ([regex]::Match((Read-Text 'src\core.js'), "VERSION = '([\d.]+)'")).Groups[1].Value
if (-not $ver) { throw 'src\core.js 에서 VERSION 을 찾지 못했습니다.' }
$dist = Join-Path $PSScriptRoot 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$tmp = Join-Path $env:TEMP ('dooray-skin-build-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null

# ---------- payload (ps1: UTF-8 BOM + CRLF, 나머지: CRLF) ----------
$P = 'installer\windows\payload'
$files = @('core.js', 'common.ps1', 'launch.ps1', 'launch.vbs', 'uninstall.ps1', 'setup.ps1')
foreach ($f in @('common.ps1', 'launch.ps1', 'uninstall.ps1', 'setup.ps1')) { [IO.File]::WriteAllText("$tmp\$f", (Crlf (Read-Text "$P\$f")), $utf8bom) }
[IO.File]::WriteAllText("$tmp\launch.vbs", (Crlf (Read-Text "$P\launch.vbs")), $utf8)
Copy-Item 'src\core.js' "$tmp\core.js"

# ---------- exe ----------
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw 'csc.exe(.NET Framework 4) 를 찾지 못했습니다.' }

# 아이콘: 이 PC 에 Dooray 가 있으면 그 아이콘을 사용 (없으면 기본 아이콘)
$args = @('/nologo', '/target:winexe', '/optimize+', "/out:$dist\DooraySkin-Setup.exe")
$doorayExe = @("$env:ProgramFiles\NHN Corporation\Dooray Messenger\DoorayMessenger.exe", "$env:ProgramFiles\Dooray Messenger\DoorayMessenger.exe", "$env:LOCALAPPDATA\Programs\Dooray Messenger\DoorayMessenger.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($doorayExe) {
  Add-Type -AssemblyName System.Drawing
  $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($doorayExe)
  $fs = [IO.File]::Create("$tmp\app.ico"); $ico.Save($fs); $fs.Close()
  $args += "/win32icon:$tmp\app.ico"
}
foreach ($f in $files) { $args += "/resource:$tmp\$f,$f" }
@"
using System.Reflection;
[assembly: AssemblyTitle("Dooray Skin Setup")]
[assembly: AssemblyProduct("Dooray Skin")]
[assembly: AssemblyDescription("Dooray Messenger 배경 · 테마 색 · 다크 모드 (내 화면에만 적용)")]
[assembly: AssemblyVersion("$ver.0")]
[assembly: AssemblyFileVersion("$ver.0")]
"@ | Out-File "$tmp\AssemblyInfo.cs" -Encoding utf8
& $csc @args 'installer\windows\DooraySkinSetup.cs' "$tmp\AssemblyInfo.cs"
if ($LASTEXITCODE -ne 0) { throw "csc 실패 ($LASTEXITCODE)" }

# ---------- cmd (head + base64 payload + setup.ps1 본문) ----------
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append((Crlf (Read-Text 'installer\windows\setup-head.cmd')))
[void]$sb.Append("#DRB_PS_BEGIN`r`n# Dooray Skin v$ver`r`n`$EmbeddedFiles = @{`r`n")
foreach ($f in $files) { [void]$sb.Append("  '$f' = '" + [Convert]::ToBase64String([IO.File]::ReadAllBytes("$tmp\$f")) + "'`r`n") }
[void]$sb.Append("}`r`n")
[void]$sb.Append((Crlf (Read-Text "$P\setup.ps1")))
[IO.File]::WriteAllText("$dist\DooraySkin-Setup.cmd", $sb.ToString(), $utf8)

# ---------- zip ----------
$W = Join-Path $tmp 'windows'; New-Item -ItemType Directory -Path $W | Out-Null
Copy-Item "$dist\DooraySkin-Setup.exe", "$dist\DooraySkin-Setup.cmd" $W
[IO.File]::WriteAllText("$W\README.txt", (Crlf (Read-Text 'installer\windows\설치방법.txt')), $utf8bom)
Remove-Item "$dist\DooraySkin-windows.zip" -ErrorAction SilentlyContinue
Compress-Archive -Path "$W\*" -DestinationPath "$dist\DooraySkin-windows.zip"

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "built v$ver"
Get-ChildItem $dist | Where-Object { $_.Name -match 'windows|Setup' } | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
