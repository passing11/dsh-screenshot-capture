<#
  dsh-screenshot-capture · 剪贴板监听 + 系统级悬浮窗 (PowerShell 5.1, 零依赖)

  职责:
    1. 轮询剪贴板序列号(GetClipboardSequenceNumber),检测新图片(截图/Ctrl+C 图片)
    2. 检测到后:原图存到 $env:TEMP\dsh-capture\clip_<ts>.png
    3. 在鼠标当前位置弹出置顶小窗:图片预览 + 注释输入框 + 「重点」复选框
       + 【存文档】【存图片】
    4. 结果写入事件日志文件(每行一个 JSON),也尝试写 stdout

  协议(每行一个 JSON,写日志 + stdout):
    {"t":"ready"}
    {"t":"img","path":"...","seq":123}
    {"t":"choice","action":"doc|img|ignore","path":"...","note":"用户注释","isKey":true,"autoClosed":false}
    {"t":"err","msg":"..."}

  参数:
    -ConfigPath  JSON 配置文件(可选): pollIntervalMs / cooldownMs / offsetX / offsetY / previewMaxWidth
                 / dupWindowMs / autoCloseSec(悬浮窗自动关闭秒数,0 = 不自动关)
    -AutoAction  doc|img|ignore|none  自动选择,不弹窗(自动化测试用);none=只检测不处理
    -Once        只处理一次后退出
#>
param(
  [string]$ConfigPath = "",
  [string]$AutoAction = "",
  [switch]$Once
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class WinClip {
  [DllImport("user32.dll")]
  public static extern uint GetClipboardSequenceNumber();
}
"@

$tempDir = Join-Path $env:TEMP "dsh-capture"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
$logPath = Join-Path $tempDir "events.log"

function Write-Event([hashtable]$obj) {
  $line = $obj | ConvertTo-Json -Compress
  try { [System.IO.File]::AppendAllText($logPath, $line + [Environment]::NewLine, [System.Text.Encoding]::UTF8) } catch {}
  try { [Console]::Out.WriteLine($line); [Console]::Out.Flush() } catch {}
}

$config = @{ pollIntervalMs = 200; cooldownMs = 2000; positionMode = "cursor"; fixedX = 0; fixedY = 0; offsetX = 16; offsetY = 16; previewMaxWidth = 320; width = 0; height = 0; dupWindowMs = 6000; autoCloseSec = 0; statePath = "" }
if ($ConfigPath -and (Test-Path $ConfigPath)) {
  try {
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    foreach ($k in @('pollIntervalMs','cooldownMs','positionMode','fixedX','fixedY','offsetX','offsetY','previewMaxWidth','width','height','dupWindowMs','autoCloseSec','statePath')) {
      if ($null -ne $cfg.$k) { $config[$k] = $cfg.$k }
    }
  } catch { Write-Event @{ t = "err"; msg = "config parse: $($_.Exception.Message)" } }
}

# --- duplicate-screen guard -------------------------------------------------
# Windows' snipping tool can push the SAME screen to the clipboard twice within a
# few seconds (measured 2026-09-29: two images 1 px apart, 3 s apart). Without a
# guard that is two dialogs and two archived copies for one screenshot. Compare a
# coarse 32x32 grey fingerprint against the recent captures and skip near-identical
# ones inside dupWindowMs.
$dupPixelsAllowed = 64   # of 1024 cells (6%); same screen stays well under it
$recentSignatures = @()

function Get-ImageSignature([System.Drawing.Image]$image) {
  $bmp = New-Object System.Drawing.Bitmap 32, 32
  try {
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try { $g.DrawImage($image, 0, 0, 32, 32) } finally { $g.Dispose() }
    $sig = New-Object 'int[]' 1024
    for ($y = 0; $y -lt 32; $y++) {
      for ($x = 0; $x -lt 32; $x++) {
        $c = $bmp.GetPixel($x, $y)
        $lum = ($c.R * 0.299) + ($c.G * 0.587) + ($c.B * 0.114)
        $sig[($y * 32) + $x] = [int][Math]::Floor($lum / 16)
      }
    }
    return , $sig
  } finally {
    $bmp.Dispose()
  }
}

function Test-SimilarSignature($a, $b, [int]$allowed) {
  $diff = 0
  for ($i = 0; $i -lt $a.Length; $i++) {
    if ($a[$i] -ne $b[$i]) {
      $diff++
      if ($diff -gt $allowed) { return $false }
    }
  }
  return $true
}

function Test-DuplicateCapture($sig, $now) {
  foreach ($entry in $recentSignatures) {
    if (($now - $entry.at).TotalMilliseconds -le [int]$config.dupWindowMs) {
      if (Test-SimilarSignature $sig $entry.sig $dupPixelsAllowed) { return $true }
    }
  }
  return $false
}

function Remember-Signature($sig, $now) {
  $script:recentSignatures = @(@{ sig = $sig; at = $now }) + @($recentSignatures | Select-Object -First 4)
}

# 指针位置的唯一入口。
#
# 默认读真实光标。自动化测试可以临时把 $script:PointerOverride 设成一个返回
# Point 的 scriptblock,**模拟**指针位置 —— 这样跑测试不会去动用户真正的鼠标。
# (之前的测试直接挪真鼠标:既打断用户操作,又因为人手会跟它抢而时过时不过。)
$script:PointerOverride = $null
function Get-PointerPosition {
  if ($null -ne $script:PointerOverride) { return (& $script:PointerOverride) }
  return [System.Windows.Forms.Cursor]::Position
}

# --- 记住上次关闭时的位置和大小 --------------------------------------------
#
# 存在一个独立的小 JSON 里,而不是写回 watcher-config.json —— 那份是插件每次
# 重启都会**整份重写**的配置投影,往里写运行时状态会在下次启动时被冲掉。
#
# 读回来的值必须重新校验:显示器拔了、分辨率变了、窗口被拖到不存在的坐标上,
# 都不能让窗弹到看不见的地方。位置只接受"至少有一角落在虚拟桌面内",
# 尺寸按 MinimumSize 夹一遍。
# 路径每次现算,不缓存成脚本级变量 —— 两个理由:
#   1. 测试会把这个函数单独抠出来跑,那时脚本级变量还没赋值;
#   2. 兜底值必须**永远**是绝对路径。写成 Join-Path $tempDir 而 $tempDir 又恰好
#      为空时,会退化成相对路径 "dialog-state.json",落到当前工作目录里 ——
#      真机上 cwd 是用户的随便哪个文件夹,文件就丢了。
function Get-StatePath {
  if ($config.statePath) { return [string]$config.statePath }
  $dir = if ($tempDir) { [string]$tempDir } else { [System.IO.Path]::GetTempPath() }
  return Join-Path $dir "dialog-state.json"
}

function Get-RememberedGeometry {
  try {
    $statePath = Get-StatePath
    if (-not (Test-Path $statePath)) { return $null }
    $s = Get-Content $statePath -Raw | ConvertFrom-Json
    $rx = [int]$s.x; $ry = [int]$s.y
    $rw = [int]$s.width; $rh = [int]$s.height
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    # 窗口得**整个**落在虚拟桌面内才认。只判一个角不够:宽 800 的窗钉在
    # 屏幕最右边只露 10px,用户同样够不着标题栏去拖回来。
    if ($rw -le 0 -or $rh -le 0) { return $null }
    if ($rx -lt $vs.Left -or $ry -lt $vs.Top) { return $null }
    if (($rx + $rw) -gt $vs.Right -or ($ry + $rh) -gt $vs.Bottom) { return $null }
    return @{ x = $rx; y = $ry; width = $rw; height = $rh }
  } catch { return $null }
}

function Save-RememberedGeometry([int]$x, [int]$y, [int]$w, [int]$h) {
  # 最小化/最大化时不记 —— 那时候的 Bounds 不是用户想要的位置。
  if ($w -le 0 -or $h -le 0) { return }
  try {
    $statePath = Get-StatePath
    $obj = @{ x = $x; y = $y; width = $w; height = $h }
    $json = $obj | ConvertTo-Json -Compress
    # 先写临时文件再 Move —— 半截 JSON 会让下次启动读不到位置,
    # 而 Move 在同一卷上是原子的。
    $tmp = "$statePath.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding $false))
    if (Test-Path $statePath) { Remove-Item $statePath -Force -ErrorAction SilentlyContinue }
    Move-Item -LiteralPath $tmp -Destination $statePath -Force -ErrorAction SilentlyContinue
  } catch { }
}

function Show-CaptureDialog {
  param([string]$ImagePath, [int]$AutoCloseMs = 0)
  $form = New-Object System.Windows.Forms.Form
  $img = $null
  $autoTimer = $null
  try {
  $form.Text = "截图入库"
  # SizableToolWindow:保留"工具窗"外观(无任务栏图标、窄标题栏),但**四边可拖动改大小**。
  # 早先是 FixedToolWindow,尺寸只能在设置页里填数字,想临时放大看细节就得去改配置。
  $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::SizableToolWindow
  $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
  $form.TopMost = $true
  $form.ShowInTaskbar = $false
  $form.KeyPreview = $true
  $form.MaximizeBox = $false
  $form.MinimizeBox = $false
  # 可调整大小时给个下限,别让人把窗拖成一条缝(里面的按钮就再也点不到了)。
  # 高度 240 是按布局算的:预览图以外固定开销 156px(见下面 $relayout),
  # 预览至少留 40px → 200px 才不挤;再留点余量。
  $form.MinimumSize = New-Object System.Drawing.Size(220, 240)

  $img = [System.Drawing.Image]::FromFile($ImagePath)
  $maxW = [int]$config.previewMaxWidth
  $w = [Math]::Max(1, $img.Width)
  $h = [Math]::Max(1, $img.Height)

  $bw = 88; $bh = 32; $pad = 8; $gap = 6
  # 按钮行占用的最小宽度:窗宽再怎么被固定值压,也不能压到按钮排不下。
  $rowW = $pad * 2 + $bw * 2 + $gap
  $fixedW = [int]$config.width
  $fixedH = [int]$config.height

  # --- 宽度 ---------------------------------------------------------------
  # 固定宽度时,预览框直接铺满可用宽度 —— PictureBox 用 Zoom 模式,内部按
  # 等比缩放显示,所以框比图宽也不会变形,只是小图会居中留白(比缩在左上角
  # 一片空白好看)。框高度仍按图片原始宽高比算。
  # 自适应宽度时维持老行为:只缩不放,小图保底 160x100。
  $availW = if ($fixedW -gt 0) { [Math]::Max(1, $fixedW - $pad * 2) } else { $maxW }
  $scale = [Math]::Min(1.0, [double]$availW / [double]$w)
  if ($fixedW -gt 0) {
    $pw = $availW
    $ph = [Math]::Max(1, [int]($h * ([double]$availW / [double]$w)))
  } else {
    $pw = [Math]::Max(160, [int]($w * $scale))
    $ph = [Math]::Max(100, [int]($h * $scale))
  }

  # 固定高度时,预览框不能把注释框挤没:先给它留出 40px 的注释区,
  # 剩下的垂直空间才是预览上限(按宽高比反算框宽,保持铺满效果)。
  if ($fixedH -gt 0) {
    $chrome = 8 + 8 + 40 + 6 + 24 + 10 + $bh + $pad  # 预览以外所有固定开销
    $maxPh = [Math]::Max(1, $fixedH - $chrome)
    if ($ph -gt $maxPh) {
      $ph = $maxPh
      $pw = [Math]::Max(1, [int]($w * ([double]$ph / [double]$h)))
    }
  }

  # 窗宽取「按钮行」与「预览图」两者较宽的那个;固定宽度时以固定值为准(但不低于按钮行)。
  $totalW = if ($fixedW -gt 0) { [Math]::Max($rowW, $fixedW) } else { [Math]::Max($rowW, $pw + $pad * 2) }
  $noteW = $totalW - $pad * 2
  $noteH = 60
  $noteY = 8 + $ph + 8
  $chkY = $noteY + $noteH + 6
  $rowY = $chkY + 24 + 10
  $totalH = $rowY + $bh + $pad

  # --- 高度 ---------------------------------------------------------------
  # 固定高度时,多出来的高度全部给注释框 —— 它是窗里唯一适合拉伸的控件
  # (预览图拉伸会糊,按钮行拉伸没意义)。注释框自身保底 40px;
  # 若用户给的固定高度连"注释框 40 + 勾选框 + 按钮行"都放不下,以内容高度为准。
  if ($fixedH -gt 0) {
    $minH = $noteY + 40 + 6 + 24 + 10 + $bh + $pad
    $target = [Math]::Max($fixedH, $minH)
    $noteH = [Math]::Max(40, $noteH + ($target - $totalH))
    $chkY = $noteY + $noteH + 6
    $rowY = $chkY + 24 + 10
    $totalH = $rowY + $bh + $pad
  }

  $pic = New-Object System.Windows.Forms.PictureBox
  $pic.Width = $pw
  $pic.Height = $ph
  $pic.Image = $img
  $pic.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
  $pic.Location = New-Object System.Drawing.Point($pad, 8)

  $noteBox = New-Object System.Windows.Forms.TextBox
  $noteBox.Multiline = $true
  $noteBox.AcceptsReturn = $true
  $noteBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
  $noteBox.Width = $noteW
  $noteBox.Height = $noteH
  $noteBox.Location = New-Object System.Drawing.Point($pad, $noteY)
  $noteBox.Font = New-Object System.Drawing.Font("Microsoft YaHei", 9)
  try { $noteBox.PlaceholderText = "截图注释 / 评论(可选)…" } catch {}

  $chkKey = New-Object System.Windows.Forms.CheckBox
  $chkKey.Text = "重点"
  $chkKey.Width = 80; $chkKey.Height = 24
  $chkKey.Location = New-Object System.Drawing.Point($pad, $chkY)
  $chkKey.Font = New-Object System.Drawing.Font("Microsoft YaHei", 9)
  $chkKey.Checked = $false

  # 只有两个按钮:存文档 / 存图片。
  # 曾经的「复制截图」去掉了 —— 剪贴板本来就还是原图,这个按钮等于"什么都不做",
  # 想让剪贴板留着不动的用户直接按 Esc / 让它自动关就行。
  $bDoc = New-Object System.Windows.Forms.Button
  $bDoc.Text = "存文档"; $bDoc.Tag = "doc"; $bDoc.Width = $bw; $bDoc.Height = $bh
  $bDoc.Location = New-Object System.Drawing.Point($pad, $rowY)
  $bDoc.Add_Click({ $form.Tag = "doc"; $form.DialogResult = [System.Windows.Forms.DialogResult]::OK })

  $bImg = New-Object System.Windows.Forms.Button
  $bImg.Text = "存图片"; $bImg.Tag = "img"; $bImg.Width = $bw; $bImg.Height = $bh
  $bImg.Location = New-Object System.Drawing.Point(($pad + $bw + $gap), $rowY)
  $bImg.Add_Click({ $form.Tag = "img"; $form.DialogResult = [System.Windows.Forms.DialogResult]::Yes })

  $form.AcceptButton = $bDoc
  # Esc = 忽略(不写库、剪贴板原样保留)。窗体上没有 CancelButton 了(那个按钮就是
  # 被删掉的「复制截图」),所以 Esc 靠下面这个 KeyDown 处理器显式设 DialogResult 关窗。
  $form.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $form.Tag = "ignore"; $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel } })

  $form.Controls.AddRange(@($pic, $noteBox, $chkKey, $bDoc, $bImg))
  $form.ClientSize = New-Object System.Drawing.Size($totalW, $totalH)

  # --- 拖动边框改大小后的重新布局 ---------------------------------------------
  # 只有**预览图**跟着窗口伸缩:PicBox 是 Zoom 模式(等比缩放,放大不糊),
  # 拉大窗口正好是为了看清截图细节。注释框、勾选框、按钮行保持各自尺寸。
  #
  # 注释框高度用**当前值**而不是构造时的 $noteH:配置里填了 dialogHeight 时,
  # 初始布局会把多出来的高度给注释框(它是窗里唯一适合纵向拉伸的控件)。
  # 若这里写死 $noteH,用户一拖窗注释框就"缩回去"了,看着像闪一下。
  # 同时给它一个上限 —— 窗被拖矮时必须让注释框跟着缩,否则会顶出窗外。
  $relayout = {
    $cw = [int]$form.ClientSize.Width
    $ch = [int]$form.ClientSize.Height
    $innerW = [Math]::Max(1, $cw - $pad * 2)
    # 预览图以下(注释框 + 勾选框 + 按钮行 + 间距)是固定开销
    $chromeBelow = 6 + 24 + 10 + $bh + $pad
    # 注释框最多能占多高:至少给预览图留 40px
    $noteMax = [Math]::Max(40, $ch - 16 - 40 - $chromeBelow)
    $useNoteH = [Math]::Min([Math]::Max(40, [int]$noteBox.Height), $noteMax)
    $newPicH = [Math]::Max(40, $ch - 16 - $useNoteH - $chromeBelow)
    $pic.Size = New-Object System.Drawing.Size($innerW, $newPicH)
    $newNoteY = 8 + $newPicH + 8
    $noteBox.Location = New-Object System.Drawing.Point($pad, $newNoteY)
    $noteBox.Size = New-Object System.Drawing.Size($innerW, $useNoteH)
    $newChkY = $newNoteY + $useNoteH + 6
    $chkKey.Location = New-Object System.Drawing.Point($pad, $newChkY)
    $newRowY = $newChkY + 24 + 10
    $bDoc.Location = New-Object System.Drawing.Point($pad, $newRowY)
    $bImg.Location = New-Object System.Drawing.Point(($pad + $bw + $gap), $newRowY)
  }.GetNewClosure()
  $form.Add_Resize($relayout)

  # --- 自动关闭 ---------------------------------------------------------------
  # 到点自己关窗,等同「忽略」(和 Esc 一样):剪贴板原样保留、不写库、不弹下一层。
  # 必须用 System.Windows.Forms.Timer:只有跑在 UI 消息泵里的 Timer 才能安全地
  # 改 DialogResult 再 Close;Threading.Timer / Start-Sleep 会在别的线程上动控件。
  # 计时只在窗体真正显示后开始(Add_Shown),否则构造+布局的时间也算进去。
  #
  # 鼠标停在窗口上时**不走倒计时**:指针压在窗上说明用户正在看预览 / 准备点按钮,
  # 这时候关窗是在跟人抢手。指针离开后重新给满一轮,所以"5 秒"是
  # "你不碰它 5 秒"而不是"从弹出算 5 秒"。判据用屏幕坐标比较
  # Cursor.Position 与 Form.Bounds —— 窗是按 offsetX/offsetY 摆在光标右下方,
  # 所以刚弹出时指针在窗**外**,不移动的话照常倒计时。
  #
  # 敲键盘 / 改注释 / 勾重点 / 点窗口也把倒计时喂满,免得写到一半窗没了。
  $state = @{ left = $AutoCloseMs; autoClosed = $false; hovering = $false }
  if ($AutoCloseMs -gt 0) {
    $autoTimer = New-Object System.Windows.Forms.Timer
    $autoTimer.Interval = 250
    $autoTimer.Add_Tick({
      $inside = $form.Bounds.Contains((Get-PointerPosition))
      if ($inside) {
        # 停在窗上:冻结倒计时,不关。
        $state.hovering = $true
        return
      }
      if ($state.hovering) {
        # 刚从窗上离开:给满一轮,而不是接着数那剩下的零点几秒。
        $state.hovering = $false
        $state.left = $AutoCloseMs
      }
      if ($state.left -le 0) {
        $autoTimer.Stop()
        $state.autoClosed = $true
        if (-not $form.Tag) { $form.Tag = "ignore" }
        $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.Close()
        return
      }
      $state.left -= 250
    }.GetNewClosure())
    $bump = { $state.left = $AutoCloseMs }.GetNewClosure()
    $form.Add_KeyDown($bump)
    $form.Add_MouseDown($bump)
    $noteBox.Add_TextChanged($bump)
    $chkKey.Add_CheckedChanged($bump)
    $form.Add_Shown({ $autoTimer.Start() }.GetNewClosure())
  }

  # --- 位置 ---------------------------------------------------------------
  # 三种模式:
  #   cursor(默认):跟着鼠标,按 offsetX/offsetY 摆在光标右下方;放不下就翻到
  #                 左上侧(历史行为,原样保留)。
  #   fixed        :每次都出现在 fixedX/fixedY 这个**屏幕坐标**上,与鼠标无关。
  #                 多显示器下坐标系是整个虚拟桌面(副屏在主屏左边时 x 为负),
  #                 所以这里用 VirtualScreen 而不是某个 Screen 的 WorkingArea ——
  #                 否则钉在副屏上的窗会被 clamp 回主屏。
  #   remember     :沿用上次关闭时的位置**和大小**。没记录过(或记录已失效,
  #                 比如那块屏拔了)就退回 cursor 行为,不至于弹到看不见的地方。
  # 三种模式都保留"别跑出屏幕"的收敛,但 fixed 模式下若用户明确钉在副屏,
  # 只要该点在虚拟桌面内就按用户说的摆。
  $totalW = [int]$totalW
  $totalH = [int]$totalH
  $remembered = Get-RememberedGeometry
  $useRemember = ([string]$config.positionMode -eq "remember") -and ($null -ne $remembered)
  if ($useRemember) {
    # 记录的是**外框**矩形(Left/Top/Width/Height),所以还原也用外框,
    # 不能用 ClientSize —— 两边混着用会让窗口每开一次就胖一圈边框。
    $totalW = [Math]::Max([int]$remembered.width, [int]$form.MinimumSize.Width)
    $totalH = [Math]::Max([int]$remembered.height, [int]$form.MinimumSize.Height)
    $x = [int]$remembered.x
    $y = [int]$remembered.y
    $form.Size = New-Object System.Drawing.Size($totalW, $totalH)
  } elseif ([string]$config.positionMode -eq "fixed") {
    $x = [int]$config.fixedX
    $y = [int]$config.fixedY
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    # 只在"完全落在虚拟桌面之外"时才拉回来,不因为贴边而挪动用户指定的坐标。
    if ($x + $totalW -le $vs.Left -or $x -ge $vs.Right) {
      $x = [Math]::Max($vs.Left, [Math]::Min($x, $vs.Right - $totalW))
    }
    if ($y + $totalH -le $vs.Top -or $y -ge $vs.Bottom) {
      $y = [Math]::Max($vs.Top, [Math]::Min($y, $vs.Bottom - $totalH))
    }
  } else {
    $cursor = Get-PointerPosition
    $screen = [System.Windows.Forms.Screen]::FromPoint($cursor)
    $wa = $screen.WorkingArea
    $x = $cursor.X + [int]$config.offsetX
    $y = $cursor.Y + [int]$config.offsetY
    if ($x + $totalW -gt $wa.Right)  { $x = $cursor.X - $totalW - [int]$config.offsetX }
    if ($y + $totalH -gt $wa.Bottom) { $y = $cursor.Y - $totalH - [int]$config.offsetY }
    $x = [Math]::Max($wa.Left, $x)
    $y = [Math]::Max($wa.Top, $y)
  }
  $form.Location = New-Object System.Drawing.Point($x, $y)

  # 关窗时把外框位置记下来。所有关法都走这里 —— 按钮、Esc、右上角 X、
  # 自动关闭倒计时,对用户来说都是"我把窗放在这儿了"。
  # 用 GetNewClosure():这个处理器在 ShowDialog 的消息泵里执行,那时函数的
  # 局部作用域已经不在栈上,不捕获就会读到 $null。
  $form.Add_FormClosing({
    try {
      if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Normal) {
        Save-RememberedGeometry $form.Left $form.Top $form.Width $form.Height
      }
    } catch { }
  }.GetNewClosure())

  [void]$form.ShowDialog()
  if ($autoTimer) { $autoTimer.Stop() }
  $action = if ($form.Tag) { $form.Tag.ToString() } else { "ignore" }
  $note = $noteBox.Text.Trim()
  $isKey = [bool]$chkKey.Checked
  return @{ action = $action; note = $note; isKey = $isKey; autoClosed = [bool]$state.autoClosed }
  } finally {
    if ($null -ne $autoTimer) { $autoTimer.Dispose() }
    if ($null -ne $form) { $form.Dispose() }
    if ($null -ne $img) { $img.Dispose() }
  }
}

Write-Event @{ t = "ready" }
$lastSeq = [WinClip]::GetClipboardSequenceNumber()
$lastHandled = [DateTime]::Now

while ($true) {
  Start-Sleep -Milliseconds ([int]$config.pollIntervalMs)
  $seq = 0
  try { $seq = [WinClip]::GetClipboardSequenceNumber() } catch { continue }
  if ($seq -eq $lastSeq) { continue }
  $lastSeq = $seq
  $now = [DateTime]::Now
  if (($now - $lastHandled).TotalMilliseconds -lt [int]$config.cooldownMs) { continue }
  if (-not [System.Windows.Forms.Clipboard]::ContainsImage()) { continue }
  $img = $null
  try { $img = [System.Windows.Forms.Clipboard]::GetImage() } catch { continue }
  if ($null -eq $img) { continue }
  $sig = Get-ImageSignature $img
  if (Test-DuplicateCapture $sig $now) {
    $img.Dispose()
    Write-Event @{ t = "dup"; seq = $seq }
    continue
  }
  Remember-Signature $sig $now
  $lastHandled = $now
  $ts = Get-Date -Format "yyyyMMdd_HHmmss_fff"
  $pngPath = Join-Path $tempDir ("clip_{0}.png" -f $ts)
  try {
    $img.Save($pngPath, [System.Drawing.Imaging.ImageFormat]::Png)
  } catch {
    $img.Dispose()
    Write-Event @{ t = "err"; msg = "save: $($_.Exception.Message)" }
    continue
  }
  $img.Dispose()
  Write-Event @{ t = "img"; path = $pngPath; seq = $seq }

  if ($AutoAction) {
    if ($AutoAction -ne "none") { Write-Event @{ t = "choice"; action = $AutoAction; path = $pngPath } }
    if ($Once) { break }
    continue
  }

  $res = @{ action = "ignore"; note = ""; isKey = $false; autoClosed = $false }
  $autoCloseMs = [int](($config.autoCloseSec * 1000))
  try { $res = Show-CaptureDialog -ImagePath $pngPath -AutoCloseMs $autoCloseMs } catch {
    Write-Event @{ t = "err"; msg = "dialog: $($_.Exception.Message)" }
  }
  Write-Event @{ t = "choice"; action = $res.action; path = $pngPath; note = $res.note; isKey = $res.isKey; autoClosed = $res.autoClosed }
  if ($Once) { break }
}
