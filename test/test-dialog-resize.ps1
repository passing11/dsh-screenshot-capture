<#
  dsh-screenshot-capture · 悬浮窗「可拖动改大小」的回归测试

  验什么:
    1. 窗体边框是 SizableToolWindow —— 保留工具窗外观(无任务栏图标、窄标题栏),
       但四边可拖。早先是 FixedToolWindow,尺寸只能去设置页填数字。
    2. 有最小尺寸限制 —— 拖不成一条缝,否则按钮再也点不到。
    3. **拖动之后重新布局是对的**:拉大窗口时只有预览图跟着伸缩,
       注释框 / 勾选框 / 按钮行保持原尺寸且不越界、不重叠。

  做法:抠出 Show-CaptureDialog 在进程内跑(不截图,避免和绘制时机抢跑),
  抓到窗体后先读一次快照,再**主动把 Size 改大**、读第二次快照,
  对两次布局分别断言。

  额外验 Win32 样式位:FormBorderStyle 只是个托管属性,只有它落到窗口句柄上
  变成 WS_THICKFRAME(0x00040000),用户才真能拖边框。属性对了而样式位没对,
  界面上就是"看着像能拖,一拖纹丝不动"。这里用 .NET 的 Handle 属性拿句柄,
  **不走剪贴板** —— 剪贴板是全局独占资源,Chrome 之类的程序常年占着,
  靠它弹窗的测试(如 test-live-resize.ps1)在本机经常只能 SKIP。

  用法: powershell -NoProfile -ExecutionPolicy Bypass -File test\test-dialog-resize.ps1
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Win32 样式位读取(进程内拿句柄,不依赖剪贴板)
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class StyleProbe {
  [DllImport("user32.dll", EntryPoint="GetWindowLongW")] public static extern int GetWindowLong(IntPtr hWnd, int index);
}
"@
$GWL_STYLE = -16
$WS_THICKFRAME = 0x00040000
$WS_MAXIMIZEBOX = 0x00010000

$script = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\clip-dialog.ps1'
if (-not (Test-Path $script)) { throw "找不到 $script" }

$src = Get-Content -Raw -Encoding UTF8 $script
# 注意不能找 "function $name {" —— 带参数的函数声明是
# "function Save-RememberedGeometry([int]$x, ...)",名字后面紧跟括号而不是空格。
# 所以只匹配前缀,再从那里往后找第一个 '{'。
function Get-FnSource([string]$text, [string]$name) {
  $head = "function $name"
  $start = $text.IndexOf($head)
  if ($start -lt 0) { throw "脚本里没有 $name" }
  # 防止前缀误命中(比如找 Get-Pointer 却匹配到 Get-PointerPosition):
  # 名字后面必须是 ( 、空白 或 { 之一。
  $after = $text[$start + $head.Length]
  if ($after -ne '(' -and -not [char]::IsWhiteSpace($after) -and $after -ne '{') {
    throw "脚本里没有 $name(只匹配到前缀)"
  }
  $depth = 0
  $i = $text.IndexOf('{', $start)
  for (; $i -lt $text.Length; $i++) {
    if ($text[$i] -eq '{') { $depth++ }
    elseif ($text[$i] -eq '}') { $depth--; if ($depth -eq 0) { break } }
  }
  return $text.Substring($start, $i - $start + 1)
}
$body = Get-FnSource $src 'Show-CaptureDialog'
$ptrFn = Get-FnSource $src 'Get-PointerPosition'
Invoke-Expression $ptrFn
# Show-CaptureDialog 现在还会调这两个几何函数(记住上次位置)。抠函数跑测试
# 时得把它们一起加载进来,否则一弹窗就是 CommandNotFoundException。
# $tempDir 也要建好:默认 statePath 是从它拼出来的。
$script:tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('dsc-t-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:tempDir -Force | Out-Null
Invoke-Expression (Get-FnSource $src 'Get-StatePath')
Invoke-Expression (Get-FnSource $src 'Get-RememberedGeometry')
Invoke-Expression (Get-FnSource $src 'Save-RememberedGeometry')
Invoke-Expression $body

$script:PointerOverride = {
  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  return (New-Object System.Drawing.Point(($wa.Left + 4), ($wa.Top + 4)))
}.GetNewClosure()

$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail) {
  if ($ok) { "PASS $name" } else { "FAIL $name - $detail"; $script:fail++ }
}

function Snap($f) {
  $controls = @($f.Controls | ForEach-Object {
    @{ type = $_.GetType().Name; x = $_.Location.X; y = $_.Location.Y; w = $_.Width; h = $_.Height; text = $_.Text }
  })
  return @{ client = $f.ClientSize; controls = $controls; form = $f }
}

# 造一张宽图,保证初始布局里预览图是"被 previewMaxWidth 限制"的那一档
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('dsc-resize-' + [guid]::NewGuid().ToString('N') + '.png')
$bmp = New-Object System.Drawing.Bitmap 500, 220
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::FromArgb(238, 242, 250))
$g.Dispose()
$bmp.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

$config = @{ offsetX = 60; offsetY = 60; previewMaxWidth = 320 }
$dlgTitle = [string]([char]0x622A + [char]0x56FE + [char]0x5165 + [char]0x5E93)  # 截图入库

$clock = @{ done = $false; before = $null; after = $null; shrunk = $null; style = $null; minSize = $null; winStyle = 0; closed = $false }

$t = New-Object System.Windows.Forms.Timer
$t.Interval = 900
$t.Add_Tick({
  if ($clock.done) { return }
  $clock.done = $true
  $t.Stop()
  $f = @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -eq $dlgTitle }) | Select-Object -First 1
  if ($f) {
    $clock.style = $f.FormBorderStyle
    $clock.minSize = $f.MinimumSize
    # 句柄上的真实样式位(这才是用户拖得动拖不动的判据)
    $clock.winStyle = [StyleProbe]::GetWindowLong($f.Handle, $GWL_STYLE)
    $clock.before = Snap $f
    # 模拟用户把窗口拖大:宽 +260、高 +180
    $f.ClientSize = New-Object System.Drawing.Size(($f.ClientSize.Width + 260), ($f.ClientSize.Height + 180))
    [System.Windows.Forms.Application]::DoEvents()
    $clock.after = Snap $f
    # 再模拟拖到最小:设 Size 而不是 ClientSize —— MinimumSize 约束的是 Size
    # (真实拖动时系统按它挡住边框),而 ClientSize 的 setter 不受它限制。
    $f.Size = New-Object System.Drawing.Size(80, 80)
    [System.Windows.Forms.Application]::DoEvents()
    $clock.shrunk = Snap $f
    $clock.closed = $true
    $f.Close()
  }
})

$watchdog = New-Object System.Windows.Forms.Timer
$watchdog.Interval = 15000
$watchdog.Add_Tick({
  $watchdog.Stop()
  foreach ($w in @([System.Windows.Forms.Application]::OpenForms)) { try { $w.Close() } catch { } }
})

try {
  $t.Start()
  $watchdog.Start()
  $null = Show-CaptureDialog -ImagePath $tmp -AutoCloseMs 0
} finally {
  $t.Dispose()
  $watchdog.Dispose()
  $script:PointerOverride = $null
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

if ($null -eq $clock.before) { 'FAIL 没抓到窗体(OpenForms 里没有「截图入库」)'; exit 1 }

# ---- 1. 边框样式:可拖 + 工具窗外观 ----
Check '边框是 SizableToolWindow' ($clock.style -eq [System.Windows.Forms.FormBorderStyle]::SizableToolWindow) "实际 $($clock.style)"
Check '最小宽度有下限' ($clock.minSize.Width -ge 200) "实际 $($clock.minSize.Width)"
Check '最小高度有下限' ($clock.minSize.Height -ge 200) "实际 $($clock.minSize.Height)"
# 托管属性只是"想让它可拖";WS_THICKFRAME 才是句柄上真的可拖。
Check '句柄有 WS_THICKFRAME(真能拖边框)' (($clock.winStyle -band $WS_THICKFRAME) -ne 0) ("style=0x{0:X8}" -f $clock.winStyle)
Check '句柄没有 WS_MAXIMIZEBOX(不给最大化)' (($clock.winStyle -band $WS_MAXIMIZEBOX) -eq 0) ("style=0x{0:X8}" -f $clock.winStyle)

$before = $clock.before
$after = $clock.after

function Pick($snap, [string]$type, [int]$idx = 0) {
  return @($snap.controls | Where-Object { $_.type -eq $type })[$idx]
}

$bPic0 = Pick $before 'PictureBox'
$bNote0 = Pick $before 'TextBox'
$bChk0 = Pick $before 'CheckBox'
$aPic = Pick $after 'PictureBox'
$aNote = Pick $after 'TextBox'
$aChk = Pick $after 'CheckBox'
$aButtons = @($after.controls | Where-Object { $_.type -eq 'Button' })

# ---- 2. 拖大之后:预览图跟着变大(这才是拖动的主要用途 —— 看清细节)----
Check '拖大后预览图变宽' ($aPic.w -gt $bPic0.w) "拖前 $($bPic0.w) → 拖后 $($aPic.w)"
Check '拖大后预览图变高' ($aPic.h -gt $bPic0.h) "拖前 $($bPic0.h) → 拖后 $($aPic.h)"

# ---- 3. 注释框 / 勾选框 / 按钮行保持原尺寸(不被拉伸糊掉,也不越界)----
Check '拖大后注释框宽度跟随(与预览对齐)' ($aNote.w -eq $aPic.w) "注释 $($aNote.w) vs 预览 $($aPic.w)"
Check '拖大后注释框高度不变' ($aNote.h -eq $bNote0.h) "拖前 $($bNote0.h) → 拖后 $($aNote.h)"
Check '拖大后勾选框尺寸不变' (($aChk.w -eq $bChk0.w) -and ($aChk.h -eq $bChk0.h)) "拖前 $($bChk0.w)x$($bChk0.h) → 拖后 $($aChk.w)x$($aChk.h)"
Check '拖大后按钮还是两个' ($aButtons.Count -eq 2) "实际 $($aButtons.Count)"

# ---- 4. 拖大之后所有控件仍在窗内,且不互相重叠 ----
Check '拖大后预览图在窗内' (($aPic.x + $aPic.w) -le $after.client.Width) "右边界 $($aPic.x + $aPic.w) > 窗宽 $($after.client.Width)"
Check '拖大后注释框在窗内' (($aNote.x + $aNote.w) -le $after.client.Width) "右边界 $($aNote.x + $aNote.w) > 窗宽 $($after.client.Width)"
Check '拖大后勾选框在窗内' (($aChk.x + $aChk.w) -le $after.client.Width) "右边界 $($aChk.x + $aChk.w) > 窗宽 $($after.client.Width)"
foreach ($b in $aButtons) {
  Check "拖大后按钮「$($b.text)」在窗内" (($b.x + $b.w) -le $after.client.Width) "右边界 $($b.x + $b.w) > 窗宽 $($after.client.Width)"
}

# 纵向堆叠顺序:预览 → 注释 → 勾选 → 按钮,且相邻两者不重叠
Check '拖大后 预览在注释之上' (($aPic.y + $aPic.h) -le $aNote.y) "预览底 $($aPic.y + $aPic.h) vs 注释顶 $($aNote.y)"
Check '拖大后 注释在勾选之上' (($aNote.y + $aNote.h) -le $aChk.y) "注释底 $($aNote.y + $aNote.h) vs 勾选顶 $($aChk.y)"
$rowTop = ($aButtons | ForEach-Object { $_.y } | Measure-Object -Minimum).Minimum
Check '拖大后 勾选在按钮之上' (($aChk.y + $aChk.h) -le $rowTop) "勾选底 $($aChk.y + $aChk.h) vs 按钮顶 $rowTop"

# 所有内容都必须落在窗内(最后一行按钮的底边 + 内边距 <= 窗高)
$rowBottom = ($aButtons | ForEach-Object { $_.y + $_.h } | Measure-Object -Maximum).Maximum
Check '拖大后按钮行完整落在窗内' ($rowBottom -le $after.client.Height) "按钮底 $rowBottom > 窗高 $($after.client.Height)"

# ---- 5. 源码层:Resize 处理器必须挂上,否则上面全不成立 ----
Check '源码里有 Add_Resize 重新布局' ($body.Contains('$form.Add_Resize($relayout)')) '缺 Add_Resize 挂载'

# ---- 6. 拖到最小尺寸时,控件也不能溢出窗外 ----
$shrunk = $clock.shrunk
if ($null -eq $shrunk) {
  'FAIL 没拿到缩到最小的快照'
  $script:fail++
} else {
  $sPic = Pick $shrunk 'PictureBox'
  $sNote = Pick $shrunk 'TextBox'
  $sChk = Pick $shrunk 'CheckBox'
  $sButtons = @($shrunk.controls | Where-Object { $_.type -eq 'Button' })
  Check '缩到最小时窗口没小于下限' (($shrunk.client.Width -ge 200) -and ($shrunk.client.Height -ge 200)) "实际 $($shrunk.client.Width)x$($shrunk.client.Height)"
  Check '缩到最小时预览图仍在窗内' (($sPic.x + $sPic.w) -le $shrunk.client.Width) "右边界 $($sPic.x + $sPic.w) > 窗宽 $($shrunk.client.Width)"
  Check '缩到最小时预览图高度为正' ($sPic.h -ge 40) "实际 $($sPic.h)"
  Check '缩到最小时注释框仍在窗内' (($sNote.x + $sNote.w) -le $shrunk.client.Width) "右边界 $($sNote.x + $sNote.w) > 窗宽 $($shrunk.client.Width)"
  Check '缩到最小时勾选框仍在窗内' (($sChk.x + $sChk.w) -le $shrunk.client.Width) "右边界 $($sChk.x + $sChk.w) > 窗宽 $($shrunk.client.Width)"
  Check '缩到最小时按钮仍两个' ($sButtons.Count -eq 2) "实际 $($sButtons.Count)"
  $sBottom = ($sButtons | ForEach-Object { $_.y + $_.h } | Measure-Object -Maximum).Maximum
  Check '缩到最小时按钮行完整落在窗内' ($sBottom -le $shrunk.client.Height) "按钮底 $sBottom > 窗高 $($shrunk.client.Height)"
  Check '缩到最小时纵向不重叠(注释在勾选之上)' (($sNote.y + $sNote.h) -le $sChk.y) "注释底 $($sNote.y + $sNote.h) vs 勾选顶 $($sChk.y)"
}

if ($fail -eq 0) { '[dialog-resize] 全部通过' } else { "[dialog-resize] 失败 $fail 项"; exit 1 }
