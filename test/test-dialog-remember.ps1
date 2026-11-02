<#
  dsh-screenshot-capture · 悬浮窗「记住上次关闭位置」的回归测试

  验什么:
    1. positionMode="remember" 且**有**记录时,窗口回到记录的位置和大小。
    2. positionMode="remember" 但**没有**记录时,退回 cursor 行为(跟着指针)。
    3. 记录失效时也退回 cursor —— 那块屏拔了 / 分辨率变了 / 坐标在虚拟桌面外,
       都不能把窗弹到看不见的地方。
    4. 关窗时会把当前外框位置**写回**记录文件(按钮、Esc、X、自动关闭都算)。
    5. 记录文件写坏了(半截 JSON / 缺字段)不炸,退回 cursor。
    6. 记录比 MinimumSize 小时,按 MinimumSize 兜底。

  做法:抠出 Show-CaptureDialog 原文 + Get/Save-RememberedGeometry 在进程内跑,
  用 OpenForms 读窗体的 Bounds,然后 Close()。

  注意:$config 是**脚本级变量**,Show-CaptureDialog 读它;所以每个场景都要
  重新赋一次 $config.positionMode / statePath,再弹窗。

  用法: powershell -NoProfile -ExecutionPolicy Bypass -File test\test-dialog-remember.ps1
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

# Show-CaptureDialog 依赖这几个东西:三个几何函数 + 布局函数 + $tempDir + $config
$script:tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('dsc-remember-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:tempDir -Force | Out-Null
Invoke-Expression (Get-FnSource $src 'Get-PointerPosition')
Invoke-Expression (Get-FnSource $src 'Get-StatePath')
Invoke-Expression (Get-FnSource $src 'Get-RememberedGeometry')
Invoke-Expression (Get-FnSource $src 'Save-RememberedGeometry')
Invoke-Expression (Get-FnSource $src 'Get-DialogLayout')
Invoke-Expression (Get-FnSource $src 'Show-CaptureDialog')

$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail) {
  if ($ok) { "PASS $name" } else { "FAIL $name - $detail"; $script:fail++ }
}

# 指针钉在屏幕左上角 +4,+4,窗口摆在它右下;不碰真实鼠标
$script:PointerOverride = {
  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  return (New-Object System.Drawing.Point(($wa.Left + 4), ($wa.Top + 4)))
}.GetNewClosure()

$dlgTitle = [string]([char]0x622A + [char]0x56FE + [char]0x5165 + [char]0x5E93)  # 截图入库

# 造一张小图,尺寸稳定好算
$png = Join-Path $script:tempDir 'sample.png'
$bmp = New-Object System.Drawing.Bitmap 300, 200
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::FromArgb(238, 242, 250))
$g.Dispose()
$bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

$statePath = Join-Path $script:tempDir 'dialog-state.json'

# 弹一次窗,读它的外框矩形,然后关掉。$mutate 可以在关窗**之前**动一下窗
# (用来模拟"用户把它拖到别处")。
function Show-And-Snap([scriptblock]$mutate = $null, [int]$closeAfterMs = 700) {
  $script:snap = $null
  $clock = @{ done = $false; closed = $false }
  $t = New-Object System.Windows.Forms.Timer
  $t.Interval = $closeAfterMs
  $t.Add_Tick({
    if ($clock.done) { return }
    $clock.done = $true
    $t.Stop()
    $f = @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -eq $dlgTitle }) | Select-Object -First 1
    if ($f) {
      $script:snap = @{
        x = $f.Left; y = $f.Top; w = $f.Width; h = $f.Height
        cw = $f.ClientSize.Width; ch = $f.ClientSize.Height
      }
      if ($mutate) { & $mutate $f }
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
    $t.Start(); $watchdog.Start()
    $null = Show-CaptureDialog -ImagePath $png -AutoCloseMs 0
  } finally {
    $t.Dispose(); $watchdog.Dispose()
  }
  return $script:snap
}

function Set-Mode([string]$mode) {
  $script:config = @{
    offsetX = 60; offsetY = 60; previewMaxWidth = 320
    width = 0; height = 0; positionMode = $mode
    fixedX = 0; fixedY = 0; statePath = $statePath
  }
}

# ---- 场景 1:没有记录 + remember → 退回 cursor 行为 ----
if (Test-Path $statePath) { Remove-Item $statePath -Force }
Set-Mode 'remember'
$s1 = Show-And-Snap
if ($null -eq $s1) { 'FAIL 场景1 没抓到窗体'; exit 1 }
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
Check '无记录时 remember 退回 cursor(窗口在指针附近)' `
  (([Math]::Abs($s1.x - ($wa.Left + 4 + 60)) -le 40) -and ([Math]::Abs($s1.y - ($wa.Top + 4 + 60)) -le 40)) `
  "窗口 ($($s1.x),$($s1.y)) 期望≈($($wa.Left + 64),$($wa.Top + 64))"

# 场景 1 关窗时应该写出记录(第一次关窗就记)
Check '关窗后写出了记录文件' (Test-Path $statePath) "没有 $statePath"
$saved = $null
if (Test-Path $statePath) { $saved = Get-Content $statePath -Raw | ConvertFrom-Json }
Check '记录里有 x/y/width/height' `
  (($null -ne $saved) -and ($null -ne $saved.x) -and ($null -ne $saved.y) -and ($null -ne $saved.width) -and ($null -ne $saved.height)) `
  "记录内容: $($saved | ConvertTo-Json -Compress)"

# ---- 场景 2:手工写一条记录 + remember → 窗口回到那个位置和大小 ----
$want = @{ x = 400; y = 260; width = 520; height = 460 }
$want | ConvertTo-Json -Compress | Set-Content -Path $statePath -Encoding UTF8
Set-Mode 'remember'
$s2 = Show-And-Snap
if ($null -eq $s2) { 'FAIL 场景2 没抓到窗体'; exit 1 }
Check '有记录时窗口回到记录的 x' ($s2.x -eq $want.x) "期望 $($want.x) 实际 $($s2.x)"
Check '有记录时窗口回到记录的 y' ($s2.y -eq $want.y) "期望 $($want.y) 实际 $($s2.y)"
Check '有记录时窗口回到记录的宽' ($s2.w -eq $want.width) "期望 $($want.width) 实际 $($s2.w)"
Check '有记录时窗口回到记录的高' ($s2.h -eq $want.height) "期望 $($want.height) 实际 $($s2.h)"

# ---- 场景 3:关窗前把窗拖到别处 → 新位置被写回 ----
$moved = $null
Set-Mode 'remember'
$moved = Show-And-Snap -mutate {
  param($f)
  $f.Location = New-Object System.Drawing.Point(700, 500)
  $f.Size = New-Object System.Drawing.Size(600, 500)
}.GetNewClosure()
$saved2 = Get-Content $statePath -Raw | ConvertFrom-Json
Check '拖到别处后记录更新了 x' ($saved2.x -eq 700) "期望 700 实际 $($saved2.x)"
Check '拖到别处后记录更新了 y' ($saved2.y -eq 500) "期望 500 实际 $($saved2.y)"
Check '改大小后记录更新了宽' ($saved2.width -eq 600) "期望 600 实际 $($saved2.width)"
Check '改大小后记录更新了高' ($saved2.height -eq 500) "期望 500 实际 $($saved2.height)"

# ---- 场景 4:记录在虚拟桌面之外(拔了副屏)→ 退回 cursor,不弹到看不见 ----
@{ x = -30000; y = -30000; width = 520; height = 460 } | ConvertTo-Json -Compress | Set-Content -Path $statePath -Encoding UTF8
Set-Mode 'remember'
$s4 = Show-And-Snap
if ($null -eq $s4) { 'FAIL 场景4 没抓到窗体'; exit 1 }
$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
Check '记录在屏幕外时窗口仍落在虚拟桌面内' `
  (($s4.x -ge $vs.Left) -and ($s4.y -ge $vs.Top) -and (($s4.x + $s4.w) -le $vs.Right) -and (($s4.y + $s4.h) -le $vs.Bottom)) `
  "窗口 ($($s4.x),$($s4.y)) $($s4.w)x$($s4.h) vs 虚拟桌面 $($vs.Left),$($vs.Top) $($vs.Right)x$($vs.Bottom)"

# ---- 场景 5:记录文件是坏的(半截 JSON)→ 不炸,退回 cursor ----
'{"x": 100, "y":' | Set-Content -Path $statePath -Encoding UTF8 -NoNewline
Set-Mode 'remember'
$s5 = Show-And-Snap
Check '记录文件损坏时仍能弹窗' ($null -ne $s5) '窗没出来(可能抛异常了)'

# ---- 场景 6:记录比 MinimumSize 小 → 按 MinimumSize 兜底 ----
@{ x = 200; y = 200; width = 50; height = 50 } | ConvertTo-Json -Compress | Set-Content -Path $statePath -Encoding UTF8
Set-Mode 'remember'
$s6 = Show-And-Snap
if ($null -eq $s6) { 'FAIL 场景6 没抓到窗体'; exit 1 }
Check '记录过小时宽度按 MinimumSize 兜底' ($s6.w -ge 220) "实际 $($s6.w)"
Check '记录过小时高度按 MinimumSize 兜底' ($s6.h -ge 240) "实际 $($s6.h)"

# ---- 场景 7:remember 是**独立模式** —— cursor 模式不看记录 ----
# 0.4.6 曾把记住位置改成无条件默认行为,这几条断言被反过来写过。0.4.8 起恢复成
# 三种模式各管各的:cursor 只认鼠标,记录写得再离谱也不该把窗拽走。
@{ x = 400; y = 260; width = 520; height = 460 } | ConvertTo-Json -Compress | Set-Content -Path $statePath -Encoding UTF8
Set-Mode 'cursor'
$s7 = Show-And-Snap
if ($null -eq $s7) { 'FAIL 场景7 没抓到窗体'; exit 1 }
Check 'cursor 模式不受记录位置影响' `
  (-not (($s7.x -eq 400) -and ($s7.y -eq 260))) "窗口 ($($s7.x),$($s7.y)) 不该等于记录里的 (400,260)"
Check 'cursor 模式不受记录大小影响' `
  (-not (($s7.w -eq 520) -and ($s7.h -eq 460))) "尺寸 $($s7.w)x$($s7.h) 不该等于记录里的 520x460"

# ---- 场景 8:fixed 模式也**不**看记录 —— 用户在设置页填的坐标说了算 ----
@{ x = 400; y = 260; width = 520; height = 460 } | ConvertTo-Json -Compress | Set-Content -Path $statePath -Encoding UTF8
Set-Mode 'fixed'
$script:config.fixedX = 150
$script:config.fixedY = 150
$s8 = Show-And-Snap
if ($null -eq $s8) { 'FAIL 场景8 没抓到窗体'; exit 1 }
Check 'fixed 模式按 fixedX/fixedY 摆,不被记录覆盖' `
  (([Math]::Abs($s8.x - 150) -le 12) -and ([Math]::Abs($s8.y - 150) -le 12)) `
  "窗口 ($($s8.x),$($s8.y)) 期望≈(150,150)"

# ---- 场景 8b:没有记录时 remember 模式退回 cursor 行为 ----
if (Test-Path $statePath) { Remove-Item $statePath -Force }
Set-Mode 'remember'
$s8b = Show-And-Snap
if ($null -eq $s8b) { 'FAIL 场景8b 没抓到窗体'; exit 1 }
$vs8b = [System.Windows.Forms.SystemInformation]::VirtualScreen
Check '没有记录时 remember 退回 cursor,窗口仍落在虚拟桌面内' `
  (($s8b.x -ge $vs8b.Left) -and ($s8b.y -ge $vs8b.Top) -and (($s8b.x + $s8b.w) -le $vs8b.Right) -and (($s8b.y + $s8b.h) -le $vs8b.Bottom)) `
  "窗口 ($($s8b.x),$($s8b.y)) $($s8b.w)x$($s8b.h) 在虚拟桌面外"

# ---- 场景 8c:在 remember 模式下拉大窗口后关掉,下次按拉大后的尺寸打开 ----
if (Test-Path $statePath) { Remove-Item $statePath -Force }
Set-Mode 'remember'
$s8c = Show-And-Snap -Mutate {
  param($f)
  $f.Size = New-Object System.Drawing.Size(760, 640)
}
if ($null -eq $s8c) { 'FAIL 场景8c 没抓到窗体'; exit 1 }
$rec = $null
if (Test-Path $statePath) { $rec = Get-Content $statePath -Raw | ConvertFrom-Json }
Check '拉大后关窗记下了新尺寸' `
  (($null -ne $rec) -and ($rec.width -eq 760) -and ($rec.height -eq 640)) `
  "记录: $($rec | ConvertTo-Json -Compress)"
$s8d = Show-And-Snap
if ($null -eq $s8d) { 'FAIL 场景8d 没抓到窗体'; exit 1 }
Check '下次按拉大后的尺寸打开' `
  (($s8d.w -eq 760) -and ($s8d.h -eq 640)) "尺寸 $($s8d.w)x$($s8d.h) 期望 760x640"

# ---- 场景 9:源码层 ----
# 记录**只在 remember 模式下**读 —— 0.4.6 曾无条件优先,那是设计错误:
# 用户在设置页填的 fixedX/fixedY、宽度、高度全被旧记录压住,改了没反应。
Check '记录只在 remember 模式下读取' `
  ($src.Contains('if ([string]$config.positionMode -eq "remember") {')) '缺 remember 模式的读记录分支'
Check '三种模式各管各的' `
  ($src.Contains('$remembered = $null')) '缺 $remembered 默认置空'
Check '关窗时挂 FormClosing 记录位置' ($src.Contains('Add_FormClosing')) '缺 Add_FormClosing'
Check '关窗记录用 GetNewClosure 捕获作用域' ($src.Contains('}.GetNewClosure())')) '缺 GetNewClosure'
Check '状态文件默认落在 statePath' ($src.Contains('dialog-state.json')) '缺默认 statePath'

# ---- 场景 10:$tempDir 为空时也不能退化成相对路径 ----
# 曾经写成 `$statePath = if ($config.statePath) {...} else { Join-Path $tempDir "dialog-state.json" }`,
# $tempDir 没赋值时 Join-Path 会拼出裸的 "dialog-state.json" —— 相对路径,
# 落到当前工作目录里。真机上 cwd 是用户随便哪个文件夹,文件就丢了。
$savedTempDir = $script:tempDir
$savedConfig = $script:config
try {
  $script:tempDir = $null
  $script:config = @{ statePath = "" }
  $fallback = Get-StatePath
  Check 'tempDir 为空时回落到绝对路径' ([System.IO.Path]::IsPathRooted($fallback)) "拿到相对路径 $fallback"
  Check 'tempDir 为空时回落到系统临时目录' ($fallback.StartsWith([System.IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) "落在 $fallback"

  # 显式配了 statePath 时要原样用
  $script:config = @{ statePath = 'C:\custom\where\my-state.json' }
  Check '显式 statePath 原样使用' ((Get-StatePath) -eq 'C:\custom\where\my-state.json') "拿到 $(Get-StatePath)"
} finally {
  $script:tempDir = $savedTempDir
  $script:config = $savedConfig
}

# 收拾
$script:PointerOverride = $null
Remove-Item $script:tempDir -Recurse -Force -ErrorAction SilentlyContinue

if ($fail -eq 0) { '[dialog-remember] 全部通过' } else { "[dialog-remember] 失败 $fail 项"; exit 1 }
