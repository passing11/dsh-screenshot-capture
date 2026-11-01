<#
  dsh-screenshot-capture · 真实窗口「可拖动改大小」实测

  和 test-dialog-resize.ps1 的区别:那个是 Invoke-Expression 抠函数在进程内跑,
  读的是 .NET 属性;这个是**整条链路**(spawn powershell → 轮询剪贴板 → 弹窗),
  再用 GetWindowLong(GWL_STYLE) 读**真实窗口**的 Win32 样式位。

  为什么非要看样式位:FormBorderStyle 是个托管属性,只有它落到窗口句柄上、
  变成 WS_THICKFRAME,用户才能真正拖动边框。属性对了而样式位没对,
  界面上就是"看着像能拖,一拖纹丝不动"。

  WS_THICKFRAME (0x00040000) = 可调整边框 —— SizableToolWindow 有,FixedToolWindow 没有。
  WS_MAXIMIZEBOX (0x00010000) = 最大化按钮 —— 我们关掉了,不该有。

  用法: powershell -NoProfile -ExecutionPolicy Bypass -File test\test-live-resize.ps1
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class ResizeProbe {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder buf, int max);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr hWnd, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll", EntryPoint="GetWindowLongW")] public static extern int GetWindowLong(IntPtr hWnd, int index);
  [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr hWnd, uint msg, IntPtr w, IntPtr l);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail) {
  if ($ok) { "PASS $name" } else { "FAIL $name - $detail"; $script:fail++ }
}

$dlgTitle = [string]([char]0x622A + [char]0x56FE + [char]0x5165 + [char]0x5E93)  # 截图入库
$GWL_STYLE = -16
$WS_THICKFRAME = 0x00040000
$WS_MAXIMIZEBOX = 0x00010000
$WM_CLOSE = 0x0010

function Wait-DialogWindow([int]$timeoutMs = 12000) {
  $deadline = [DateTime]::Now.AddMilliseconds($timeoutMs)
  while ([DateTime]::Now -lt $deadline) {
    $script:foundWin = $null
    $cb = [ResizeProbe+EnumProc]{
      param($h, $l)
      if (-not [ResizeProbe]::IsWindowVisible($h)) { return $true }
      $sb = New-Object System.Text.StringBuilder 512
      [void][ResizeProbe]::GetWindowTextW($h, $sb, 512)
      if ($sb.ToString() -eq $dlgTitle) {
        $r = New-Object ResizeProbe+RECT
        if ([ResizeProbe]::GetWindowRect($h, [ref]$r)) {
          $script:foundWin = @{ hwnd = $h; rect = $r; style = [ResizeProbe]::GetWindowLong($h, $GWL_STYLE) }
          return $false
        }
      }
      return $true
    }
    [void][ResizeProbe]::EnumWindows($cb, [IntPtr]::Zero)
    if ($script:foundWin) { return $script:foundWin }
    Start-Sleep -Milliseconds 150
  }
  return $null
}

function Set-ClipboardImage([string]$path) {
  $img = [System.Drawing.Image]::FromFile($path)
  try {
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

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class ClipProbe2 {
  [DllImport("user32.dll", SetLastError=true)] public static extern bool OpenClipboard(IntPtr h);
  [DllImport("user32.dll")] public static extern bool CloseClipboard();
}
"@
$clipOk = $false
for ($i = 0; $i -lt 6; $i++) {
  if ([ClipProbe2]::OpenClipboard([IntPtr]::Zero)) { [void][ClipProbe2]::CloseClipboard(); $clipOk = $true; break }
  Start-Sleep -Milliseconds 300
}
if (-not $clipOk) {
  'SKIP 剪贴板被其他进程独占(OpenClipboard 失败),本测试无法进行。'
  exit 0
}

$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'scripts\clip-dialog.ps1'

$png = Join-Path $env:TEMP ('dsc-resize-live-' + [guid]::NewGuid().ToString('N') + '.png')
$bmp = New-Object System.Drawing.Bitmap 600, 300
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::FromArgb(238, 242, 250))
$g.Dispose()
$bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

$cfgFile = Join-Path $env:TEMP ('dsc-resize-cfg-' + [guid]::NewGuid().ToString('N') + '.json')
$proc = $null

try {
  # 自适应尺寸(宽高都填 0):这种配置下初始布局按内容算,最容易看出 resize 有没有接上
  $cfg = @{
    pollIntervalMs = 120; cooldownMs = 0
    positionMode = 'fixed'; fixedX = 300; fixedY = 200
    offsetX = 16; offsetY = 16; previewMaxWidth = 320
    width = 0; height = 0
    dupWindowMs = 0; autoCloseSec = 0
  }
  $cfg | ConvertTo-Json -Compress | Set-Content -Path $cfgFile -Encoding UTF8

  $proc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
    -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script,'-ConfigPath',$cfgFile)
  Start-Sleep -Milliseconds 2500

  Set-ClipboardImage $png
  $win = Wait-DialogWindow 12000
  if ($null -eq $win) { 'FAIL 没等到弹窗'; exit 1 }

  # ---- 1. Win32 样式位:真实可拖 ----
  $style = $win.style
  Check '窗口有 WS_THICKFRAME(边框可拖动)' (($style -band $WS_THICKFRAME) -ne 0) ("style=0x{0:X8}" -f $style)
  Check '窗口没有 WS_MAXIMIZEBOX(不给最大化按钮)' (($style -band $WS_MAXIMIZEBOX) -eq 0) ("style=0x{0:X8}" -f $style)

  $r = $win.rect
  $w0 = $r.Right - $r.Left
  $h0 = $r.Bottom - $r.Top
  Check '窗口初始尺寸合理(宽 200..2000)' (($w0 -ge 200) -and ($w0 -le 2000)) "实际 $w0"
  Check '窗口初始尺寸合理(高 240..2000)' (($h0 -ge 240) -and ($h0 -le 2000)) "实际 $h0"

  # ---- 2. 真的改一次大小,窗口跟着变 ----
  # SetWindowPos 走的是和用户拖边框**同一条**系统路径(SWP_FRAMECHANGED 会重算非客户区),
  # 所以它能验证 Resize 事件真的会触发、布局真的会重排。
  $SWP_NOZORDER = 0x0004
  $SWP_NOACTIVATE = 0x0010
  Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class PosProbe {
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT rect);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
  $newW = $w0 + 240
  $newH = $h0 + 160
  [void][PosProbe]::SetWindowPos($win.hwnd, [IntPtr]::Zero, $r.Left, $r.Top, $newW, $newH, ($SWP_NOZORDER -bor $SWP_NOACTIVATE))
  Start-Sleep -Milliseconds 600
  $r2 = New-Object PosProbe+RECT
  [void][PosProbe]::GetWindowRect($win.hwnd, [ref]$r2)
  $w1 = $r2.Right - $r2.Left
  $h1 = $r2.Bottom - $r2.Top
  Check '改大小后窗口真的变宽了' ([Math]::Abs($w1 - $newW) -le 8) "期望 $newW 实际 $w1"
  Check '改大小后窗口真的变高了' ([Math]::Abs($h1 - $newH) -le 8) "期望 $newH 实际 $h1"
  Check '改大小后窗口没崩(还活着且可见)' ([ResizeProbe]::IsWindowVisible($win.hwnd)) '窗口不可见了'

  # ---- 3. 往下缩到最小尺寸,应被 MinimumSize 挡住而不是变成一条缝 ----
  [void][PosProbe]::SetWindowPos($win.hwnd, [IntPtr]::Zero, $r.Left, $r.Top, 60, 60, ($SWP_NOZORDER -bor $SWP_NOACTIVATE))
  Start-Sleep -Milliseconds 600
  $r3 = New-Object PosProbe+RECT
  [void][PosProbe]::GetWindowRect($win.hwnd, [ref]$r3)
  $w2 = $r3.Right - $r3.Left
  $h2 = $r3.Bottom - $r3.Top
  Check '缩到最小被 MinimumSize 挡住(宽 >= 200)' ($w2 -ge 200) "实际 $w2"
  Check '缩到最小被 MinimumSize 挡住(高 >= 200)' ($h2 -ge 200) "实际 $h2"

  [void][ResizeProbe]::PostMessageW($win.hwnd, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
} finally {
  Start-Sleep -Milliseconds 400
  if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch {} }
  Remove-Item $png -Force -ErrorAction SilentlyContinue
  Remove-Item $cfgFile -Force -ErrorAction SilentlyContinue
}

if ($fail -eq 0) { '[live-resize] 全部通过' } else { "[live-resize] 失败 $fail 项"; exit 1 }
