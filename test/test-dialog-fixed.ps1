<#
  dsh-screenshot-capture · 悬浮窗「固定位置 + 自定义尺寸」的回归测试

  验什么:
    1. positionMode="fixed" 时,窗口**真的**出现在 fixedX/fixedY,
       而且与鼠标位置无关(把模拟指针放到屏幕另一头,窗口不动)。
    2. positionMode="cursor"(默认)行为没被改坏 —— 仍跟着指针 + offset。
    3. width/height 固定时,ClientSize 就等于设定值(且不低于可用下限)。
    4. width=0/height=0 时回到自适应,ClientSize 由内容决定。
    5. 固定尺寸下所有控件仍在窗内(不许越界),注释框吃掉多余高度。

  做法:抠出 scripts/clip-dialog.ps1 的 Show-CaptureDialog 原文直接 Invoke-Expression,
  用 OpenForms 在弹窗后读 ClientSize / Location / 控件框,然后 Close() 掉。
  指针一律用 $script:PointerOverride 模拟,**不动真实鼠标**。

  用法: powershell -NoProfile -ExecutionPolicy Bypass -File test\test-dialog-fixed.ps1
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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

$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail) {
  if ($ok) { "PASS $name" } else { "FAIL $name - $detail"; $script:fail++ }
}

# 造一张 500x220 的图(比 previewMaxWidth 大,逼出缩放路径)
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('dsc-fixed-' + [guid]::NewGuid().ToString('N') + '.png')
$bmp = New-Object System.Drawing.Bitmap 500, 220
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::FromArgb(238, 242, 250))
$g.Dispose()
$bmp.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

$dlgTitle = [string]([char]0x622A + [char]0x56FE + [char]0x5165 + [char]0x5E93)

<#
  弹一次窗并把结果读出来。

  $config 是**全局**的:$body 里所有 $config.xxx 都读它,所以每次调用前
  重置成这一轮的配置。$script:PointerOverride 同理。

  返回 @{ client = Size; location = Point; controls = @(...) },抓不到返回 $null。
#>
function Invoke-DialogProbe {
  param([hashtable]$Cfg, [System.Drawing.Point]$Pointer)

  $global:config = $Cfg
  $script:PointerOverride = [scriptblock]::Create("return (New-Object System.Drawing.Point($($Pointer.X), $($Pointer.Y)))")

  $clock = @{ done = $false; snap = $null }
  $t = New-Object System.Windows.Forms.Timer
  $t.Interval = 700
  $t.Add_Tick({
    if ($clock.done) { return }
    $clock.done = $true
    $t.Stop()
    $f = @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -eq $dlgTitle }) | Select-Object -First 1
    if ($f) {
      $clock.snap = @{
        client   = $f.ClientSize
        location = $f.Location
        controls = @($f.Controls | ForEach-Object {
          @{ type = $_.GetType().Name; x = $_.Location.X; y = $_.Location.Y; w = $_.Width; h = $_.Height; text = $_.Text }
        })
      }
      $f.Close()
    }
  }.GetNewClosure())

  # 兜底:抓不到就把所有窗体关掉,免得模态窗挂死整个测试
  $watchdog = New-Object System.Windows.Forms.Timer
  $watchdog.Interval = 12000
  $watchdog.Add_Tick({
    $watchdog.Stop()
    foreach ($w in @([System.Windows.Forms.Application]::OpenForms)) { try { $w.Close() } catch { } }
  }.GetNewClosure())

  try {
    $t.Start(); $watchdog.Start()
    $null = Show-CaptureDialog -ImagePath $tmp -AutoCloseMs 0
  } finally {
    $t.Dispose(); $watchdog.Dispose()
    $script:PointerOverride = $null
  }
  return $clock.snap
}

$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
$baseCfg = @{
  pollIntervalMs = 200; cooldownMs = 2000
  positionMode = 'cursor'; fixedX = 0; fixedY = 0
  offsetX = 16; offsetY = 16; previewMaxWidth = 320
  width = 0; height = 0; dupWindowMs = 6000; autoCloseSec = 0
}

try {
  # ---- 1. 默认(cursor)行为:跟着指针 + offset ----------------------------
  # 指针放在**主屏工作区中部** —— 那里右下方向一定有足够空间,窗口不会触发
  # 「放不下就翻到左上」的兜底分支(那个分支会让断言算不准)。
  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $ptr = New-Object System.Drawing.Point(([int]($wa.Left + $wa.Width / 2) - 400), ([int]($wa.Top + $wa.Height / 2) - 300))
  $cfg = $baseCfg.Clone(); $cfg.offsetX = 40; $cfg.offsetY = 30
  $snap = Invoke-DialogProbe -Cfg $cfg -Pointer $ptr
  if ($null -eq $snap) { 'FAIL 没抓到窗体(cursor 模式)'; exit 1 }
  Check 'cursor 模式:窗口跟着指针' `
    (($snap.location.X -eq $ptr.X + 40) -and ($snap.location.Y -eq $ptr.Y + 30)) `
    "期望 ($($ptr.X + 40),$($ptr.Y + 30)) 实际 ($($snap.location.X),$($snap.location.Y))"

  # ---- 2. fixed 模式:钉死在指定坐标,与指针无关 -------------------------
  # 指针故意挪到屏幕另一头,窗口必须纹丝不动。
  $fx = $vs.Left + 300
  $fy = $vs.Top + 200
  $cfg2 = $baseCfg.Clone(); $cfg2.positionMode = 'fixed'; $cfg2.fixedX = $fx; $cfg2.fixedY = $fy
  $far = New-Object System.Drawing.Point(($vs.Right - 30), ($vs.Bottom - 30))
  $snap2 = Invoke-DialogProbe -Cfg $cfg2 -Pointer $far
  if ($null -eq $snap2) { 'FAIL 没抓到窗体(fixed 模式)'; exit 1 }
  Check 'fixed 模式:窗口钉在 fixedX/fixedY' `
    (($snap2.location.X -eq $fx) -and ($snap2.location.Y -eq $fy)) `
    "期望 ($fx,$fy) 实际 ($($snap2.location.X),$($snap2.location.Y))"
  Check 'fixed 模式:与鼠标位置无关' `
    (($snap2.location.X -ne $far.X + $cfg2.offsetX)) `
    "窗口跟着鼠标跑了:实际 ($($snap2.location.X),$($snap2.location.Y))"

  # ---- 3. 固定尺寸 ------------------------------------------------------
  $cfg3 = $baseCfg.Clone(); $cfg3.positionMode = 'fixed'; $cfg3.fixedX = $vs.Left + 100; $cfg3.fixedY = $vs.Top + 100
  $cfg3.width = 520; $cfg3.height = 640
  $snap3 = Invoke-DialogProbe -Cfg $cfg3 -Pointer $ptr
  if ($null -eq $snap3) { 'FAIL 没抓到窗体(固定尺寸)'; exit 1 }
  Check '固定宽度生效' ($snap3.client.Width -eq 520) "期望 520 实际 $($snap3.client.Width)"
  Check '固定高度生效' ($snap3.client.Height -eq 640) "期望 640 实际 $($snap3.client.Height)"

  # 固定尺寸下控件不能越界
  $pic3 = @($snap3.controls | Where-Object { $_.type -eq 'PictureBox' })[0]
  $note3 = @($snap3.controls | Where-Object { $_.type -eq 'TextBox' })[0]
  $btns3 = @($snap3.controls | Where-Object { $_.type -eq 'Button' })
  Check '固定尺寸:预览在窗内' (($pic3.x + $pic3.w) -le $snap3.client.Width) "右边界 $($pic3.x + $pic3.w) > $($snap3.client.Width)"
  Check '固定尺寸:注释框在窗内' (($note3.x + $note3.w) -le $snap3.client.Width) "右边界 $($note3.x + $note3.w) > $($snap3.client.Width)"
  Check '固定尺寸:注释框不压按钮行' (($note3.y + $note3.h) -le ($btns3 | ForEach-Object { $_.y } | Measure-Object -Minimum).Minimum) `
    "注释底 $($note3.y + $note3.h) 越过按钮顶"
  Check '固定尺寸:按钮在窗内' `
    (@($btns3 | Where-Object { ($_.x + $_.w) -le $snap3.client.Width -and ($_.y + $_.h) -le $snap3.client.Height }).Count -eq $btns3.Count) `
    '有按钮越界'
  # 多出来的高度应该给注释框:640 高的窗里注释框要明显高于默认 60
  Check '固定高度:多余高度给了注释框' ($note3.h -gt 100) "注释框只有 $($note3.h) 高"

  # ---- 4. 自适应(0/0)仍然是内容驱动 -----------------------------------
  $cfg4 = $baseCfg.Clone(); $cfg4.positionMode = 'fixed'; $cfg4.fixedX = $vs.Left + 100; $cfg4.fixedY = $vs.Top + 100
  $snap4 = Invoke-DialogProbe -Cfg $cfg4 -Pointer $ptr
  if ($null -eq $snap4) { 'FAIL 没抓到窗体(自适应)'; exit 1 }
  Check 'width/height=0 时回到自适应' (($snap4.client.Width -ne 520) -or ($snap4.client.Height -ne 640)) `
    "自适应居然和固定尺寸一样:$($snap4.client.Width)x$($snap4.client.Height)"
  Check '自适应高度明显小于固定 640' ($snap4.client.Height -lt 640) "实际 $($snap4.client.Height)"

  # ---- 5. 固定尺寸小于内容下限时不能把控件挤爆 -------------------------
  $cfg5 = $baseCfg.Clone(); $cfg5.positionMode = 'fixed'; $cfg5.fixedX = $vs.Left + 50; $cfg5.fixedY = $vs.Top + 50
  $cfg5.width = 100; $cfg5.height = 80
  $snap5 = Invoke-DialogProbe -Cfg $cfg5 -Pointer $ptr
  if ($null -eq $snap5) { 'FAIL 没抓到窗体(过小尺寸)'; exit 1 }
  $btns5 = @($snap5.controls | Where-Object { $_.type -eq 'Button' })
  Check '尺寸过小时按钮仍排得下' ($snap5.client.Width -ge (8 * 2 + 88 * 2 + 6)) "窗宽被压到 $($snap5.client.Width)"
  Check '尺寸过小时按钮仍在窗内' `
    (@($btns5 | Where-Object { ($_.x + $_.w) -le $snap5.client.Width -and ($_.y + $_.h) -le $snap5.client.Height }).Count -eq $btns5.Count) `
    '有按钮越界'
} finally {
  $script:PointerOverride = $null
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

if ($fail -eq 0) { '[dialog-fixed] 全部通过' } else { "[dialog-fixed] 失败 $fail 项"; exit 1 }
