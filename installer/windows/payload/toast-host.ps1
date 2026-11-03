# Dooray Skin 알림창 (Windows). launch.ps1(감시자)이 숨김 PowerShell(-STA)로 한 번 띄우고 Dooray 가 꺼지면 스스로 종료한다.
#  - %APPDATA%\DooraySkin\toast\in\*.json  : 띄울 알림 { title, body, channelId, bg, fg, sub, accent }
#  - %APPDATA%\DooraySkin\toast\click\*.json : 클릭한 알림의 { channelId } → 감시자가 그 대화방을 연다
# Dooray 원래 알림창(DoorayMessenger.ToastWnd)은 직접 그린 밝은 창이라 다크 모드가 닿지 않아 이 창으로 대신 보여 준다.
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\DooraySkinToastHost', [ref]$created)
if (-not $created) { exit 0 }

$script:data = Join-Path $env:APPDATA 'DooraySkin'
$script:inDir = Join-Path $script:data 'toast\in'
$script:clickDir = Join-Path $script:data 'toast\click'
New-Item -ItemType Directory -Force -Path $script:inDir, $script:clickDir | Out-Null

if (-not ('DRB.ToastApi' -as [type])) {
  Add-Type -Namespace DRB -Name ToastApi -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("gdi32.dll")] public static extern IntPtr CreateRoundRectRgn(int l, int t, int r, int b, int w, int h);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
'@
}

$script:toasts = New-Object System.Collections.ArrayList
$script:W = 360
$script:H = 88
$script:GAP = 10

function Get-DrbColor([string]$hex, [System.Drawing.Color]$fallback) {
  try { if ($hex -match '^#[0-9a-fA-F]{6}$') { return [System.Drawing.ColorTranslator]::FromHtml($hex) } } catch {}
  return $fallback
}

function Update-DrbToastLayout {
  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $i = 0
  foreach ($f in @($script:toasts)) {
    if ($f.IsDisposed) { continue }
    $f.Location = New-Object System.Drawing.Point(($wa.Right - $script:W - 16), ($wa.Bottom - 16 - ($script:H + $script:GAP) * ($i + 1) + $script:GAP))
    $i++
  }
}

function Open-DrbDooray {
  $p = Get-Process -Name DoorayMessenger -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
  if ($p) {
    if ([DRB.ToastApi]::IsIconic($p.MainWindowHandle)) { [void][DRB.ToastApi]::ShowWindow($p.MainWindowHandle, 9) }
    [void][DRB.ToastApi]::SetForegroundWindow($p.MainWindowHandle)
  }
}

# 이벤트 핸들러는 스크립트 범위에서 실행되므로 지역 변수 대신 $this 와 컨트롤 Tag 를 쓴다
$script:onClick = {
  $f = if ($this -is [System.Windows.Forms.Form]) { $this } else { $this.FindForm() }
  if (-not $f -or $f.IsDisposed) { return }
  $info = $f.Tag
  if ($info.channelId) {
    $name = '{0:D19}' -f [DateTime]::UtcNow.Ticks
    $tmp = Join-Path $script:clickDir ($name + '.tmp')
    [IO.File]::WriteAllText($tmp, (@{ channelId = $info.channelId } | ConvertTo-Json -Compress))
    Move-Item $tmp (Join-Path $script:clickDir ($name + '.json')) -Force
  }
  Open-DrbDooray
  $f.Close()
}
$script:onClose = {
  $f = $this.FindForm()
  if ($f -and -not $f.IsDisposed) { $f.Close() }
}
$script:onEnter = { $f = if ($this -is [System.Windows.Forms.Form]) { $this } else { $this.FindForm() }; if ($f) { $f.Tag.hover = $true } }
$script:onLeave = { $f = if ($this -is [System.Windows.Forms.Form]) { $this } else { $this.FindForm() }; if ($f) { $f.Tag.hover = $false } }
$script:onLife = {
  $f = $this.Tag
  if ($f.IsDisposed) { $this.Stop(); $this.Dispose(); return }
  if ($f.Tag.hover) { return }
  $f.Tag.left -= 1
  if ($f.Tag.left -le 0) { $this.Stop(); $this.Dispose(); $f.Close() }
}

function Show-DrbToast($t) {
  $bg = Get-DrbColor $t.bg ([System.Drawing.Color]::FromArgb(40, 40, 40))
  $fg = Get-DrbColor $t.fg ([System.Drawing.Color]::FromArgb(240, 240, 240))
  $sub = Get-DrbColor $t.sub ([System.Drawing.Color]::FromArgb(169, 169, 169))
  $accent = Get-DrbColor $t.accent ([System.Drawing.Color]::FromArgb(47, 140, 255))

  $f = New-Object System.Windows.Forms.Form
  $f.FormBorderStyle = 'None'
  $f.ShowInTaskbar = $false
  $f.StartPosition = 'Manual'
  $f.Size = New-Object System.Drawing.Size($script:W, $script:H)
  $f.BackColor = $bg
  $f.Cursor = [System.Windows.Forms.Cursors]::Hand
  $f.Tag = @{ channelId = [string]$t.channelId; hover = $false; left = 6 }
  try { $f.Region = [System.Drawing.Region]::FromHrgn([DRB.ToastApi]::CreateRoundRectRgn(0, 0, $script:W + 1, $script:H + 1, 16, 16)) } catch {}

  $bar = New-Object System.Windows.Forms.Panel
  $bar.BackColor = $accent
  $bar.Location = New-Object System.Drawing.Point(0, 0)
  $bar.Size = New-Object System.Drawing.Size(5, $script:H)

  $title = New-Object System.Windows.Forms.Label
  $title.Text = [string]$t.title
  $title.ForeColor = $fg
  $title.Font = New-Object System.Drawing.Font('Malgun Gothic', 10, [System.Drawing.FontStyle]::Bold)
  $title.Location = New-Object System.Drawing.Point(18, 12)
  $title.Size = New-Object System.Drawing.Size(($script:W - 52), 22)
  $title.AutoEllipsis = $true

  $body = New-Object System.Windows.Forms.Label
  $body.Text = [string]$t.body
  $body.ForeColor = $sub
  $body.Font = New-Object System.Drawing.Font('Malgun Gothic', 9)
  $body.Location = New-Object System.Drawing.Point(18, 38)
  $body.Size = New-Object System.Drawing.Size(($script:W - 30), 40)
  $body.AutoEllipsis = $true

  $x = New-Object System.Windows.Forms.Label
  $x.Text = [char]0x00D7
  $x.ForeColor = $sub
  $x.Font = New-Object System.Drawing.Font('Segoe UI', 11)
  $x.Location = New-Object System.Drawing.Point(($script:W - 30), 6)
  $x.Size = New-Object System.Drawing.Size(22, 22)
  $x.TextAlign = 'MiddleCenter'

  foreach ($c in @($bar, $title, $body)) { $c.Add_Click($script:onClick); $c.Add_MouseEnter($script:onEnter); $c.Add_MouseLeave($script:onLeave) }
  $x.Add_Click($script:onClose)
  $f.Add_Click($script:onClick); $f.Add_MouseEnter($script:onEnter); $f.Add_MouseLeave($script:onLeave)
  $f.Controls.AddRange(@($x, $bar, $title, $body))
  $f.Add_FormClosed({ [void]$script:toasts.Remove($this); Update-DrbToastLayout })

  [void]$script:toasts.Insert(0, $f)
  while ($script:toasts.Count -gt 4) { $old = $script:toasts[$script:toasts.Count - 1]; $old.Close() }
  Update-DrbToastLayout

  $life = New-Object System.Windows.Forms.Timer
  $life.Interval = 1000
  $life.Tag = $f
  $life.Add_Tick($script:onLife)
  $life.Start()
  # 입력 중인 창의 포커스를 빼앗지 않도록: 활성화 없이 표시(SW_SHOWNOACTIVATE) + 맨 위 고정(HWND_TOPMOST, SWP_NOACTIVATE)
  $h = $f.Handle
  [void][DRB.ToastApi]::ShowWindow($h, 4)
  [void][DRB.ToastApi]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x0013)
}

# 새 알림 파일 확인 (0.3초) + Dooray 가 꺼지면 종료
$script:noDooray = 0
$poll = New-Object System.Windows.Forms.Timer
$poll.Interval = 300
$poll.Add_Tick({
  foreach ($file in (Get-ChildItem $script:inDir -Filter *.json -ErrorAction SilentlyContinue | Sort-Object Name)) {
    try {
      $t = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
      Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
      if ($t.at -and ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [long]$t.at) -gt 60000) { continue }  # 1분 넘은 알림은 버림
      Show-DrbToast $t
    } catch { Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue }
  }
})
$alive = New-Object System.Windows.Forms.Timer
$alive.Interval = 5000
$alive.Add_Tick({
  if (Get-Process -Name DoorayMessenger -ErrorAction SilentlyContinue) { $script:noDooray = 0 } else { $script:noDooray++ }
  if ($script:noDooray -ge 3) { [System.Windows.Forms.Application]::Exit() }
})
$poll.Start()
$alive.Start()
[System.Windows.Forms.Application]::Run()
$mutex.ReleaseMutex()
