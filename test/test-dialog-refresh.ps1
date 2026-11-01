<#
  dsh-screenshot-capture · 悬浮窗「窗口开着时换新截图」的回归测试

  验什么:
    1. Set-DialogImage 把预览换成新图,旧图的临时文件被删掉(用户要求
       「原来的截图不用」)。
    2. 换图**不改窗口尺寸** —— 窗可能已被拖过或按 remember 还原过,按新图
       尺寸去改会把用户刚摆好的位置和大小冲掉。
    3. 新旧图是同一张(ReferenceEquals)时不 Dispose 自己,也不删文件。
    4. 换图次数被记账。
    5. 读剪贴板 / 存临时图这两个辅助函数在"剪贴板里没图"时安静返回 $null,
       不抛异常、不中断监听。
    6. 源码层:Show-CaptureDialog 里挂了刷新定时器,并且用的是
       System.Windows.Forms.Timer(必须在 UI 消息泵里跑)。
    7. Show-CaptureDialog 返回最终显示的那张图的 path(不是最初传进去的),
       否则存进库的图和用户看到的那张对不上。

  做法:Set-DialogImage / Read-ClipboardImage / Save-ClipboardImageToTemp 都是
  纯函数式的(只碰传入的控件和 $tempDir),抠出来在进程内直接调 —— **完全不碰
  剪贴板**。这台机器上 Chrome 长期占着剪贴板,任何 OpenClipboard 都会失败,
  所以"靠真剪贴板弹窗"的端到端测试在这里一律 SKIP,不能作为验证手段。

  用法: powershell -NoProfile -ExecutionPolicy Bypass -File test\test-dialog-refresh.ps1
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

$script:tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('dsc-refresh-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:tempDir -Force | Out-Null

# 这些是被测函数依赖的脚本级东西:事件日志、配置、剪贴板 P/Invoke
$script:logPath = Join-Path $script:tempDir 'events.log'
function Write-Event([hashtable]$obj) {
  $line = $obj | ConvertTo-Json -Compress
  try { [System.IO.File]::AppendAllText($script:logPath, $line + [Environment]::NewLine, [System.Text.Encoding]::UTF8) } catch {}
}
$script:config = @{ pollIntervalMs = 200; dupWindowMs = 6000 }
$script:recentSignatures = @()
$dupPixelsAllowed = 64

Invoke-Expression (Get-FnSource $src 'Get-ImageSignature')
Invoke-Expression (Get-FnSource $src 'Test-SimilarSignature')
Invoke-Expression (Get-FnSource $src 'Test-DuplicateCapture')
Invoke-Expression (Get-FnSource $src 'Remember-Signature')
# 注意顺序:Get-ClipboardSeq 必须在 tick 之前加载,否则 tick 一进去就在
# `try { $seqNow = Get-ClipboardSeq } catch { return }` 上静默返回,
# 后面所有断言都会变成"什么都没发生"的假通过。
Invoke-Expression (Get-FnSource $src 'Get-ClipboardSeq')
Invoke-Expression (Get-FnSource $src 'Read-ClipboardImage')
Invoke-Expression (Get-FnSource $src 'Save-ClipboardImageToTemp')
Invoke-Expression (Get-FnSource $src 'Set-DialogImage')

# 刷新定时器的 Tick 处理器要单独抠出来跑:它闭在 Show-CaptureDialog 里,
# 但那一段只依赖 $state / $pic / $config / $tempDir 和两个接缝函数,
# 所以能在进程内直接驱动,不必真弹一个窗、更不必真碰剪贴板。
# 抠法:从 "$refreshTimer.Add_Tick({" 起到配对的 "}.GetNewClosure())" 止。
function Get-TickSource([string]$text) {
  $marker = '$refreshTimer.Add_Tick({'
  $start = $text.IndexOf($marker)
  if ($start -lt 0) { throw '脚本里没有 $refreshTimer.Add_Tick' }
  $bodyStart = $text.IndexOf('{', $start)
  $depth = 0
  $i = $bodyStart
  for (; $i -lt $text.Length; $i++) {
    if ($text[$i] -eq '{') { $depth++ }
    elseif ($text[$i] -eq '}') { $depth--; if ($depth -eq 0) { break } }
  }
  return $text.Substring($bodyStart, $i - $bodyStart + 1)
}

# 把 tick 原文包成一个函数来调。函数体里读的 $state / $pic / $config / $tempDir
# 都是脚本级变量,PowerShell 的作用域链会自然找到,不用传参也不用闭包。
#
# 注意 $tickSrc **自带一对大括号**,所以这里直接拼在函数名后面:
#   function Invoke-RefreshTick { ... }
# 若写成 "function Invoke-RefreshTick { $tickSrc }" 就成了函数体里只放一个
# 脚本块字面量 —— 调用它只会把那个脚本块**打印出来**,tick 一行都不执行。
$tickSrc = Get-TickSource $src
Invoke-Expression "function Invoke-RefreshTick $tickSrc"

$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail) {
  if ($ok) { "PASS $name" } else { "FAIL $name - $detail"; $script:fail++ }
}

# 造一张纯色图,顺便把文件写到磁盘(模拟"上一张已经落盘")
function New-TestImage([int]$w, [int]$h, [System.Drawing.Color]$color) {
  $bmp = New-Object System.Drawing.Bitmap $w, $h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.Clear($color)
  $g.Dispose()
  return $bmp
}

function Save-TestImage([System.Drawing.Image]$img, [string]$name) {
  $p = Join-Path $script:tempDir $name
  $img.Save($p, [System.Drawing.Imaging.ImageFormat]::Png)
  return $p
}

# ---- 场景 1:换图 —— 预览换成新图,旧的临时文件被删 ----
$oldImg = New-TestImage 300 200 ([System.Drawing.Color]::FromArgb(240, 240, 240))
$oldPath = Save-TestImage $oldImg 'old.png'
$newImg = New-TestImage 640 480 ([System.Drawing.Color]::FromArgb(30, 60, 120))
$newPath = Save-TestImage $newImg 'new.png'

$pic = New-Object System.Windows.Forms.PictureBox
$pic.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
$pic.Size = New-Object System.Drawing.Size(300, 200)
$pic.Image = $oldImg

$state = @{ path = $oldPath; image = $oldImg; seq = 1; refreshes = 0 }

Check '换图前旧文件在' (Test-Path $oldPath) "缺 $oldPath"

Set-DialogImage -state $state -pic $pic -newImg $newImg -newPath $newPath

Check '换图后预览是新图' ([object]::ReferenceEquals($pic.Image, $newImg)) 'pic.Image 没换'
Check '换图后 state.path 指向新文件' ($state.path -eq $newPath) "拿到 $($state.path)"
Check '换图后 state.image 是新图' ([object]::ReferenceEquals($state.image, $newImg)) 'state.image 没换'
Check '旧的临时图被删掉' (-not (Test-Path $oldPath)) "还在:$oldPath"
Check '新的临时图还在' (Test-Path $newPath) "缺 $newPath"
Check '换图次数 +1' ($state.refreshes -eq 1) "拿到 $($state.refreshes)"

# ---- 场景 2:换图不改窗口/预览框尺寸 ----
$sizeBefore = $pic.Size
$old2 = New-TestImage 200 200 ([System.Drawing.Color]::White)
$old2Path = Save-TestImage $old2 'old2.png'
$state.path = $old2Path
$state.image = $old2
$pic.Image = $old2
$tiny = New-TestImage 40 40 ([System.Drawing.Color]::Red)
$tinyPath = Save-TestImage $tiny 'tiny.png'
Set-DialogImage -state $state -pic $pic -newImg $tiny -newPath $tinyPath
Check '换图不改变预览框尺寸' ($pic.Size -eq $sizeBefore) "从 $sizeBefore 变成 $($pic.Size)"

# ---- 场景 3:新旧是同一张 → 不 Dispose、不删文件 ----
$sameImg = New-TestImage 100 100 ([System.Drawing.Color]::Green)
$samePath = Save-TestImage $sameImg 'same.png'
$state.path = $samePath
$state.image = $sameImg
$pic.Image = $sameImg
$threw = $false
try { Set-DialogImage -state $state -pic $pic -newImg $sameImg -newPath $samePath } catch { $threw = $true }
Check '同一张图不抛异常' (-not $threw) '抛了'
Check '同一张图不会被删掉' (Test-Path $samePath) "被删了:$samePath"
Check '同一张图仍可用' ($sameImg.Width -eq 100) "Width=$($sameImg.Width)"

# ---- 场景 4:state.path 为空时换图也不炸(旧记录缺失) ----
$fresh = New-TestImage 80 60 ([System.Drawing.Color]::Blue)
$freshPath = Save-TestImage $fresh 'fresh.png'
$pic2 = New-Object System.Windows.Forms.PictureBox
$state2 = @{ path = $null; image = $null; seq = 0; refreshes = 0 }
$threw2 = $false
try { Set-DialogImage -state $state2 -pic $pic2 -newImg $fresh -newPath $freshPath } catch { $threw2 = $true }
Check '没有旧图时换图不抛异常' (-not $threw2) '抛了'
Check '没有旧图时新图挂上了' ([object]::ReferenceEquals($pic2.Image, $fresh)) '没挂上'
Check '没有旧图时新文件保留' (Test-Path $freshPath) "缺 $freshPath"

# ---- 场景 5:Save-ClipboardImageToTemp 落盘 + 撞名顺延 ----
$probe = New-TestImage 50 50 ([System.Drawing.Color]::Orange)
$p1 = Save-ClipboardImageToTemp $probe
Check '临时图落盘成功' (($null -ne $p1) -and (Test-Path $p1)) "拿到 $p1"
Check '临时图在 tempDir 下' ($p1.StartsWith($script:tempDir, [StringComparison]::OrdinalIgnoreCase)) "落在 $p1"
# 撞名:同一毫秒再存一次,不能覆盖上一张
$p2 = Save-ClipboardImageToTemp $probe
Check '连存两张不覆盖' (($p1 -ne $p2) -and (Test-Path $p1) -and (Test-Path $p2)) "p1=$p1 p2=$p2"

# ---- 场景 6:Read-ClipboardImage 在剪贴板没图时安静返回 $null ----
# 不判定"剪贴板里到底有没有图"(那取决于机器状态),只验它**不抛异常**。
$threw3 = $false
$got = $null
try { $got = Read-ClipboardImage } catch { $threw3 = $true }
Check '读剪贴板不抛异常' (-not $threw3) '抛了'
$gotType = if ($null -eq $got) { 'null' } else { $got.GetType().Name }
Check '读剪贴板返回值是 Image 或 $null' (($null -eq $got) -or ($got -is [System.Drawing.Image])) "拿到 $gotType"

# ---- 场景 7:真驱动一次刷新 Tick ----
# 前面测的是 Set-DialogImage 本身;这里测**定时器那一段**是否把它接对了:
# 序列号没变不换图、变成文字了不换图、真来新图才换,并且删掉旧文件。
$script:config = @{ pollIntervalMs = 200; dupWindowMs = 6000 }
$script:recentSignatures = @()

$tickOldImg = New-TestImage 320 240 ([System.Drawing.Color]::FromArgb(200, 200, 200))
$tickOldPath = Save-TestImage $tickOldImg 'tick-old.png'
$tickPic = New-Object System.Windows.Forms.PictureBox
$tickPic.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
$tickPic.Size = New-Object System.Drawing.Size(320, 240)
$tickPic.Image = $tickOldImg
$script:state = @{ path = $tickOldPath; image = $tickOldImg; seq = 100; refreshes = 0 }
$script:pic = $tickPic
$script:AutoCloseMs = 0

# (a) 序列号没变 → 什么都不该发生
$script:SeqOverride = { 100 }
$script:ClipboardImageOverride = $null
Invoke-RefreshTick
Check 'Tick:序列号没变不换图' ($script:state.refreshes -eq 0) "refreshes=$($script:state.refreshes)"
Check 'Tick:序列号没变旧文件还在' (Test-Path $tickOldPath) '被删了'

# (b) 序列号变了,但剪贴板里不是图 → 也不换,窗里那张留着
$script:SeqOverride = { 101 }
$script:ClipboardImageOverride = { $null }
Invoke-RefreshTick
Check 'Tick:剪贴板不是图时不换图' ($script:state.refreshes -eq 0) "refreshes=$($script:state.refreshes)"
Check 'Tick:剪贴板不是图时旧文件还在' (Test-Path $tickOldPath) '被删了'
Check 'Tick:剪贴板不是图时序列号已更新' ($script:state.seq -eq 101) "seq=$($script:state.seq)"

# (c) 真来了一张**不一样**的新图 → 换图,旧文件删掉
$tickNewImg = New-TestImage 800 600 ([System.Drawing.Color]::FromArgb(20, 90, 200))
$script:SeqOverride = { 102 }
$script:ClipboardImageOverride = { $tickNewImg }.GetNewClosure()
Invoke-RefreshTick
Check 'Tick:新图换上去了' ([object]::ReferenceEquals($script:pic.Image, $tickNewImg)) '没换'
Check 'Tick:换图次数 +1' ($script:state.refreshes -eq 1) "refreshes=$($script:state.refreshes)"
Check 'Tick:旧的临时图被删掉' (-not (Test-Path $tickOldPath)) "还在:$tickOldPath"
Check 'Tick:state.path 指向新文件' (($null -ne $script:state.path) -and (Test-Path $script:state.path)) "拿到 $($script:state.path)"
Check 'Tick:新文件在 tempDir 下' `
  ($script:state.path.StartsWith($script:tempDir, [StringComparison]::OrdinalIgnoreCase)) "落在 $($script:state.path)"

# (d) 同一张屏被推两次 → 去重,不刷新(否则用户会觉得窗在闪)
$refreshBefore = $script:state.refreshes
$pathBefore = $script:state.path
$dupImg = New-TestImage 800 600 ([System.Drawing.Color]::FromArgb(20, 90, 200))  # 和上一张几乎一样
$script:SeqOverride = { 103 }
$script:ClipboardImageOverride = { $dupImg }.GetNewClosure()
Invoke-RefreshTick
Check 'Tick:重复截图不刷新' ($script:state.refreshes -eq $refreshBefore) "refreshes 从 $refreshBefore 变成 $($script:state.refreshes)"
Check 'Tick:重复截图不换 path' ($script:state.path -eq $pathBefore) "path 变了"

# (e) 定时器里抛异常不能把消息泵带走
$script:SeqOverride = { 104 }
$script:ClipboardImageOverride = { throw 'boom' }.GetNewClosure()
$threw4 = $false
try { Invoke-RefreshTick } catch { $threw4 = $true }
Check 'Tick:内部异常不外泄(会带走消息泵)' (-not $threw4) '抛出来了'
$logText = ''
if (Test-Path $script:logPath) { $logText = [System.IO.File]::ReadAllText($script:logPath) }
$errLogged = $logText.Contains('"t":"err"')
Check 'Tick:内部异常被记进日志' $errLogged '日志里没有 err 事件'

# 还原接缝,免得影响后面的场景
$script:SeqOverride = $null
$script:ClipboardImageOverride = $null

# ---- 场景 8:源码层 —— 刷新定时器挂对了地方 ----
$body = Get-FnSource $src 'Show-CaptureDialog'
Check '窗里挂了刷新定时器' ($body.Contains('$refreshTimer')) '缺 $refreshTimer'
Check '刷新定时器用 WinForms Timer(必须在 UI 消息泵里)' `
  ($body.Contains('$refreshTimer = New-Object System.Windows.Forms.Timer')) '定时器类型不对'
Check '刷新定时器在窗体显示后启动' `
  ($body.Contains('$form.Add_Shown({ $refreshTimer.Start() }')) '没在 Add_Shown 里启动'
Check '窗关掉时停掉刷新定时器' `
  ($body.Contains('$refreshTimer.Stop()') -and $body.Contains('$refreshTimer.Dispose()')) '缺 Stop/Dispose'
Check '刷新时删掉上一张临时图' ($body.Contains('Set-DialogImage')) '没走 Set-DialogImage'
Check '刷新也走重复截图去重' `
  ($body.Contains('Test-DuplicateCapture $sig $now')) '没去重'
Check '返回值带最终那张图的 path' ($body.Contains('path = $state.path')) '缺 path'
Check '返回值带换图次数' ($body.Contains('refreshes = [int]$state.refreshes')) '缺 refreshes'

# ---- 场景 9:主循环用 Show-CaptureDialog 返回的 path 写 choice ----
# 换过图却拿最初那张去写库,存进去的图和用户看到的就是两张。
$loop = $src.Substring($src.IndexOf('while ($true)'))
Check '主循环按返回的 path 写 choice' ($loop.Contains('$choicePath')) '还在用最初那张'
Check '主循环把被替掉的临时图删掉' ($loop.Contains('Remove-Item -LiteralPath $pngPath')) '没清'
Check '主循环弹窗时把 seq 传进去' ($loop.Contains('-Seq $seq')) '没传 seq'

# ---- 场景 10:事件日志里能看见刷新 ----
Check '刷新会写 refresh 事件' ($body.Contains('t = "refresh"')) '缺 refresh 事件'

# 收拾
foreach ($p in @($oldPath, $newPath, $old2Path, $tinyPath, $samePath, $freshPath, $p1, $p2)) {
  if ($p -and (Test-Path $p)) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
}
try { $oldImg.Dispose() } catch { }
try { $newImg.Dispose() } catch { }
try { $old2.Dispose() } catch { }
try { $tiny.Dispose() } catch { }
try { $sameImg.Dispose() } catch { }
try { $fresh.Dispose() } catch { }
try { $probe.Dispose() } catch { }
$pic.Dispose(); $pic2.Dispose()
Remove-Item $script:tempDir -Recurse -Force -ErrorAction SilentlyContinue

if ($fail -eq 0) { '[dialog-refresh] 全部通过' } else { "[dialog-refresh] 失败 $fail 项"; exit 1 }
