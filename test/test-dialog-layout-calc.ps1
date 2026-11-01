<#
  dsh-screenshot-capture · 弹窗布局(Get-DialogLayout)的单元测试

  为什么要有这个文件:
    0.4.7 之前预览框的高度是"窗口剩余高度",和图片自己的宽高比无关。
    PictureBox 用 Zoom 模式,框比图胖或瘦都会在框里留灰边 —— 用户看到的
    就是"图片缩在一大片空白中间,没有完全展开"。布局算法抽成纯函数之后
    可以脱离真实弹窗直接断言,不用等窗口真的弹出来。

  验什么:
    1. 预览框宽高比 == 图片宽高比(±1px,整数四舍五入)
    2. 各种窗口尺寸下,控件都在窗内、互不重叠、纵向顺序正确
    3. 富余高度全部给注释框;高度不够时优先保住注释框、图按比例缩窄居中
    4. 极端比例(超宽 / 超窄)不产生负数或越界

  用法: powershell -NoProfile -ExecutionPolicy Bypass -File test\test-dialog-layout-calc.ps1
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\clip-dialog.ps1'
if (-not (Test-Path $script)) { throw "找不到 $script" }
$src = Get-Content -Raw -Encoding UTF8 $script

function Get-FnSource([string]$text, [string]$name) {
  $head = "function $name"
  $start = $text.IndexOf($head)
  if ($start -lt 0) { throw "脚本里没有 $name" }
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

Invoke-Expression (Get-FnSource $src 'Get-DialogLayout')

$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail) {
  if ($ok) { "PASS $name" } else { "FAIL $name - $detail"; $script:fail++ }
}

$Pad = 8; $Gap = 6; $BtnW = 88; $BtnH = 32; $ChkH = 24

function Layout([int]$cw, [int]$ch, [int]$iw, [int]$ih) {
  return Get-DialogLayout -ClientW $cw -ClientH $ch -ImageW $iw -ImageH $ih `
    -Pad $Pad -Gap $Gap -BtnW $BtnW -BtnH $BtnH
}

# 断言一套布局自洽:比例、越界、重叠、顺序。
# $label 只用于报错信息;返回 $true/$false 由调用方汇总。
function Test-Invariants([string]$label, $L, [int]$cw, [int]$ch, [int]$iw, [int]$ih) {
  $imgAspect = [double]$iw / [double]$ih
  $boxAspect = [double]$L.picW / [double]$L.picH
  # 比例必须一致 —— 这是"没有灰边"的充要条件。
  # 整数取整的误差会随宽高比放大:15:1 的图铺到 320 宽只有 21 高,
  # 高度差 1px 就让反算出的比例差 0.7。所以容差跟着比例走,不写死 2px。
  $tol = [Math]::Max(2.0, $imgAspect * 1.5)
  $aspectOk = ([Math]::Abs($L.picW - $L.picH * $imgAspect) -le $tol)
  Check "$label 预览框比例贴合图片" $aspectOk ("pic {0}x{1} 比例 {2:N3} vs 图 {3:N3}" -f $L.picW, $L.picH, $boxAspect, $imgAspect)

  Check "$label 预览图不越右边界" (($L.picX + $L.picW) -le $cw) "右 $($L.picX + $L.picW) > $cw"
  Check "$label 预览图不越下边界" (($L.picY + $L.picH) -le $ch) "下 $($L.picY + $L.picH) > $ch"
  Check "$label 预览图不出左/上边界" (($L.picX -ge 0) -and ($L.picY -ge 0)) "位置 $($L.picX),$($L.picY)"
  Check "$label 注释框不越界" ((($L.noteX + $L.noteW) -le $cw) -and (($L.noteY + $L.noteH) -le $ch)) "右 $($L.noteX + $L.noteW) 下 $($L.noteY + $L.noteH)"
  Check "$label 注释框宽度 = 窗宽 - 2*pad" ($L.noteW -eq ($cw - $Pad * 2)) "注释 $($L.noteW) vs 期望 $($cw - $Pad * 2)"
  Check "$label 注释框高度不低于下限" ($L.noteH -ge 60) "实际 $($L.noteH)"
  # 预览图高度**不设 40 的下限**:那个下限只用于"纵向空间被挤压"的分支。
  # 宽度受限时高度由图片比例决定 —— 15:1 的宽条铺满 320 宽就只有 21 高,
  # 这是比例正确的结果;硬抬到 40 会破坏比例、重新制造灰边。
  Check "$label 预览图高度为正" ($L.picH -ge 1) "实际 $($L.picH)"

  # 纵向顺序:预览 → 注释 → 勾选 → 按钮行,相邻不重叠
  Check "$label 预览在注释之上" (($L.picY + $L.picH) -le $L.noteY) "预览底 $($L.picY + $L.picH) vs 注释顶 $($L.noteY)"
  Check "$label 注释在勾选之上" (($L.noteY + $L.noteH) -le $L.chkY) "注释底 $($L.noteY + $L.noteH) vs 勾选顶 $($L.chkY)"
  Check "$label 勾选在按钮之上" (($L.chkY + $ChkH) -le $L.rowY) "勾选底 $($L.chkY + $ChkH) vs 按钮顶 $($L.rowY)"
  Check "$label 按钮行完整落在窗内" (($L.rowY + $BtnH) -le $ch) "按钮底 $($L.rowY + $BtnH) > 窗高 $ch"
  Check "$label 按钮行宽度够放两个按钮" (($L.rowX + $BtnW * 2 + $Gap) -le $cw) "需要 $($Pad + $BtnW * 2 + $Gap) 宽,窗只有 $cw"
}

# ---- ① 典型 16:9 截图,窗口宽度刚好 --------------------------------
$L = Layout 336 336 1920 1080
Test-Invariants '16:9/336x336' $L 336 336 1920 1080
# 宽度铺满(336 - 16 = 320),高度按比例 320/1.7778 = 180
Check '16:9 预览铺满窗宽' ($L.picW -eq 320) "实际 $($L.picW)"
Check '16:9 预览高度按比例' ($L.picH -eq 180) "实际 $($L.picH)"

# ---- ② 同样 16:9,但窗口被拉得很高 → 富余全给注释框 ----------------
$L = Layout 336 600 1920 1080
Test-Invariants '16:9 高窗' $L 336 600 1920 1080
Check '高窗时预览宽度不变(仍铺满)' ($L.picW -eq 320) "实际 $($L.picW)"
Check '高窗时预览高度不变(没有灰边)' ($L.picH -eq 180) "实际 $($L.picH)"
# chrome = 8*3 + 6 + 24 + 10 + 32 = 96; avail = 600 - 96 = 504; noteH = 504 - 180 = 324
Check '高窗时富余高度给了注释框' ($L.noteH -eq 324) "实际 $($L.noteH)"

# ---- ③ 竖长截图(400x900)在宽窗里 → 图变窄居中,两侧留白 ----------
$L = Layout 600 400 400 900
Test-Invariants '竖图/宽窗' $L 600 400 400 900
Check '竖图在宽窗里不被拉宽' ($L.picW -lt 584) "实际 $($L.picW)"
Check '竖图水平居中' ([Math]::Abs($L.picX - ($Pad + (584 - $L.picW) / 2)) -le 1) "picX $($L.picX)"

# ---- ④ 超宽图(3000x200)在窄窗里 ----------------------------------
$L = Layout 336 400 3000 200
Test-Invariants '超宽图' $L 336 400 3000 200
Check '超宽图铺满窗宽' ($L.picW -eq 320) "实际 $($L.picW)"
Check '超宽图按比例算出很扁的高度(不硬撑到 40)' (($L.picH -ge 1) -and ($L.picH -le 40)) "实际 $($L.picH)"

# ---- ⑤ 超窄图(100x2000)------------------------------------------
$L = Layout 336 400 100 2000
Test-Invariants '超窄图' $L 336 400 100 2000
Check '超窄图宽度被压窄(保注释框)' ($L.picW -lt 320) "实际 $($L.picW)"
Check '超窄图仍 >= 最小高度' ($L.picH -ge 40) "实际 $($L.picH)"

# ---- ⑥ 最小窗口(220x240)不该算出负数 -----------------------------
$L = Layout 220 240 1920 1080
Test-Invariants '最小窗口' $L 220 240 1920 1080
Check '最小窗口下预览尺寸为正' (($L.picW -gt 0) -and ($L.picH -gt 0)) "实际 $($L.picW)x$($L.picH)"

# ---- ⑦ 大窗口(1111x1111 固定尺寸)--------------------------------
$L = Layout 1111 1111 1920 1080
Test-Invariants '大窗/16:9' $L 1111 1111 1920 1080
Check '大窗下预览铺满窗宽' ($L.picW -eq (1111 - $Pad * 2)) "实际 $($L.picW)"

# ---- ⑧ 图片尺寸为 0 也不炸(防御性)--------------------------------
$L = Layout 336 336 0 0
Check '图片尺寸为 0 时布局仍可用' (($null -ne $L) -and ($L.picW -gt 0) -and ($L.picH -gt 0)) "pic $($L.picW)x$($L.picH)"

# ---- ⑨ 源码层:PictureBox 必须是 Zoom(等比缩放),不能是 StretchImage ----
$body = Get-FnSource $src 'Show-CaptureDialog'
Check '预览框用 Zoom 模式(等比缩放不糊)' ($body.Contains('[System.Windows.Forms.PictureBoxSizeMode]::Zoom')) '缺 Zoom 模式'
Check '没有用 StretchImage 拉伸变形' (-not ($body.Contains('StretchImage'))) '出现 StretchImage,图片会被拉变形'

if ($fail -eq 0) { '[dialog-layout-calc] 全部通过' } else { "[dialog-layout-calc] 失败 $fail 项"; exit 1 }
