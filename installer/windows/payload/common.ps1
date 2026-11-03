# Dooray Skin (Windows) 공용 함수
# Windows Dooray Messenger 는 Electron 이 아니라 C++ + WebView2 앱이다 (C:\Program Files\Dooray Messenger\DoorayMessenger.exe).
# WebView2 공식 환경변수 WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS 로 로컬 디버그 포트를 열고, CDP 로 core.js 를 주입한다.

$script:DrbData = Join-Path $env:APPDATA 'DooraySkin'
$script:DrbLog = Join-Path $script:DrbData 'launcher.log'

function Write-DrbLog([string]$msg) {
  try { Add-Content -Path $script:DrbLog -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8 } catch {}
}

function Test-DoorayExePath($p) {
  return ($p -and (Test-Path -LiteralPath $p -PathType Leaf) -and ($p -match '(?i)\.exe$') -and ($p -notmatch '(?i)Drive|Uninst|Update|Installer|AppLauncher'))
}

# Dooray Messenger 실행 파일 찾기: 저장값 → 실행 중 프로세스 → 알려진 경로 → 레지스트리 → 바로가기 → 탐색 → 직접 선택
function Find-DoorayExe([switch]$AllowPicker) {
  $saved = Join-Path $script:DrbData 'dooray-path.txt'
  if (Test-Path $saved) {
    $p = (Get-Content $saved -Raw -Encoding UTF8).Trim()
    if (Test-DoorayExePath $p) { return $p }
  }
  foreach ($n in @('DoorayMessenger', 'Dooray Messenger')) {
    $pr = Get-Process -Name $n -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1
    if ($pr -and (Test-DoorayExePath $pr.Path)) { return $pr.Path }
  }
  $roots = @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:LOCALAPPDATA\Programs", $env:LOCALAPPDATA) | Where-Object { $_ } | Select-Object -Unique
  foreach ($r in $roots) {
    foreach ($d in @('Dooray Messenger', 'Dooray! Messenger', 'DoorayMessenger', 'NHN Dooray\Dooray Messenger')) {
      $p = Join-Path (Join-Path $r $d) 'DoorayMessenger.exe'
      if (Test-DoorayExePath $p) { return $p }
    }
  }
  $keys = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
  foreach ($e in (Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -eq 'DoorayMessenger' -or $_.DisplayName -match 'Dooray.*Messenger|두레이.*메신저' })) {
    $loc = if ($e.InstallLocation) { $e.InstallLocation.Trim('"') } else { $null }
    $icon = if ($e.DisplayIcon) { ($e.DisplayIcon -split ',')[0].Trim('"') } else { $null }
    foreach ($p in @($icon, $(if ($loc -and $icon) { Join-Path $loc (Split-Path $icon -Leaf) }), $(if ($loc) { Join-Path $loc 'DoorayMessenger.exe' }))) {
      if (Test-DoorayExePath $p) { return $p }
    }
  }
  $shell = New-Object -ComObject WScript.Shell
  foreach ($d in (Get-DrbShortcutDirs)) {
    foreach ($f in (Get-ChildItem $d -Filter *.lnk -Recurse -ErrorAction SilentlyContinue)) {
      try { $t = $shell.CreateShortcut($f.FullName).TargetPath } catch { continue }
      if ($t -match '(?i)\\DoorayMessenger\.exe$' -and (Test-DoorayExePath $t)) { return $t }
    }
  }
  foreach ($r in $roots) {
    $hit = Get-ChildItem $r -Filter 'DoorayMessenger.exe' -Recurse -Depth 3 -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { return $hit.FullName }
  }
  if ($AllowPicker) {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = 'Dooray Messenger 실행 파일(DoorayMessenger.exe)을 선택해 주세요'
    $dlg.Filter = 'Dooray Messenger|DoorayMessenger.exe;*.exe'
    $dlg.InitialDirectory = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK -and (Test-DoorayExePath $dlg.FileName)) { return $dlg.FileName }
  }
  return $null
}

function Get-DrbShortcutDirs {
  @(
    [Environment]::GetFolderPath('Desktop'),
    "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar",
    "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\StartMenu",
    [Environment]::GetFolderPath('Programs'),
    [Environment]::GetFolderPath('Startup'),
    [Environment]::GetFolderPath('CommonDesktopDirectory'),
    [Environment]::GetFolderPath('CommonPrograms')
  ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
}

function Test-IsDoorayTarget([string]$target) {
  return ($target -match '(?i)\\DoorayMessenger\.exe$' -or $target -match '(?i)\\Dooray( |! )Messenger\\[^\\]+\.exe$') -and ($target -notmatch '(?i)Drive|Uninst|Installer')
}

# 로그인 시 자동 실행(HKCU Run)에 Dooray 가 있으면 Skin 런처로 교체 (Dooray 가 다시 써도 런처 실행 때마다 재적용)
function Update-DrbRunKey {
  $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
  $backupPath = Join-Path $script:DrbData 'run-backup.json'
  $launch = '"' + (Join-Path $env:WINDIR 'System32\wscript.exe') + '" "' + (Join-Path $script:DrbData 'launch.vbs') + '"'
  $backup = @{}
  if (Test-Path $backupPath) { (Get-Content $backupPath -Raw -Encoding UTF8 | ConvertFrom-Json).psobject.Properties | ForEach-Object { $backup[$_.Name] = $_.Value } }
  $props = Get-ItemProperty $runKey -ErrorAction SilentlyContinue
  if (-not $props) { return 0 }
  $n = 0
  foreach ($p in $props.psobject.Properties) {
    if ($p.Name -like 'PS*') { continue }
    $v = [string]$p.Value
    if ($v -match '(?i)DoorayMessenger\.exe' -and $v -notmatch '(?i)launch\.vbs') {
      if (-not $backup.ContainsKey($p.Name)) { $backup[$p.Name] = $v }
      Set-ItemProperty -Path $runKey -Name $p.Name -Value $launch
      $n++
    }
  }
  if ($n) { $backup | ConvertTo-Json | Set-Content $backupPath -Encoding UTF8; Write-DrbLog "run key replaced: $n" }
  return $n
}

# ---------------- CDP (Chrome DevTools Protocol) ----------------
function Receive-DrbWsText($ws, [int]$timeoutMs) {
  $buf = New-Object byte[] 65536
  $ms = New-Object IO.MemoryStream
  do {
    $seg = New-Object 'ArraySegment[byte]' (, $buf)
    $t = $ws.ReceiveAsync($seg, [Threading.CancellationToken]::None)
    if (-not $t.Wait($timeoutMs)) { return $null }
    $r = $t.Result
    if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { return $null }
    $ms.Write($buf, 0, $r.Count)
  } while (-not $r.EndOfMessage)
  return [Text.Encoding]::UTF8.GetString($ms.ToArray())
}

# $expressions 를 순서대로 Runtime.evaluate 하고 각 결과 value 를 배열로 반환
function Invoke-DrbEvaluate([string]$wsUrl, [string[]]$expressions) {
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $none = [Threading.CancellationToken]::None
  $out = @()
  try {
    if (-not $ws.ConnectAsync([Uri]$wsUrl, $none).Wait(5000)) { return $null }
    $id = 0
    foreach ($expr in $expressions) {
      $id++
      $msg = @{ id = $id; method = 'Runtime.evaluate'; params = @{ expression = $expr; returnByValue = $true } } | ConvertTo-Json -Depth 5 -Compress
      $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
      $seg = New-Object 'ArraySegment[byte]' (, $bytes)
      $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $none).Wait(5000) | Out-Null
      $val = $null
      while ($true) {
        $text = Receive-DrbWsText $ws 15000
        if ($null -eq $text) { break }
        $obj = $text | ConvertFrom-Json
        if ($obj.id -eq $id) { $val = $obj.result.result.value; break }
      }
      $out += , $val
    }
    try { $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, '', $none).Wait(2000) | Out-Null } catch {}
  } catch {
    Write-DrbLog ("cdp error: " + $_.Exception.Message)
    return $null
  } finally { $ws.Dispose() }
  return , $out
}

function Get-DrbTargets([int]$port) {
  try { return Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list" -TimeoutSec 3 } catch { return $null }
}

# ---------------- 창 투명도 / 제목 표시줄 다크 / 메뉴 바 (Win32) ----------------
function Initialize-DrbWin32 {
  if ('DRB.Win' -as [type]) { return }
  Add-Type -Namespace DRB -Name Win -MemberDefinition @'
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] public static extern System.IntPtr GetWindowLongPtr(System.IntPtr h, int i);
[System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] public static extern System.IntPtr SetWindowLongPtr(System.IntPtr h, int i, System.IntPtr v);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetLayeredWindowAttributes(System.IntPtr h, uint key, byte alpha, uint flags);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetMenu(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetMenu(System.IntPtr h, System.IntPtr m);
[System.Runtime.InteropServices.DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr h, int attr, ref int val, int size);
public static System.Collections.Generic.List<System.IntPtr> ListWindows(uint pid) {
  var list = new System.Collections.Generic.List<System.IntPtr>();
  EnumWindows(delegate (System.IntPtr h, System.IntPtr l) {
    uint p; GetWindowThreadProcessId(h, out p);
    if (p == pid && IsWindowVisible(h)) list.Add(h);
    return true;
  }, System.IntPtr.Zero);
  return list;
}
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int max);
// 제목에 exclude 중 하나라도 들어 있는 창(이미지·파일 미리보기)은 불투명(255)으로 둔다
public static int SetAlphaForPidEx(uint pid, byte alpha, string[] exclude) {
  int n = 0;
  EnumWindows(delegate (System.IntPtr h, System.IntPtr l) {
    uint p; GetWindowThreadProcessId(h, out p);
    if (p == pid && IsWindowVisible(h)) {
      byte a = alpha;
      if (exclude != null && exclude.Length > 0) {
        var sb = new System.Text.StringBuilder(512);
        GetWindowText(h, sb, 512);
        string t = sb.ToString();
        foreach (string x in exclude) { if (!string.IsNullOrEmpty(x) && t.Contains(x)) { a = 255; break; } }
      }
      long ex = GetWindowLongPtr(h, -20).ToInt64();
      if ((ex & 0x80000) == 0) SetWindowLongPtr(h, -20, new System.IntPtr(ex | 0x80000));
      SetLayeredWindowAttributes(h, 0, a, 2);
      n++;
    }
    return true;
  }, System.IntPtr.Zero);
  return n;
}
public static int SetAlphaForPid(uint pid, byte alpha) {
  int n = 0;
  EnumWindows(delegate (System.IntPtr h, System.IntPtr l) {
    uint p; GetWindowThreadProcessId(h, out p);
    if (p == pid && IsWindowVisible(h)) {
      long ex = GetWindowLongPtr(h, -20).ToInt64();
      if ((ex & 0x80000) == 0) SetWindowLongPtr(h, -20, new System.IntPtr(ex | 0x80000));
      SetLayeredWindowAttributes(h, 0, alpha, 2);
      n++;
    }
    return true;
  }, System.IntPtr.Zero);
  return n;
}
'@
}

function Set-DrbOpacity([int]$percent, [string[]]$exclude = @()) {
  Initialize-DrbWin32
  $alpha = [byte][Math]::Round([Math]::Max(30, [Math]::Min(100, $percent)) * 2.55)
  $n = 0
  foreach ($pr in (Get-Process -Name DoorayMessenger -ErrorAction SilentlyContinue)) { $n += [DRB.Win]::SetAlphaForPidEx([uint32]$pr.Id, $alpha, [string[]]@($exclude)) }
  return $n
}

# 창 제목 표시줄 다크(DWMWA_USE_IMMERSIVE_DARK_MODE=20, 캡션 색 DWMWA_CAPTION_COLOR=35 는 Windows 11) + 메뉴 바 숨기기/복원.
# 외부 프로세스에서도 DwmSetWindowAttribute / SetMenu 가 동작한다. 적용 상태를 창 핸들별로 기억해 바뀔 때만 호출.
$script:DrbChrome = @{}   # hwnd → "dark|level"
$script:DrbMenus = @{}    # hwnd → 숨기기 전 메뉴 핸들
function Set-DrbWindowChrome([bool]$dark, [int]$level, [bool]$hideMenu) {
  Initialize-DrbWin32
  $n = 0
  foreach ($pr in (Get-Process -Name DoorayMessenger -ErrorAction SilentlyContinue)) {
    foreach ($h in [DRB.Win]::ListWindows([uint32]$pr.Id)) {
      $k = [string]$h
      $key = "$dark|$level"
      if ($script:DrbChrome[$k] -ne $key) {
        $v = [int]$dark
        [DRB.Win]::DwmSetWindowAttribute($h, 20, [ref]$v, 4) | Out-Null
        if ($dark) { $g = [int][Math]::Round(255 * $level / 100); $c = ($g -shl 16) -bor ($g -shl 8) -bor $g } else { $c = -1 }  # -1 = 기본색
        [DRB.Win]::DwmSetWindowAttribute($h, 35, [ref]$c, 4) | Out-Null
        $script:DrbChrome[$k] = $key
        $n++
      }
      $m = [DRB.Win]::GetMenu($h)
      if ($hideMenu -and $m -ne [IntPtr]::Zero) {
        $script:DrbMenus[$k] = $m
        [DRB.Win]::SetMenu($h, [IntPtr]::Zero) | Out-Null
        $n++
      } elseif (-not $hideMenu -and $m -eq [IntPtr]::Zero -and $script:DrbMenus.ContainsKey($k)) {
        [DRB.Win]::SetMenu($h, $script:DrbMenus[$k]) | Out-Null
        $script:DrbMenus.Remove($k)
        $n++
      }
    }
  }
  return $n
}
