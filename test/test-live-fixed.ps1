<#
  真实弹窗实测:用一份指定的 watcher-config.json 直接拉起 scripts/clip-dialog.ps1,
  往剪贴板塞一张图,然后用 EnumWindows + GetWindowRect 读**真实窗口**的屏幕矩形。

  和 test-dialog-fixed.ps1 的区别:那个是 Invoke-Expression 抠函数出来在进程内跑,
  这个是**整条链路**(spawn powershell → 轮询剪贴板 → 弹窗 → 屏幕上的窗)。
  所以它能验证「配置真的从 json 一路走到了窗口位置和尺寸」。

  用法: powershell -NoProfile -ExecutionPolicy Bypass -File test\test-live-fixed.ps1
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class WinProbe {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder buf, int max);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr hWnd, uint msg, IntPtr w, IntPtr l);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail) {
  if ($ok) { "PASS $name" } else { "FAIL $name - $detail"; $script:fail++ }
}

$dlgTitle = [string]([char]0x622A + [char]0x56FE + [char]0x5165 + [char]0x5E93)  # 截图入库

<# 在 $timeoutMs 内等一个标题匹配且可见的窗口,返回 @{ hwnd; rect } 或 $null #>
function Wait-DialogWindow([int]$timeoutMs = 12000) {
  $deadline = [DateTime]::Now.AddMilliseconds($timeoutMs)
  while ([DateTime]::Now -lt $deadline) {
    $found = $null
    $cb = [WinProbe+EnumProc]{
      param($h, $l)
      if (-not [WinProbe]::IsWindowVisible($h)) { return $true }
      $sb = New-Object System.Text.StringBuilder 512
      [void][WinProbe]::GetWindowTextW($h, $sb, 512)
      if ($sb.ToString() -eq $dlgTitle) {
        $r = New-Object WinProbe+RECT
        if ([WinProbe]::GetWindowRect($h, [ref]$r)) {
          $script:foundWin = @{ hwnd = $h; rect = $r }
          return $false
        }
      }
      return $true
    }
    $script:foundWin = $null
    [void][WinProbe]::EnumWindows($cb, [IntPtr]::Zero)
    if ($script:foundWin) { return $script:foundWin }
    Start-Sleep -Milliseconds 150
  }
  return $null
}

<# 把一张带文字的图放进剪贴板(要 STA) #>
function Set-ClipboardImage([string]$path) {
  $img = [System.Drawing.Image]::FromFile($path)
  try {
    # SetImage 偶发 "Requested Clipboard operation did not succeed" —— 剪贴板是
    # 全局独占资源,插件自己的监听助手每 200ms 就 OpenClipboard 一次,别的程序也
    # 可能占着。所以带重试,而不是一次失败就判整个测试死刑。
    for ($i = 0; $i -lt 15; $i++) {
      try {
        [System.Windows.Forms.Clipboard]::SetImage($img)
        return
      } catch {
        Start-Sleep -Milliseconds 200
      }
    }
    throw "剪贴板被占用,15 次重试后仍无法写入"
  } finally { $img.Dispose() }
}

$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'scripts\clip-dialog.ps1'
$tempDir = Join-Path $env:TEMP 'dsh-capture'
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

# 造一张 600x300 的图
$png = Join-Path $env:TEMP ('dsc-live-' + [guid]::NewGuid().ToString('N') + '.png')
$bmp = New-Object System.Drawing.Bitmap 600, 300
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::FromArgb(238, 242, 250))
$g.Dispose()
$bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

$cfgFile = Join-Path $env:TEMP ('dsc-live-cfg-' + [guid]::NewGuid().ToString('N') + '.json')
$proc = $null

# 先探剪贴板能不能写。剪贴板是全局独占资源,别的程序(实测见过 Electron 的
# Chrome_MessageWindow)占着不放时,本测试的**前提**就不成立 —— 那种情况报 SKIP,
# 不报 FAIL,免得把别人的问题算到插件头上。
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class ClipProbe {
  [DllImport("user32.dll", SetLastError=true)] public static extern bool OpenClipboard(IntPtr h);
  [DllImport("user32.dll")] public static extern bool CloseClipboard();
}
"@
$clipOk = $false
for ($i = 0; $i -lt 6; $i++) {
  if ([ClipProbe]::OpenClipboard([IntPtr]::Zero)) { [void][ClipProbe]::CloseClipboard(); $clipOk = $true; break }
  Start-Sleep -Milliseconds 300
}
if (-not $clipOk) {
  Remove-Item $png -Force -ErrorAction SilentlyContinue
  'SKIP 剪贴板被其他进程独占(OpenClipboard 失败),本测试无法进行。'
  '     这不是插件的问题:关掉占用剪贴板的程序(常见是 Electron 应用)后重跑即可。'
  exit 0
}

try {
  # ---- 场景:固定坐标 300,200 + 固定尺寸 560x620 ---------------------------
  $cfg = @{
    pollIntervalMs = 120; cooldownMs = 0
    positionMode = 'fixed'; fixedX = 300; fixedY = 200
    offsetX = 16; offsetY = 16; previewMaxWidth = 320
    width = 560; height = 620
    dupWindowMs = 0; autoCloseSec = 0
  }
  $cfg | ConvertTo-Json -Compress | Set-Content -Path $cfgFile -Encoding UTF8

  $proc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
    -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script,'-ConfigPath',$cfgFile)
  Start-Sleep -Milliseconds 2500

  Set-ClipboardImage $png
  $win = Wait-DialogWindow 12000
  if ($null -eq $win) { 'FAIL 没等到弹窗(固定坐标场景)'; exit 1 }

  $r = $win.rect
  $w = $r.Right - $r.Left
  $h = $r.Bottom - $r.Top
  # GetWindowRect 是**含边框**的屏幕矩形;FixedToolWindow 的边框很窄,
  # 位置断言的容差给 12px(不同 DPI/主题下边框宽度不一样)。
  Check '固定坐标:窗口左边 ≈ fixedX' ([Math]::Abs($r.Left - 300) -le 12) "期望 ≈300 实际 $($r.Left)"
  Check '固定坐标:窗口上边 ≈ fixedY' ([Math]::Abs($r.Top - 200) -le 12) "期望 ≈200 实际 $($r.Top)"
  # 尺寸:ClientSize 560x620 + 边框 → 外框略大
  Check '固定尺寸:窗口宽 ≈ 560' ([Math]::Abs($w - 560) -le 40) "期望 ≈560 实际 $w"
  Check '固定尺寸:窗口高 ≈ 620' ([Math]::Abs($h - 620) -le 60) "期望 ≈620 实际 $h"

  [void][WinProbe]::PostMessageW($win.hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)  # WM_CLOSE
  Start-Sleep -Milliseconds 800

  # ---- 场景:跟随鼠标(cursor)不能也钉在 300,200 --------------------------
  $cfg2 = $cfg.Clone()
  $cfg2.positionMode = 'cursor'
  $cfg2.fixedX = 0; $cfg2.fixedY = 0
  $cfg2 | ConvertTo-Json -Compress | Set-Content -Path $cfgFile -Encoding UTF8

  if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch {} }
  Start-Sleep -Milliseconds 400
  $proc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
    -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script,'-ConfigPath',$cfgFile)
  Start-Sleep -Milliseconds 2500
  Set-ClipboardImage $png
  $win2 = Wait-DialogWindow 12000
  if ($null -eq $win2) { 'FAIL 没等到弹窗(cursor 场景)'; exit 1 }
  $r2 = $win2.rect
  $cursor = [System.Windows.Forms.Cursor]::Position
  Check 'cursor 模式:窗口不在固定坐标上' `
    (([Math]::Abs($r2.Left - 300) -gt 12) -or ([Math]::Abs($r2.Top - 200) -gt 12)) `
    "窗口仍在 (300,200):实际 ($($r2.Left),$($r2.Top))"
  Check 'cursor 模式:窗口在光标附近' `
    (([Math]::Abs($r2.Left - $cursor.X) -le 700) -and ([Math]::Abs($r2.Top - $cursor.Y) -le 700)) `
    "光标 ($($cursor.X),$($cursor.Y)) 窗口 ($($r2.Left),$($r2.Top))"
  [void][WinProbe]::PostMessageW($win2.hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
} finally {
  Start-Sleep -Milliseconds 300
  if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch {} }
  Remove-Item $png -Force -ErrorAction SilentlyContinue
  Remove-Item $cfgFile -Force -ErrorAction SilentlyContinue
}

if ($fail -eq 0) { '[live-fixed] 全部通过' } else { "[live-fixed] 失败 $fail 项"; exit 1 }
