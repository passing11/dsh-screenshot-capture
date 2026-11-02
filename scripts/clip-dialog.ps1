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

# 剪贴板序列号的唯一入口。
#
# 和 Get-PointerPosition 同样的理由留一个测试接缝:真剪贴板在这台机器上被
# 浏览器长期占着(OpenClipboard 连续 8 次失败),测试没法靠它验证刷新逻辑。
# 测试把 $script:SeqOverride 设成一个返回整数的 scriptblock,就能**模拟**
# "用户又截了一张图",完全不动系统剪贴板。
$script:SeqOverride = $null
function Get-ClipboardSeq {
  if ($null -ne $script:SeqOverride) { return [int](& $script:SeqOverride) }
  return [int][WinClip]::GetClipboardSequenceNumber()
}

# --- 剪贴板读取与临时落盘 ---------------------------------------------------
# 主循环和「窗口开着时盯新截图」都要这两步,抽出来免得两份实现走偏。
# 剪贴板是全局资源,别的程序(浏览器、截图工具)随时可能占着它:
# ContainsImage / GetImage 都可能抛,一律当"这会儿没图"处理,不中断监听。

# 读当前剪贴板里的图片,没有或读不到就返回 $null。**调用方负责 Dispose**。
# $script:ClipboardImageOverride 是同一个测试接缝:返回一张现成的位图,
# 就能在完全不碰系统剪贴板的前提下驱动刷新。
$script:ClipboardImageOverride = $null
function Read-ClipboardImage {
  if ($null -ne $script:ClipboardImageOverride) {
    return (& $script:ClipboardImageOverride)
  }
  try {
    if (-not [System.Windows.Forms.Clipboard]::ContainsImage()) { return $null }
  } catch { return $null }
  try { return [System.Windows.Forms.Clipboard]::GetImage() } catch { return $null }
}

# 把图存成临时 png,返回路径;失败返回 $null。
# 同一毫秒里连存两张会撞名(时间戳只到毫秒),撞了就顺延 _2 / _3。
function Save-ClipboardImageToTemp([System.Drawing.Image]$img) {
  $ts = Get-Date -Format "yyyyMMdd_HHmmss_fff"
  $pngPath = Join-Path $tempDir ("clip_{0}.png" -f $ts)
  $n = 1
  while (Test-Path $pngPath) {
    $n++
    $pngPath = Join-Path $tempDir ("clip_{0}_{1}.png" -f $ts, $n)
  }
  try {
    $img.Save($pngPath, [System.Drawing.Imaging.ImageFormat]::Png)
    return $pngPath
  } catch {
    Write-Event @{ t = "err"; msg = "save: $($_.Exception.Message)" }
    return $null
  }
}

# 把窗里的预览换成新图,并把旧的那张临时图删掉。
#
# 抽成函数是为了能测:它只动 $pic 和 $state,完全不碰剪贴板,所以测试可以
# 拿一张现成的位图直接调,不用去抢那块被浏览器长期占着的剪贴板。
#
# 只换图、不动窗口大小:窗可能已经被拖过、或者按 remember 还原过,按新图的
# 尺寸去改窗会把用户刚摆好的位置和大小冲掉。PicBox 是 Zoom 模式,比例不同
# 就居中留白,不会变形。
function Set-DialogImage {
  param($state, $pic, [System.Drawing.Image]$newImg, [string]$newPath)
  $oldImg = $pic.Image
  $pic.Image = $newImg
  $pic.Refresh()
  # 旧图要 Dispose,否则每换一张漏一份 GDI+ 句柄。ReferenceEquals 判一下:
  # 极端情况下新图就是旧图本身,那就别把它释放了。
  if (($null -ne $oldImg) -and (-not [object]::ReferenceEquals($oldImg, $newImg))) {
    try { $oldImg.Dispose() } catch { }
  }
  $oldPath = $state.path
  $state.path = $newPath
  $state.image = $newImg
  # 旧的那张临时图不再需要 —— 用户明确说了「原来的截图不用」。
  if ($oldPath -and ($oldPath -ne $newPath)) {
    try { Remove-Item -LiteralPath $oldPath -Force -ErrorAction SilentlyContinue } catch { }
  }
  $state.refreshes = [int]$state.refreshes + 1
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

# --- 弹窗内的布局计算 -------------------------------------------------------
#
# 单独抽成纯函数:给定客户区大小和图片原始尺寸,算出预览框该多大、注释框
# 该多高、各自摆在哪。抽出来有两个好处 —— 能脱离真实弹窗单独跑测试,
# 而且"用户拖边框改大小"和"窗开着时换了张比例不同的图"能共用同一套算法。
#
# 核心约束:**预览框必须和图片同宽高比**。PictureBox 是 Zoom 模式,框比图
# 胖或瘦都会出现灰边(letterbox)—— 而灰边正是"图没完全展开"的观感:
# 用户看到的是一张图缩在一大片空白中间。所以框的尺寸一律按图片宽高比反算,
# 多出来的纵向空间全给注释框(窗里唯一适合纵向拉伸的控件)。
function Get-DialogLayout {
  param(
    [int]$ClientW,
    [int]$ClientH,
    [int]$ImageW,
    [int]$ImageH,
    [int]$Pad = 8,
    [int]$Gap = 6,
    [int]$BtnW = 88,
    [int]$BtnH = 32,
    [int]$ChkH = 24,
    [int]$MinPicH = 40,
    [int]$MinNoteH = 60
  )
  $ImageW = [Math]::Max(1, $ImageW)
  $ImageH = [Math]::Max(1, $ImageH)
  $aspect = [double]$ImageW / [double]$ImageH

  $innerW = [Math]::Max(1, $ClientW - $Pad * 2)
  # 预览图与注释框**之外**的所有纵向开销:顶部内边距 + 图与注释框的间距 +
  # 注释框与勾选框的间距 + 勾选框 + 勾选框与按钮行的间距 + 按钮行 + 下边距
  $chrome = $Pad * 3 + $Gap + $ChkH + 10 + $BtnH
  # 预览图 + 注释框能共用的纵向空间
  $avail = [Math]::Max($MinPicH + $MinNoteH, $ClientH - $chrome)

  # 先按"图铺满窗宽"算框高
  $picW = $innerW
  $picH = [Math]::Max(1, [int][Math]::Round($innerW / $aspect))

  if ($picH + $MinNoteH -gt $avail) {
    # 高度不够:图按剩余空间缩,宽度跟着比例收窄(于是图水平居中,两侧留边)
    $picH = [Math]::Max($MinPicH, $avail - $MinNoteH)
    $picW = [Math]::Max(1, [int][Math]::Round($picH * $aspect))
    if ($picW -gt $innerW) { $picW = $innerW }
    $noteH = $MinNoteH
  } else {
    # 高度有富余:图保持满宽(框高恰好等于图高,没有灰边),富余全给注释框
    $noteH = $avail - $picH
  }

  $picX = $Pad + [int](($innerW - $picW) / 2)
  $noteY = $Pad + $picH + $Pad
  $chkY = $noteY + $noteH + $Gap
  $rowY = $chkY + $ChkH + 10

  return @{
    picX = $picX; picY = $Pad; picW = $picW; picH = $picH
    noteX = $Pad; noteY = $noteY; noteW = $innerW; noteH = $noteH
    chkX = $Pad; chkY = $chkY
    rowX = $Pad; rowY = $rowY
    innerW = $innerW
  }
}

function Show-CaptureDialog {
  param([string]$ImagePath, [int]$AutoCloseMs = 0, [int]$Seq = 0)
  $form = New-Object System.Windows.Forms.Form
  $img = $null
  $autoTimer = $null
  $refreshTimer = $null
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

  # --- 初始尺寸 ---------------------------------------------------------------
  # 宽度:固定值优先(但不低于按钮行),否则按 previewMaxWidth。
  $totalW = if ($fixedW -gt 0) { [Math]::Max($rowW, $fixedW) } else { [Math]::Max($rowW, $maxW + $pad * 2) }

  # 自适应宽度时**不放大**小图:100x100 的图标铺到 320 宽只会变糊。
  # 窗宽跟着图片收窄(仍不低于按钮行)。固定宽度时按用户要求铺满。
  if ($fixedW -le 0 -and $w -lt ($totalW - $pad * 2)) {
    $totalW = [Math]::Max($rowW, $w + $pad * 2)
  }

  # 高度:按"预览图铺满窗宽 + 注释框 60px"算出自然高度。
  # 关键是这里算的是**图片真实高度**(innerW / 宽高比) —— 老代码算的是
  # "按 maxW 缩放后的高度",两者在固定宽度下数值相同,但框的尺寸一旦和
  # 图片比例脱钩,PictureBox 的 Zoom 模式就会在框里留灰边。
  $innerW0 = [Math]::Max(1, $totalW - $pad * 2)
  $chrome0 = $pad * 3 + $gap + 24 + 10 + $bh
  $picH0 = [Math]::Max(1, [int][Math]::Round($innerW0 * ([double]$h / [double]$w)))
  $naturalH = $chrome0 + $picH0 + 60

  # 固定高度以固定值为准,但不能矮到连"预览 40 + 注释 60"都放不下。
  $totalH = if ($fixedH -gt 0) { [Math]::Max($fixedH, $chrome0 + 40 + 60) } else { $naturalH }

  $layout = Get-DialogLayout -ClientW $totalW -ClientH $totalH -ImageW $w -ImageH $h `
    -Pad $pad -Gap $gap -BtnW $bw -BtnH $bh
  $pw = $layout.picW; $ph = $layout.picH
  $noteW = $layout.noteW; $noteH = $layout.noteH
  $noteY = $layout.noteY
  $chkY = $layout.chkY
  $rowY = $layout.rowY

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

  # --- 窗口状态 ---------------------------------------------------------------
  # 必须先建 $state 再挂 $relayout:GetNewClosure() 只捕获**创建闭包那一刻**
  # 已经存在的变量,晚于它定义的 $state 会永远读到 $null。
  $state = @{ left = $AutoCloseMs; autoClosed = $false; hovering = $false }
  # 窗口开着时又来了新截图 → 原地换图,不再弹第二个窗。
  #   path      : 当前窗里这张图的临时路径(关窗后由调用方负责删)
  #   image     : 当前这张图本身,换图时要 Dispose 旧的
  #   seq       : 剪贴板序列号,用来判断"有没有新的截图"
  #   refreshes : 换过几次(测试与日志用)
  $state.path = $ImagePath
  $state.image = $img
  $state.seq = $Seq
  $state.refreshes = 0

  # --- 拖动边框改大小后的重新布局 ---------------------------------------------
  # 只有**预览图**跟着窗口伸缩:PicBox 是 Zoom 模式(等比缩放,放大不糊),
  # 拉大窗口正好是为了看清截图细节。注释框、勾选框、按钮行保持各自尺寸。
  #
  # 预览框尺寸一律由 Get-DialogLayout 按**当前图**的宽高比算 —— 框和图片比例
  # 一致,Zoom 模式下就不会出现灰边(灰边正是"图没完全展开"的观感)。
  # 用 $state.image 而不是构造时的 $img:窗开着时可能换过图,比例未必一样。
  $relayout = {
    $curImg = $state.image
    $cw = [int]$form.ClientSize.Width
    $ch = [int]$form.ClientSize.Height
    if ($null -eq $curImg -or $cw -le 0 -or $ch -le 0) { return }
    $L = Get-DialogLayout -ClientW $cw -ClientH $ch -ImageW $curImg.Width -ImageH $curImg.Height `
      -Pad $pad -Gap $gap -BtnW $bw -BtnH $bh
    $pic.Location = New-Object System.Drawing.Point($L.picX, $L.picY)
    $pic.Size = New-Object System.Drawing.Size($L.picW, $L.picH)
    $noteBox.Location = New-Object System.Drawing.Point($L.noteX, $L.noteY)
    $noteBox.Size = New-Object System.Drawing.Size($L.noteW, $L.noteH)
    $chkKey.Location = New-Object System.Drawing.Point($L.chkX, $L.chkY)
    $bDoc.Location = New-Object System.Drawing.Point($L.rowX, $L.rowY)
    $bImg.Location = New-Object System.Drawing.Point(($L.rowX + $bw + $gap), $L.rowY)
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

  # --- 窗口开着时盯新截图 -----------------------------------------------------
  # ShowDialog 是**模态**调用:它跑自己的消息泵,主循环那圈 while 在它返回之前
  # 一步都不走。所以窗口开着的时候,剪贴板其实没人看 —— 用户连截两张,
  # 第二张会被 cooldown 吞掉、或者干脆等到窗关了才处理。
  #
  # 这里挂一个 WinForms Timer 在**模态消息泵内部**轮询:发现剪贴板序列号变了、
  # 而且新内容确实是图,就地把预览换成新图,并删掉上一张临时图(用户要求
  # 「原来的截图不用」)。不弹第二个窗、不动窗口位置和大小 —— 用户可能已经把
  # 它拖到顺手的地方了。
  #
  # 为什么不在主循环里改:那要求把 ShowDialog 换成 Show + Application.Run,
  # 会连带改掉"窗关掉之后才拿到返回值"的整套控制流,风险大得多。
  #
  # 去重仍然走同一套 Test-DuplicateCapture:Windows 截图工具会在几秒内把同一张
  # 屏推两次,那种情况不该刷新(否则用户会觉得窗在闪)。
  $refreshTimer = New-Object System.Windows.Forms.Timer
  $refreshTimer.Interval = [Math]::Max(120, [int]$config.pollIntervalMs)
  $refreshTimer.Add_Tick({
    try {
      $seqNow = 0
      try { $seqNow = Get-ClipboardSeq } catch { return }
      if ($seqNow -eq $state.seq) { return }   # 剪贴板没动过
      $state.seq = $seqNow
      $newImg = Read-ClipboardImage
      if ($null -eq $newImg) { return }        # 换成文字/文件了,窗里这张留着
      $now = [DateTime]::Now
      $sig = Get-ImageSignature $newImg
      if (Test-DuplicateCapture $sig $now) {
        $newImg.Dispose()
        return
      }
      Remember-Signature $sig $now
      $newPath = Save-ClipboardImageToTemp $newImg
      if ($null -eq $newPath) {
        $newImg.Dispose()
        return
      }
      Set-DialogImage -state $state -pic $pic -newImg $newImg -newPath $newPath
      # 换过图就重置自动关闭倒计时:用户刚截了新图,正要看这一张。
      if ($AutoCloseMs -gt 0) { $state.left = $AutoCloseMs }
      Write-Event @{ t = "refresh"; path = $newPath; seq = $seqNow }
    } catch {
      # 定时器里抛异常会把整个消息泵带走,一律吞掉并记账。
      Write-Event @{ t = "err"; msg = "refresh: $($_.Exception.Message)" }
    }
  }.GetNewClosure())
  $form.Add_Shown({ $refreshTimer.Start() }.GetNewClosure())

  # --- 位置 ---------------------------------------------------------------
  # 三种模式各管各的,互不干扰:
  #   cursor(默认):跟着鼠标,按 offsetX/offsetY 摆在光标右下方;放不下就翻到
  #                 左上侧(历史行为,原样保留)。
  #   fixed        :出现在 fixedX/fixedY 这个**屏幕坐标**上,与鼠标无关。
  #                 多显示器下坐标系是整个虚拟桌面(副屏在主屏左边时 x 为负),
  #                 所以这里用 VirtualScreen 而不是某个 Screen 的 WorkingArea ——
  #                 否则钉在副屏上的窗会被 clamp 回主屏。
  #   remember     :沿用上次关闭时的位置和大小(**外框**矩形)。没有记录时退回
  #                 cursor 行为 —— 宁可弹在鼠标旁,也不弹在不知道哪儿的角落。
  #
  # 记录文件是**无条件写入**的(不管当前是哪个模式),只是只有 remember 读它。
  # 这样临时切到别的模式看看效果,再切回来,上次摆的位置还在。
  $totalW = [int]$totalW
  $totalH = [int]$totalH
  $remembered = $null
  if ([string]$config.positionMode -eq "remember") {
    $remembered = Get-RememberedGeometry
  }
  if ($null -ne $remembered) {
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
  if ($null -ne $refreshTimer) { $refreshTimer.Stop() }
  $action = if ($form.Tag) { $form.Tag.ToString() } else { "ignore" }
  $note = $noteBox.Text.Trim()
  $isKey = [bool]$chkKey.Checked
  # path 是**最终**显示的那张:窗口开着时换过图的话,它已经不是传进来的 $ImagePath 了。
  # 调用方要拿它写 choice 事件,否则存进库的是第一张、用户看到的是最后一张。
  return @{
    action = $action; note = $note; isKey = $isKey
    autoClosed = [bool]$state.autoClosed
    path = $state.path
    refreshes = [int]$state.refreshes
  }
  } finally {
    if ($null -ne $autoTimer) { $autoTimer.Dispose() }
    if ($null -ne $refreshTimer) { $refreshTimer.Dispose() }
    # 换过图的话,$img 早在 Set-DialogImage 里释放过了;这里要释放的是
    # 窗里**当前**那张(两者相同时只释放一次)。
    if ($null -ne $state -and $null -ne $state.image -and (-not [object]::ReferenceEquals($state.image, $img))) {
      try { $state.image.Dispose() } catch { }
    }
    if ($null -ne $form) { $form.Dispose() }
    if ($null -ne $img) { $img.Dispose() }
  }
}

Write-Event @{ t = "ready" }
$lastSeq = Get-ClipboardSeq
$lastHandled = [DateTime]::Now

while ($true) {
  Start-Sleep -Milliseconds ([int]$config.pollIntervalMs)
  $seq = 0
  try { $seq = Get-ClipboardSeq } catch { continue }
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
  $pngPath = Save-ClipboardImageToTemp $img
  $img.Dispose()
  if ($null -eq $pngPath) { continue }
  Write-Event @{ t = "img"; path = $pngPath; seq = $seq }

  if ($AutoAction) {
    if ($AutoAction -ne "none") { Write-Event @{ t = "choice"; action = $AutoAction; path = $pngPath } }
    if ($Once) { break }
    continue
  }

  $res = @{ action = "ignore"; note = ""; isKey = $false; autoClosed = $false; path = $pngPath; refreshes = 0 }
  $autoCloseMs = [int](($config.autoCloseSec * 1000))
  try { $res = Show-CaptureDialog -ImagePath $pngPath -AutoCloseMs $autoCloseMs -Seq $seq } catch {
    Write-Event @{ t = "err"; msg = "dialog: $($_.Exception.Message)" }
  }
  # 窗开着时换过图的话,$res.path 是**最后那张**,不是 $pngPath。
  # 存库得按用户真正看到的那张来,否则存进去的和眼前的对不上。
  # 换图时 Set-DialogImage 已经删掉被替掉的那几张,这里只补刀。
  if ($res.path -and ($res.path -ne $pngPath)) {
    try { Remove-Item -LiteralPath $pngPath -Force -ErrorAction SilentlyContinue } catch { }
  }
  $choicePath = if ($res.path) { $res.path } else { $pngPath }
  Write-Event @{ t = "choice"; action = $res.action; path = $choicePath; note = $res.note; isKey = $res.isKey; autoClosed = $res.autoClosed }
  # 主循环也要跟上:窗里已经消化掉的那几次刷新,别在这儿又当成新图弹一遍。
  try { $lastSeq = Get-ClipboardSeq } catch { }
  if ($Once) { break }
}
