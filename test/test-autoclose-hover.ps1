<#
  dsh-screenshot-capture · 悬浮窗「鼠标停在窗上就不关」的行为测试

  和 test-autoclose-dialog.ps1 一样,只测真东西:从 scripts/clip-dialog.ps1 里
  **抠出 Show-CaptureDialog 函数原文**再 Invoke-Expression,不复制实现。

  ⚠️ 这个测试**不移动真实鼠标**。
  早先的版本靠挪真光标来制造"指针在窗上",两个问题:
    1. 会打断用户正在做的事(测试跑 6 秒,期间用户没法用鼠标);
    2. 人手会跟测试抢光标 —— 实测一秒钟光标就飘出窗外,产品是对的,
       测试却报"用时不足",4 次跑 2 过 2 挂。
  现在改成用被测脚本自己提供的**模拟指针**入口 `$script:PointerOverride`
  (一个返回 System.Drawing.Point 的 scriptblock),纯逻辑驱动,不碰硬件。

  验什么:
    1. 指针压在窗上时**不关**:把模拟指针钉在窗体中心,等远超 AutoCloseMs 的时间,
       窗必须还活着。
    2. 指针离开后**重新给满一轮**:把模拟指针挪到屏幕另一角,再过 AutoCloseMs 才关;
       关闭时刻要明显晚于"从弹出算"的那个点(否则说明只是冻结、没有重置)。
    3. 悬停期间不写注释、不勾重点(到点关走忽略分支)。

  用法: powershell -NoProfile -ExecutionPolicy Bypass -File test\test-autoclose-hover.ps1
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 按标题找窗口 / 取矩形。**不用 [System.Windows.Forms.Form]::ActiveForm** ——
# 实测它时灵时不灵(同一个脚本跑 5 次有 3 次返回 null)。
# 也不用 FindWindow(by title):这台机器上它对中文标题稳定返回 0,而同一次运行里
# EnumWindows 能正常列出「截图入库」。所以用 EnumWindows 遍历可见顶层窗口。
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class WinFind {
  public delegate bool Proc(IntPtr h, IntPtr l);
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(Proc cb, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  /// 按标题精确匹配可见顶层窗口,返回其屏幕矩形;找不到返回 false。
  public static bool TryFindRect(string title, out RECT found) {
    RECT hit = new RECT();
    bool ok = false;
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h)) return true;
      var t = new StringBuilder(512);
      if (GetWindowTextW(h, t, 512) <= 0) return true;
      if (t.ToString() != title) return true;
      RECT r;
      if (!GetWindowRect(h, out r)) return true;
      hit = r; ok = true;
      return false;   // 找到了,停
    }, IntPtr.Zero);
    found = hit;
    return ok;
  }
}
"@

$script = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\clip-dialog.ps1'
if (-not (Test-Path $script)) { throw "找不到 $script" }

# 抠函数:按名字找到 'function NAME {' 再按花括号配平到结尾。
# 只抠原文不复制实现 —— 改源码这个测试就会跟着变。
$src = Get-Content -Raw -Encoding UTF8 $script
function Get-FnSource([string]$text, [string]$name) {
  $head = "function $name {"
  $start = $text.IndexOf($head)
  if ($start -lt 0) { throw "脚本里没有 $name" }
  $depth = 0
  $i = $text.IndexOf('{', $start)
  for (; $i -lt $text.Length; $i++) {
    if ($text[$i] -eq '{') { $depth++ }
    elseif ($text[$i] -eq '}') { $depth--; if ($depth -eq 0) { break } }
  }
  return $text.Substring($start, $i - $start + 1)
}

# Show-CaptureDialog 依赖 Get-PointerPosition(指针入口),两个都要抠出来
$body = Get-FnSource $src 'Show-CaptureDialog'
$ptrFn = Get-FnSource $src 'Get-PointerPosition'
$script:PointerOverride = $null
Invoke-Expression $ptrFn
Invoke-Expression $body
if (-not (Get-Command Show-CaptureDialog -ErrorAction SilentlyContinue)) { throw 'Invoke-Expression 之后没有 Show-CaptureDialog' }
if (-not (Get-Command Get-PointerPosition -ErrorAction SilentlyContinue)) { throw '脚本里缺 Get-PointerPosition(模拟指针入口)' }

$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail) {
  if ($ok) { "PASS $name" } else { "FAIL $name - $detail"; $script:fail++ }
}

$AUTO = 1500          # 窗自己的倒计时
$HOLD = 3000          # 模拟指针压在窗上多久

# previewMaxWidth 给大一点,窗够宽够高,窗心一定远离边缘
$config = @{ offsetX = 60; offsetY = 60; previewMaxWidth = 480 }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('dsc-hover-' + [guid]::NewGuid().ToString('N') + '.png')
$bmp = New-Object System.Drawing.Bitmap 480, 200
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::FromArgb(238, 242, 250))
$g.Dispose()
$bmp.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

# 窗标题是「截图入库」,用码点拼,免得脚本编码出岔子
$dlgTitle = [string]([char]0x622A + [char]0x56FE + [char]0x5165 + [char]0x5E93)

# 模拟指针:状态全在这个哈希表里,由下面两个 Timer 改
$ptr = @{ mode = 'center'; bounds = $null; inside = $false }
$script:PointerOverride = {
  if ($null -eq $ptr.bounds) {
    # 还没看到窗口:返回真实光标位置(此时窗还没定位,无所谓)
    return [System.Windows.Forms.Cursor]::Position
  }
  if ($ptr.mode -eq 'far') {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    return (New-Object System.Drawing.Point(($wa.Left + 4), ($wa.Top + 4)))
  }
  # center:钉在窗体正中间
  return (New-Object System.Drawing.Point(
    ($ptr.bounds.Left + [int]($ptr.bounds.Width / 2)),
    ($ptr.bounds.Top + [int]($ptr.bounds.Height / 2))
  ))
}.GetNewClosure()

$mover = New-Object System.Windows.Forms.Timer
$mover.Interval = 100
$clock = @{ elapsed = 0; moved = $false; sawInside = $false; bounds = $null }
$mover.Add_Tick({
  $clock.elapsed += 100
  $r = New-Object WinFind+RECT
  if ([WinFind]::TryFindRect($dlgTitle, [ref]$r)) {
    $rect = New-Object System.Drawing.Rectangle $r.Left, $r.Top, ($r.Right - $r.Left), ($r.Bottom - $r.Top)
    $ptr.bounds = $rect
    $clock.bounds = $rect
    # 用「模拟指针会返回什么」来判断,而不是去读真实光标
    $sim = if ($ptr.mode -eq 'far') {
      $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
      New-Object System.Drawing.Point(($wa.Left + 4), ($wa.Top + 4))
    } else {
      New-Object System.Drawing.Point(($rect.Left + [int]($rect.Width / 2)), ($rect.Top + [int]($rect.Height / 2)))
    }
    if ($rect.Contains($sim)) { $clock.sawInside = $true }
  }
  if (-not $clock.moved -and $clock.elapsed -ge $HOLD) {
    $ptr.mode = 'far'      # 模拟指针离开窗口
    $clock.moved = $true
  }
})

$res = $null
$ms = 0
try {
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $mover.Start()
  $res = Show-CaptureDialog -ImagePath $tmp -AutoCloseMs $AUTO
  $sw.Stop()
  $mover.Stop()
  $ms = [int]$sw.Elapsed.TotalMilliseconds

  # 前提:模拟指针确实在窗内待过(否则后面的时长断言没意义)
  Check '前提:模拟指针曾落在窗内' ($clock.sawInside) "从未进入窗体 $($clock.bounds)"

  Check '悬停期间没有被关掉(总耗时超过 HOLD)' ($ms -gt $HOLD) "实测 ${ms}ms,HOLD=${HOLD}ms"
  Check '离开后重新给满一轮(AUTO 之后才关)' ($ms -ge ($HOLD + $AUTO - 400)) "实测 ${ms}ms,期望 >= $($HOLD + $AUTO - 400)ms"
  Check '离开后不会拖太久(不超过 HOLD+AUTO+2s)' ($ms -lt ($HOLD + $AUTO + 2000)) "实测 ${ms}ms"
  Check '最终走忽略分支 action=ignore' ($res.action -eq 'ignore') "action=$($res.action)"
  Check 'autoClosed 标记为 true' ($res.autoClosed -eq $true) "autoClosed=$($res.autoClosed)"
  Check '没有顺手写注释/勾重点' (($res.note -eq '') -and (-not $res.isKey)) "note='$($res.note)' isKey=$($res.isKey)"

  # 源码层:悬停判定必须在 Timer 的 Tick 里,且走统一的指针入口(可被模拟)
  Check 'Tick 里判断指针是否在窗内' ($body.Contains('$form.Bounds.Contains((Get-PointerPosition))')) '缺 Bounds.Contains(Get-PointerPosition)'
  Check '指针走 Get-PointerPosition 入口(可模拟)' ($body.Contains('function Get-PointerPosition') -or $src.Contains('function Get-PointerPosition')) '缺 Get-PointerPosition'
  Check '在窗内时直接 return(冻结倒计时)' ($body.Contains('$state.hovering = $true')) '缺 hovering 标记'
  Check '离开后把倒计时喂满' ($body.Contains('$state.left = $AutoCloseMs')) '缺 left 重置'
} finally {
  $script:PointerOverride = $null
  $mover.Dispose()
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

if ($fail -eq 0) { '[autoclose-hover] 全部通过' } else { "[autoclose-hover] 失败 $fail 项"; exit 1 }
