<#
  dsh-screenshot-capture · 悬浮窗布局的回归测试

  验什么:
    1. 按钮只有「存文档」「存图片」两个 —— 「复制截图」在 v0.3.0 去掉了。
    2. **预览图不被裁**:窗宽必须 >= 预览图宽 + 两侧内边距。
       这条是补 2026-10-29 的漏:窗宽原来只按按钮行算(三键时代 292),
       预览图按 previewMaxWidth 独立算,两者谁也不管谁 —— 去掉一个按钮后
       窗宽掉到 198,320 宽的预览直接横向缺了一半。
    3. 注释框、重点勾选框、按钮都在窗体内(不越界)。

  做法:抠出 scripts/clip-dialog.ps1 里的 Show-CaptureDialog 原文,
  用 DrawToBitmap 之外的纯属性读数做断言(不截图,避免和绘制时机抢跑)。

  用法: powershell -NoProfile -ExecutionPolicy Bypass -File test\test-dialog-layout.ps1
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\clip-dialog.ps1'
if (-not (Test-Path $script)) { throw "找不到 $script" }

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
$body = Get-FnSource $src 'Show-CaptureDialog'
$ptrFn = Get-FnSource $src 'Get-PointerPosition'
Invoke-Expression $ptrFn
Invoke-Expression $body

# 指针用模拟的,不动真实鼠标:钉在屏幕左上角,窗口摆在它右下,不会反过来盖住它。
$script:PointerOverride = {
  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  return (New-Object System.Drawing.Point(($wa.Left + 4), ($wa.Top + 4)))
}.GetNewClosure()

$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail) {
  if ($ok) { "PASS $name" } else { "FAIL $name - $detail"; $script:fail++ }
}

# 造一张比 previewMaxWidth 宽的图,逼出"预览要不要裁"这个问题
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('dsc-layout-' + [guid]::NewGuid().ToString('N') + '.png')
$bmp = New-Object System.Drawing.Bitmap 500, 220
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::FromArgb(238, 242, 250))
$g.Dispose()
$bmp.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

$config = @{ offsetX = 60; offsetY = 60; previewMaxWidth = 320 }

# 窗标题「截图入库」用码点拼,避免脚本编码问题
$dlgTitle = [string]([char]0x622A + [char]0x56FE + [char]0x5165 + [char]0x5E93)

# 在弹窗后的一瞬间把控件树读出来,然后直接关掉那个窗体。
#
# 不用 [System.Windows.Forms.Form]::ActiveForm —— 实测时灵时不灵,拿到 null 时
# 下面 SendKeys 的 ESC 也就发不出去,模态窗永远不返回,测试直接挂死(踩过)。
# 改用 Application.OpenForms:同一进程内所有已打开的 Form 都在里面,模态对话框
# 也在,不依赖焦点。关闭用 $f.Close() —— WinForms Timer 跑在 UI 线程的消息泵上,
# 可以直接关;Close() 让 ShowDialog 返回 Cancel,正好走 ignore 分支。
$clock = @{ done = $false; snap = $null; closed = $false }
$t = New-Object System.Windows.Forms.Timer
$t.Interval = 900
$t.Add_Tick({
  if ($clock.done) { return }
  $clock.done = $true
  $t.Stop()
  $f = @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -eq $dlgTitle }) | Select-Object -First 1
  if ($f) {
    $clock.snap = @{
      client = $f.ClientSize
      controls = @($f.Controls | ForEach-Object {
        @{ type = $_.GetType().Name; x = $_.Location.X; y = $_.Location.Y; w = $_.Width; h = $_.Height; text = $_.Text }
      })
    }
    $clock.closed = $true
    $f.Close()
  }
})

# 兜底:万一上面没找到窗(标题不符等),15 秒后强行关掉所有窗体,免得挂死。
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

$snap = $clock.snap
if ($null -eq $snap) { 'FAIL 没抓到窗体(OpenForms 里没有「截图入库」)'; exit 1 }

$buttons = @($snap.controls | Where-Object { $_.type -eq 'Button' })
$pic = @($snap.controls | Where-Object { $_.type -eq 'PictureBox' })[0]
$note = @($snap.controls | Where-Object { $_.type -eq 'TextBox' })[0]
$chk = @($snap.controls | Where-Object { $_.type -eq 'CheckBox' })[0]

Check '只有两个按钮' ($buttons.Count -eq 2) "实际 $($buttons.Count) 个"
Check '按钮是 存文档 / 存图片' ((($buttons | ForEach-Object { $_.text }) -join '/') -eq '存文档/存图片') (($buttons | ForEach-Object { $_.text }) -join '/')
Check '没有「复制截图」' (-not ($buttons | Where-Object { $_.text -eq '复制截图' })) '还留着复制截图'

# 预览图必须完整落在窗内(左右各留 8px 内边距)
Check '预览图没被横向裁掉' (($pic.w + 16) -le $snap.client.Width) "图宽 $($pic.w) + 16 > 窗宽 $($snap.client.Width)"
Check '预览图在窗内(右边界不越界)' (($pic.x + $pic.w) -le $snap.client.Width) "右边界 $($pic.x + $pic.w) > 窗宽 $($snap.client.Width)"
Check '注释框在窗内' (($note.x + $note.w) -le $snap.client.Width) "右边界 $($note.x + $note.w) > 窗宽 $($snap.client.Width)"
Check '注释框宽度与预览对齐' ($note.w -eq $pic.w) "注释 $($note.w) vs 预览 $($pic.w)"
Check '重点勾选框在窗内' (($chk.x + $chk.w) -le $snap.client.Width) "右边界 $($chk.x + $chk.w) > 窗宽 $($snap.client.Width)"
foreach ($b in $buttons) {
  Check "按钮「$($b.text)」在窗内" (($b.x + $b.w) -le $snap.client.Width) "右边界 $($b.x + $b.w) > 窗宽 $($snap.client.Width)"
}

# 源码层:窗宽必须是「按钮行」与「预览图」两者取大
Check '窗宽取按钮行与预览图较宽者' ($body.Contains('$totalW = [Math]::Max($rowW, $pw + $pad * 2)')) '缺 totalW 取大的写法'

if ($fail -eq 0) { '[dialog-layout] 全部通过' } else { "[dialog-layout] 失败 $fail 项"; exit 1 }
