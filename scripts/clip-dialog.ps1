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

$config = @{ pollIntervalMs = 200; cooldownMs = 2000; offsetX = 16; offsetY = 16; previewMaxWidth = 320; dupWindowMs = 6000; autoCloseSec = 0 }
if ($ConfigPath -and (Test-Path $ConfigPath)) {
  try {
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    foreach ($k in @('pollIntervalMs','cooldownMs','offsetX','offsetY','previewMaxWidth','dupWindowMs','autoCloseSec')) {
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

function Show-CaptureDialog {
  param([string]$ImagePath, [int]$AutoCloseMs = 0)
  $form = New-Object System.Windows.Forms.Form
  $img = $null
  $autoTimer = $null
  try {
  $form.Text = "截图入库"
  $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedToolWindow
  $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
  $form.TopMost = $true
  $form.ShowInTaskbar = $false
  $form.KeyPreview = $true
  $form.MaximizeBox = $false
  $form.MinimizeBox = $false

  $img = [System.Drawing.Image]::FromFile($ImagePath)
  $maxW = [int]$config.previewMaxWidth
  $w = [Math]::Max(1, $img.Width)
  $h = [Math]::Max(1, $img.Height)
  $scale = [Math]::Min(1.0, $maxW / $w)
  $pw = [Math]::Max(160, [int]($w * $scale))
  $ph = [Math]::Max(100, [int]($h * $scale))

  $bw = 88; $bh = 32; $pad = 8; $gap = 6
  # 窗宽取「按钮行」与「预览图」两者较宽的那个。
  # 曾经只按按钮行算(三键时代 198…不对,292),预览图按 previewMaxWidth 独立算,
  # 两者谁也不管谁 —— 图比窗宽就横向被裁掉一截(2026-10-29 去掉「复制截图」后
  # 从 292 缩到 198,320 宽的预览直接缺了一半才发现)。
  $rowW = $pad * 2 + $bw * 2 + $gap
  $totalW = [Math]::Max($rowW, $pw + $pad * 2)
  $noteW = $totalW - $pad * 2
  $noteH = 60
  $noteY = 8 + $ph + 8
  $chkY = $noteY + $noteH + 6
  $rowY = $chkY + 24 + 10
  $totalH = $rowY + $bh + $pad

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

  $cursor = Get-PointerPosition
  $screen = [System.Windows.Forms.Screen]::FromPoint($cursor)
  $wa = $screen.WorkingArea
  $x = $cursor.X + [int]$config.offsetX
  $y = $cursor.Y + [int]$config.offsetY
  if ($x + $totalW -gt $wa.Right)  { $x = $cursor.X - $totalW - [int]$config.offsetX }
  if ($y + $totalH -gt $wa.Bottom) { $y = $cursor.Y - $totalH - [int]$config.offsetY }
  $x = [Math]::Max($wa.Left, $x)
  $y = [Math]::Max($wa.Top, $y)
  $form.Location = New-Object System.Drawing.Point($x, $y)

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
