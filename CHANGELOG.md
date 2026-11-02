# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.4.8] - 2026-11-02

### Fixed — 「记住上次位置」恢复为独立模式 / Remember is a mode again

**用户反馈**:「是要单出一个记忆上一次窗口位置的模式。」

**背景**:0.4.6 我把「记住上次关闭时的位置和大小」改成了**无条件默认行为**,
理由是「用户拖过就该按他摆的来,不该要他先认识一个模式」。这个判断是错的 ——
它连带把另外两个模式废掉了:

- 选「固定坐标」并把窗口拉到别处关掉,下次还是开在拉到的位置,
  `fixedX/fixedY` 等于摆设;
- 「宽度 / 高度」两个设置同样被旧记录压住,填了没反应。

也就是说,为了让一个功能"总是生效",把另外两个功能的用户意图**吞掉**了。
用户要的是「这是一个可以选的模式」,不是「这必须一直是开着的」。

**改动**:

1. **`positionMode` 恢复三种取值,各管各的**(`scripts/clip-dialog.ps1`):
   - `cursor` —— 跟着鼠标(默认)
   - `fixed` —— 出现在 `fixedX/fixedY`,与鼠标无关
   - `remember` —— 沿用上次关闭时的位置和大小
   只有 `remember` 会调 `Get-RememberedGeometry()`,另外两个模式连读都不读。
2. **记录仍然无条件写入**,只是只有 `remember` 读它。这样临时切去别的模式
   看看效果、再切回来,上次摆的位置还在 —— 不用为了"保住记忆"而不敢切换。
3. **`remember` 没有记录时退回 `cursor`**,不是退回"左上角"或"不动"。
   宁可弹在鼠标旁,也不弹在不知道哪儿的角落。
4. **删掉 0.4.6 加的「一改几何设置就删位置记录」逻辑**(`index.mjs`)。
   那是为「记录无条件优先」打的补丁 —— 既然 `fixed`/`cursor` 不再读记录,
   两者就不冲突了,再删记录反而会误伤:用户在 `cursor` 模式下改个偏移量,
   不该把他 `remember` 模式记下的位置弄丢。
5. **设置页恢复三项,并按模式显示对应字段**(`client.js`):
   `remember` 模式下隐藏「宽度 / 高度」和「固定 X / Y」「偏移量」,换成一句
   说明;`cursor` 显示偏移量;`fixed` 显示坐标。

**几个不那么显然的决定**:

- **字段按模式显示,不是全部堆在一起**:宽度/高度对 `remember` 模式毫无作用
  (尺寸由记录决定),摆在那里只会让人以为"填了不生效"。
- **`geometryKeyOf` 保留但不再用于删记录**:它成了「哪些字段算窗口几何」的
  单一出处,测试里还在用。留着比删掉好 —— 免得以后又有人手抄一份字段清单。
- **没有把记录文件挪进 `remember` 专属子目录**:记录是跨模式共享的状态,
  按模式分文件会让"切模式不丢记忆"这件事变得不可靠。

**测试**:
- `test-dialog-remember.ps1` 21 → **29 项**:场景 7/8 断言改回「cursor / fixed
  不受记录影响」(0.4.6 里被反写成"也沿用记录"),新增场景 8b「没有记录时
  `remember` 退回 cursor」,8c「`remember` 模式下拉大窗口也被记住」。
- `test-settings-reload.mjs` 新增「`remember` 必须原样保留,不能被 merge
  折叠成 cursor」一条。
- 全量:8 套 ps1 共 **263 项**全 PASS,`npm test` 5 个 JS 套件全通过。

## [0.4.7] - 2026-11-01

### Changed — 弹窗布局:图片真正铺满,不再缩在灰边中间 / Preview fills its box

**用户反馈**:「优化弹窗内的内容布局。使图片能完全展开」

**问题**:预览框的高度取的是"窗口剩余空间",和图片自己的宽高比没关系。
`PictureBox` 用 `Zoom` 模式 —— 框比图胖就在上下留灰边,框比图瘦就在左右留灰边。
所以一张 16:9 的截图放进接近方形的窗口里,实际显示区域只有框的中间一条,
上下各留一条灰带;窗口被拉得越高、留白越多。用户看到的就是"图片缩在一大片
空白中间,没有完全展开"。

实测(1920×1080 的截图,窗口被拖到 351×438):预览框 319×243,图片按比例只
占 319×179 —— **上下各浪费 32px**,合计 64px 的灰边。

**改动**:

1. **新增 `Get-DialogLayout` 纯函数**(`scripts/clip-dialog.ps1`) —— 给定客户区
   大小和图片原始尺寸,算出预览框、注释框、勾选框、按钮行各自的位置和尺寸。
   **预览框宽高比一律等于图片宽高比**,多出来的纵向空间全部给注释框(窗里唯一
   适合纵向拉伸的控件)。抽成纯函数还有个好处:能脱离真实弹窗直接断言,
   不用等窗口真的弹出来。
2. **初始布局和拖动改大小共用同一套算法** —— 老代码里这两处各算一套,容易
   走样;现在 `$relayout` 直接调 `Get-DialogLayout`。
3. **拖动改大小时用「当前窗里那张图」的比例** —— 窗开着时可能换过图(0.4.5 的
   换图功能),新图比例未必和老图一样,用构造时的尺寸算会让新图重新出现灰边。
4. **自适应宽度时不再放大小图** —— 老代码有 `Max(160, ...)` / `Max(100, ...)`
   的兜底,100×100 的图标会被拉到 160×100 显示,变糊。现在窗宽跟着图片收窄
   (仍不低于按钮行宽度)。
5. **高度不够时优先保住注释框** —— 图按剩余空间缩、宽度跟着比例收窄并水平居中,
   而不是硬撑一个和图片比例不符的框。

**几个不那么显然的决定**:

- **不做"图片铺满窗口"**:那需要拉伸变形或裁切,两者都比灰边更糟。真正的
  诉求是"图片占据它该占的那块、周围别浪费",所以做法是把框贴合图片比例,
  富余空间给别的控件 —— 视觉上图片就是"完全展开"了。
- **`MinPicH`(40px)只用于"纵向被挤压"分支**:宽度受限时高度由比例决定。
  15:1 的宽条铺满 320 宽就只有 21 高,这是比例正确的**结果**,硬抬到 40 会
  破坏比例、重新制造灰边。测试里为此专门写了一条断言钉住。
- **注释框上限不再是"窗口高度 - 16 - 40"**:老算法把预览图的下限写死成 40,
  现在预览图按比例算,注释框就是"剩余空间",不再需要单独夹上限。
- **`$state` 必须建在 `$relayout` 之前**:`GetNewClosure()` 只捕获创建闭包
  **那一刻**已存在的变量,晚于它定义的变量在闭包里永远是 `$null`。

**测试**:
- 新增 `test/test-dialog-layout-calc.ps1`(**107 项**) —— 纯函数级单元测试。
  覆盖 16:9 / 竖图 / 超宽 15:1 / 超窄 20:1 / 最小窗口 / 大窗口 / 图片尺寸为 0,
  每个场景都断言:预览框比例贴合图片、所有控件在窗内、纵向顺序正确不重叠、
  按钮行放得下。另有源码层检查 `Zoom` 模式且没有 `StretchImage`。
- `test-dialog-layout.ps1` 与 `test-dialog-resize.ps1` 里两条断言钉的是旧实现
  (内联算式、"拖大后注释框高度不变"),改为钉新语义(布局走纯函数、
  富余高度给注释框)。
- 6 个 ps1 测试原先只抠 `Show-CaptureDialog` 原文,新代码调 `Get-DialogLayout`
  会 `CommandNotFoundException` —— 全部补上加载该函数。
- 全量:8 套 ps1 共 **262 项全 PASS**,`npm test` 5 个 JS 套件全通过。

## [0.4.6] - 2026-11-01

### Fixed — 拖动过的位置、拉过的大小现在真的会被记住 / Geometry is remembered by default

**用户反馈**:「移动窗口关闭后,并没有记住上回关闭的位置,未从关闭的位置打开。
还有调整窗口大小,也要记住它的调整后的大小,重新打开时要按上次调整的大小打开。」

**根因**:记住位置的代码一直在跑 —— `Add_FormClosing` 无条件写记录,所以
`dialog-state.json` 里确实躺着 `{"x":360,"y":122,"width":1127,"height":1150}`。
**但读记录那一步被 `positionMode` 挡着**:

```powershell
$useRemember = ([string]$config.positionMode -eq "remember") -and ($null -ne $remembered)
```

0.4.4 把「记住上次位置」做成了一个**独立的模式**,只有显式选它才会读记录。
而用户的配置是 `dialogPositionMode: fixed` —— 于是记录写了没人读,下次照样
弹回 `fixedX/fixedY` 和配置里的固定尺寸。尺寸问题也是同一个根因:拉大后记下了,
但读不到,所以仍按 `dialogWidth/dialogHeight` 开。

这本身是设计错误:**「记住上次位置」本来就该是默认行为**,不该要用户先认识
一个叫「记住上次位置」的模式才生效。

**改动**:

1. **`scripts/clip-dialog.ps1`** —— 记录无条件优先生效:
   ```powershell
   $remembered = Get-RememberedGeometry
   if ($null -ne $remembered) { ...按记录的位置和大小... }
   elseif ([string]$config.positionMode -eq "fixed") { ... }
   else { ...cursor... }
   ```
   `positionMode` 现在只决定**没有记录时第一次**出现在哪儿。`remember` 值仍然
   接受(等同 `cursor`),只为兼容老配置。
2. **`index.mjs`** —— 用户主动改了「宽度 / 高度 / 固定 X / 固定 Y / 出现位置」
   时,把 `dialog-state.json` 删掉。否则新设置永远被旧记录压住,变成更难理解的
   「改了没反应」。判据是新导出的 `geometryKeyOf(cfg)`,只挑这五个字段 ——
   改轮询间隔、OCR 模型之类不该动记录。
   **只在 `settings/document-updated` 路径上做**,首次加载只对齐基线:插件每次
   重载都会走一遍首次加载,那时拿构造时的值去比一定"不相等",一比较就把记录
   删了,等于每次重启都忘掉位置 —— 正是这个功能最不该有的表现。
3. **`clipboard.mjs`** —— 把状态文件路径导出成 `DIALOG_STATE_PATH`,给 `index.mjs`
   清除时用(原来是在 `writeWatcherConfig` 里内联拼的)。
4. **`client.js`** —— 「出现位置」去掉 `记住上次位置` 这个选项(它已经没意义了),
   提示文案改成说明"之后你拖到哪儿、拉成多大,下次就按那个样子打开;改这里的
   数字会覆盖那个记忆"。宽度/高度的提示同步补一句。

**测试**:
- `test-dialog-remember.ps1` 从 21 项扩到 28 项。原来场景 7/8 断言的是
  「cursor / fixed 模式**不受**记录影响」—— 那正是被修掉的错误行为,现在反过来
  断言「cursor / fixed 也照样沿用记录」。新增场景 8c/8d:把窗口拉到 760×640
  再关掉,断言记录里是新尺寸、下次就按 760×640 打开(用户明确要求的那条)。
- `test-dialog-fixed.ps1` 加一步:每次探测前清掉状态文件。记录无条件生效之后,
  同一个测试进程里上一次弹窗关掉时写下的记录会压过这一轮要验证的 fixedX/Y,
  断言就变成"上一轮的结果"了。
- `test-settings-reload.mjs` 加 11 组断言钉住 `geometryKeyOf` 的判据:五个几何
  字段任一变化都要认出来,六个与几何无关的字段变了都不该删记录,且同一份配置
  算两次必须相同(否则每次重载都误删)。

## [0.4.5] - 2026-11-01

### Changed — 窗口开着时又截图,原地换图 / Refresh the preview instead of stacking dialogs

**需求**:在窗口弹出期间又截了一张图,希望窗里换成新图,**原来那张不要了**。

**根因**:`Show-CaptureDialog` 用的是 `ShowDialog()` —— 这是**模态**调用,它跑
自己的消息泵,主循环那圈 `while` 在它返回之前一步都不走。所以窗口开着的时候
剪贴板其实没人看:用户连截两张,第二张要么被 `cooldownMs` 吞掉,要么一直等到
窗关掉之后才处理,表现成"截了没反应,过一会儿才弹出第二个窗"。

**改动**:

1. **`scripts/clip-dialog.ps1`** — 在模态消息泵内部挂一个
   `System.Windows.Forms.Timer`,按 `pollIntervalMs` 轮询剪贴板序列号。序列号变了
   且新内容确实是图,就地把预览换成新图。
   - 新增 `Read-ClipboardImage` / `Save-ClipboardImageToTemp` / `Set-DialogImage`
     三个函数(主循环和刷新定时器共用,免得两份实现走偏)。
   - `Show-CaptureDialog` 多收一个 `-Seq`,返回 `path`(最终显示的那张)和
     `refreshes`(换过几次)。
   - 主循环按返回的 `path` 写 `choice` 事件,并把被替掉的临时图删掉。
   - 新增事件 `{"t":"refresh","path":"...","seq":123}`。

**几个不那么显然的决定**:

- **为什么不改成 `Show()` + `Application.Run`**:那样确实能在主循环里统一处理
  剪贴板,但要连带改掉"窗关掉之后才拿到返回值"的整套控制流 —— `ShowDialog`
  返回时 `$form.Tag` 就是用户的按钮选择,改成 `Show` 之后这套要重写,风险比
  加一个定时器大得多。而且用户拖窗、改注释时主循环插进来处理截图,更容易出
  竞态。
- **换图不动窗口大小**。窗可能已经被拖过、或者按 `remember` 还原过,按新图
  尺寸去改会把用户刚摆好的位置和大小冲掉。`PictureBox` 是 `Zoom` 模式,比例
  不同就居中留白,不会变形。
- **旧图要 `Dispose`,但同一张不能 Dispose 两次**。换图时漏掉旧图的
  `Dispose` 会每换一张漏一份 GDI+ 句柄;而用 `ReferenceEquals` 兜一下是因为
  极端情况下新旧可能就是同一个对象,那时候释放了就等于把窗里那张弄死。
- **去重仍然生效**。Windows 截图工具会在几秒内把同一张屏推两次(实测 1px
  之差、间隔 3s),那种情况不该刷新 —— 否则用户会觉得窗在闪。
- **换图重置自动关闭倒计时**。刚截了新图正要细看,这时候倒计时到点把窗关掉
  是在跟人抢手。
- **刷新定时器里的一切都包在 try/catch 里**。定时器回调抛异常会把整个消息泵
  带走 —— 窗还在,但所有按钮和倒计时全死了。
- **`cooldownMs` 在窗内不生效**。那个是主循环用来防抖的(两次弹窗之间至少隔
  多久);窗里刷新是用户明确的新动作,不该被它挡住。

**测试**:新增 `test/test-dialog-refresh.ps1`(45 项断言),10 个场景:换图后
预览与状态都指向新图 / 旧的临时文件被删 / 换图不改预览框尺寸 / 新旧同一张时
不 Dispose 也不删文件 / `state.path` 为空时换图不炸 / 临时图落盘与撞名顺延 /
读剪贴板不抛异常 / **把定时器的 Tick 处理器原文抠出来直接驱动**(序列号没变
不换图、剪贴板变成文字时保留原图、真来新图才换、同色重复图被去重、Tick 内部
抛异常不外泄且记进日志) / 源码层检查定时器的类型与挂载位置 / 主循环按返回的
`path` 写 `choice`。

**为什么这个测试不碰真剪贴板**:这台机器上 Chrome 长期占着剪贴板
(`OpenClipboard` 连续 8 次失败),靠真剪贴板弹窗的端到端测试一律 SKIP。所以
`Set-DialogImage` 被设计成只依赖传入的控件和 `$tempDir` 的纯函数,而剪贴板的
两个读取点(`Get-ClipboardSequenceNumber` / `ContainsImage`+`GetImage`)各留了
一个 `$script:*Override` 接缝 —— 测试用脚本块模拟"用户又截了一张图",既覆盖
真正容易错的部分(句柄释放、删旧文件、不动尺寸、去重、异常隔离),又不依赖
任何全局资源。

## [0.4.4] - 2026-11-01

### Added — 记住上次关闭时的位置和大小 / Remember where the window was left

**需求**:窗口每次都弹在同一个地方,而人多半会把它挪到顺手的位置(副屏、
角落、拖大一点)。每次重开都要重新挪,很烦。

**改动**:`出现位置` 多了第三种 `记住上次位置`(原来的 `跟随鼠标` / `固定坐标`
保持不变)。

1. **`scripts/clip-dialog.ps1`**
   - 新增 `Get-RememberedGeometry` / `Save-RememberedGeometry`,状态存成一个
     独立小 JSON(`dialog-state.json`)。
   - 位置分支从两路扩成三路:`remember` → `fixed` → `cursor`(逐级回落)。
   - 挂 `$form.Add_FormClosing(...)` 记录外框 `Left/Top/Width/Height`。
   - `$config` 新增 `statePath` 键。
2. **`clipboard.mjs`** — `writeWatcherConfig()` 多传一个 `statePath`,
   指向 `~/.dsh/dsh-screenshot-capture/dialog-state.json`。
3. **`index.mjs`** — `dialogPositionMode` 的 union 加 `z.const("remember")`。
4. **`client.js`** — 分段按钮加第三项,中英文文案各加一条。

**几个不那么显然的决定**:

- **不写回 `watcher-config.json`**。那份是插件每次重启都**整份重写**的配置
  投影,往里写运行时状态,下次启动就被冲掉了。所以另开一个文件。
- **存的是外框矩形,不是 ClientSize**。还原时也用 `$form.Size`。两边混着用
  会让窗口每开一次就胖一圈边框。
- **状态文件不能放 `tmpdir()`**。Windows 上每个进程/每个 shell 都可能拿到
  不同的临时目录(单实例锁就栽过这个坑,见 0.4.1),而且系统清临时目录时会
  连位置一起清掉。所以放 `homedir()` 下。
- **读回来的值必须重新校验**。显示器拔了、分辨率变了、窗口被拖到不存在的
  坐标上,都不能让窗弹到看不见的地方。判据是「整个窗口落在虚拟桌面内」——
  只判一个角不够:宽 800 的窗钉在屏幕最右边只露 10px,用户同样够不着标题栏。
  校验不过就退回 `cursor` 行为,不会什么都不弹。
- **写文件用「临时文件 + Move」**。半截 JSON 会让下次启动读不到位置,而
  `Move-Item` 在同一卷上是原子的。
- **`Add_FormClosing` 的处理器必须 `.GetNewClosure()`**。它在 `ShowDialog`
  的消息泵里执行,那时函数的局部作用域已经不在栈上,不捕获就全是 `$null`。
- 最小化/最大化时不记 —— 那时候的 `Bounds` 不是用户想要的位置。
- **路径每次现算,不缓存成脚本级变量**(`Get-StatePath`)。一开始写的是
  `$statePath = if ($config.statePath) {...} else { Join-Path $tempDir "dialog-state.json" }`
  放在脚本顶层。两个问题:一是测试把几何函数单独抠出来跑时那个变量还没赋值;
  二是 `$tempDir` 为空时 `Join-Path` 会拼出**裸的** `dialog-state.json` ——
  相对路径,落到当前工作目录里。真机上 cwd 是用户随便哪个文件夹,位置就丢了
  (自测时确实在当前目录里生成了一个 43 字节的 `.tmp` 文件,才暴露出来)。
  现在兜底值永远是绝对路径,`$tempDir` 为空就用 `Path::GetTempPath()`。

**测试**:新增 `test/test-dialog-remember.ps1`(24 项断言),10 个场景:
无记录退回 cursor / 有记录精确还原四个值 / 关窗前的移动和改大小被写回 /
记录在虚拟桌面外时仍落在屏内 / 记录文件是半截 JSON 也不炸 / 记录比
`MinimumSize` 小时按 `MinimumSize` 兜底 / `cursor` 与 `fixed` 模式都不受记录
影响 / 源码层检查 / `$tempDir` 为空时兜底路径仍是绝对路径 / 显式 `statePath`
原样使用。

**顺带修了老测试**:`Get-FnSource` 原来用 `"function $name {"` 精确匹配,
而带参数的声明是 `function Save-RememberedGeometry([int]$x, ...)` —— 名字后面
紧跟括号,匹配不到。改成只匹配前缀再校验后继字符。5 个老脚本同步更新,
并补上两个几何函数的加载(否则一弹窗就是 `CommandNotFoundException`)。

## [0.4.3] - 2026-11-01

### Added — 悬浮窗可以拖动边框改大小 / Resizable capture dialog

**需求**:窗口尺寸原先只能在设置页里填 `宽度`/`高度` 两个数字,想临时放大看清
截图细节得去改配置、保存、等 watcher 重启。要能在窗口上直接拖。

**改动**(全部在 `scripts/clip-dialog.ps1`):

1. `FormBorderStyle` 从 `FixedToolWindow` 改为 **`SizableToolWindow`** —— 保留
   工具窗外观(无任务栏图标、窄标题栏),但四边可拖。
2. 加 `MinimumSize = (220, 240)` —— 别让人把窗拖成一条缝,否则里面的按钮
   再也点不到。高度按布局算:预览图以外固定开销 156px + 预览至少 40px。
3. 新增 `$relayout` 脚本块挂在 `$form.Add_Resize(...)` 上:拖动时**只有预览图
   跟着伸缩**(PictureBox 是 Zoom 模式,等比缩放不糊,拉大正是为了看清细节),
   注释框宽度跟随预览、高度保持;勾选框与按钮行只跟着纵向平移。

**注意一处容易写错的地方**:注释框高度取的是**当前值** `$noteBox.Height`
而不是构造时的 `$noteH`。配置里填了 `dialogHeight` 时初始布局会把多出来的
高度给注释框(它是窗里唯一适合纵向拉伸的控件),若 resize 里写死 `$noteH`,
用户一拖窗注释框就"缩回去",看着像闪了一下。同时给它上限 `$noteMax`,窗被
拖矮时必须让注释框跟着缩,否则会顶出窗外。

**测试**:新增 `test/test-dialog-resize.ps1`(30 项断言)—— 进程内抠出
`Show-CaptureDialog` 跑起来,读初始快照 → 拖大(+260×+180)读第二份 →
拖到最小读第三份,分别断言边框样式、最小尺寸、预览图确实变大、注释框/勾选框
尺寸不变、所有控件在窗内、纵向堆叠不重叠、按钮行完整落在窗内。

其中一条是**句柄级**的:光有 `FormBorderStyle = SizableToolWindow` 这个托管
属性不算数,得看窗口句柄上真的有 `WS_THICKFRAME`(0x00040000) —— 属性对了而
样式位没对,界面上就是"看着像能拖,一拖纹丝不动"。用 `$f.Handle` 读
`GetWindowLong(GWL_STYLE)`,不经过剪贴板。

另附 `test/test-live-resize.ps1`(真实链路:spawn 助手 → 剪贴板塞图 → 弹窗 →
`SetWindowPos` 改大小 → `GetWindowRect` 复测),但它依赖剪贴板可用;
Chrome 等程序常年独占剪贴板时只会打 SKIP,不算失败。

**踩坑 1**:`MinimumSize` 约束的是 `Size`,不是 `ClientSize` —— 测试里用
`$f.ClientSize = 80,80` 模拟"拖到最小"会**原样接受**(断言直接失败),必须设
`$f.Size`。真实拖动时是系统按 `MinimumSize` 挡边框,所以设 `Size` 才等价。

**踩坑 2**:改 `scripts/clip-dialog.ps1` 时**必须保留 UTF-8 BOM**。这个文件
带 BOM,PowerShell 才按 UTF-8 读;BOM 一丢就回落到系统 ANSI(GBK),中文注释
全变乱码、`ParseFile` 直接报「表达式或语句中包含意外的标记」。编辑后务必用
`[System.Management.Automation.Language.Parser]::ParseFile(...)` 复核一遍。

## [0.4.2] - 2026-11-01

### Fixed — 设置页「出现位置」选了固定坐标却不生效 / Position mode never persisted

用户报告「固定位置不生效」。排查过程与结论:

**现象**:设置页把「出现位置」选成「固定坐标」后,界面一直显示固定坐标(重开
设置页也还是),但窗口照旧跟着鼠标跑;而同一页里的 `固定 X/Y`、`宽度/高度`
四个数字框却能正常存下来。

**根因**:`scope.set(field, value)` 返回的是**布尔值** —— Host 拒绝时返回
`false`,只有传输层出错才 reject。`client.js` 的 `save()` 只写了

```js
Promise.resolve(scope.set(field, v))
  .then(() => flash(t("saved")))   // ← 不管成败都报「已保存」
  .catch((err) => flash(`${t("error")} ...`));
```

于是写入被拒时界面照样提示「已保存」,用户以为存上了,配置其实一个字没变。
UI 之所以还显示「固定坐标」,是因为下拉框的受控值来自 React state,而不是
从 Host 回读。

**Host 为什么会拒绝**:`settings.write` 会拿客户端传来的 `expectedRevision`
和当前 revision 比对,不一致就抛 `SETTINGS_CONFLICT`。revision 的种子里含
`fiber.uid`,**插件每重载一次 revision 就 +1**,客户端镜像随即过期。

**修法**(`client.js`):

1. `save()` 检查返回值:拿到 `false` 或 catch 到错误,一律显示红色的
   「保存失败」,不再把失败当成功。
2. 被拒时**自动重试一次** —— 控制器在拒绝后自己会 `mirror.load()` 把
   revision 拉新,紧接着再写就能成功。不重试的话用户得手动再点一遍。
3. 状态行支持错误样式(`.scc-status-bad`),成功/失败一眼可辨。
4. 「出现位置」与「识别通道」两个下拉框换成**分段按钮**(`Segmented`):
   每个按钮各自带 `onClick`,事件源和目标都是它自己,不经过 `<select>` 的
   合成事件层。

### Changed

- 状态提示的显示时长 2.5s → 4s(失败信息需要更多时间读)。

### Fixed — 保存成功了但插件不知道(设置热更新从来没生效) / Settings never hot-reloaded

接上面那条:把保存链路修好之后,`cordis.patch.yml` 里确实出现了
`dialogPositionMode: fixed`(文件 mtime 也对得上),但窗口还是跟着鼠标跑。
查下去发现 **`index.mjs` 从来没有订阅过设置变更**:

```js
ctx.inject(["settings"], (settingsCtx) => {
  const row = settings.describe().find((r) => r.ns === SETTINGS_NS);
  ...
  scheduleRestart();   // ← 只在插件加载时跑这一次
});
```

`settings` 服务确实有变更事件,签名是

```ts
'settings/document-updated'(ns: SettingsNamespace, revision: number): void
```

但插件没监听,于是用户在设置页改完,宿主把值写进了 profile patch,
**运行中的插件毫不知情**,`liveConfig` 停在旧值,`watcherKey` 也一直相等,
`scheduleRestart` 每次都提前 return —— 助手进程按旧配置跑到底。
用户看到的正是「改了设置没反应 / 固定位置不生效」。

**修法**(`index.mjs`):

1. 把读设置那段抽成 `pullSettings(settings, { dropSchemaDefaults })`。
2. 在 `ctx.inject(["settings"], ...)` 里 `settingsCtx.on("settings/document-updated", (ns) => ...)`,
   只处理 `ns === SETTINGS_NS` 的变更(`ctx.on` 返回的 disposer 绑在当前 fiber 上,
   fiber 卸载时自动摘除)。
3. **变更更新时不再套 `dropDefaults`**:该函数会滤掉「等于 schema 默认值」的字段,
   而 `cursor` 恰好就是 `dialogPositionMode` 的默认值 —— 用户从 `fixed` 改回
   `cursor` 时那次改动会被当成「没改」丢掉,`liveConfig` 永远停在 `fixed`。
   首次加载仍保留 `dropDefaults`(防老版本宿主把默认值灌进来冲掉 config.json),
   后续变更全量应用。

## [0.4.1] - 2026-11-01

### Fixed — 一次复制弹出两个窗口 / Two dialogs for one copy

用户报告「为什么一次会弹出两个窗口」。排查结果:不是同一个 watcher 重复触发,
而是**两个 DSH 实例在同时跑**(`--profile desktop` 与 `--profile fixture-mirror`),
两个 profile 都把本插件装成了指向同一份源码的 link,于是各自拉起一个
`clip-dialog.ps1`。它们共用同一个 `%TEMP%\dsh-capture` 目录和同一个系统剪贴板,
所以复制一次图,两边同时检测到,各自弹出一个内容完全相同的窗口。

`clipboard.mjs` 新增单实例锁(`~/.dsh/dsh-screenshot-capture/watcher.lock`,
内容是本进程 PID):

- 用 `openSync(path, "wx")` 抢锁 —— 该标志在文件已存在时失败,是原子的,
  不依赖「先查再写」这种有竞态的做法。
- 抢不到时读锁里的 PID 并 `process.kill(pid, 0)` 探活:**持有者活着就让位**,
  不 spawn 助手,只 `emit("busy")` 打一条告警;持有者已死(被强杀会留下锁文件)
  则接管。
- `EPERM` 视为活着 —— Windows 上对存在但无权限的进程探活会抛它,那是活的。
- `stop()` / `stopAsync()` / 助手退出时释放锁,且**只删自己那把**
  (删之前比对 PID),避免把刚接管的实例的锁删掉。

**锁为什么放在 `~/.dsh/` 而不是 `%TEMP%`**:这是踩出来的。第一版锁放在
`tmpdir()` 下,实测发现从 shell 里启动的 DSH 会继承那个 shell 的私有 TEMP
(`...\Temp\dsh-win-bash-<pid>-<rand>`),两个实例算出的 `tmpdir()` 根本不是
同一个目录,于是各锁各的,锁形同虚设 —— 跨实例验证时直接失败。`homedir()`
(`USERPROFILE`)对所有实例都相同,才是能共享的位置。

`index.mjs` 配合两件事:

- 收到 `busy` 时置 `busyLocked`,**不走重试退避** —— 抢锁失败不是故障,
  退避重试只会让两个实例反复互抢。
- 每 15s 探一次:对方退出后本实例自动接管,不需要用户重启 DSH。

新增 `test/test-single-instance.mjs`(11 个断言,已并入 `npm test`),锁住
「第一个拿到 / 第二个让位 / 不覆盖对方 PID / 僵尸锁接管 / 损坏锁接管 /
stop 后释放」这几条容易写错的路径。

## [0.4.0] - 2026-11-01

### Added — 悬浮窗可以钉在固定位置 / Pin the floating window to a fixed position

新配置 `dialog.positionMode`，两档：

- `cursor`（默认，保持历史行为）—— 在光标旁弹出，按 `offsetX` / `offsetY` 偏移；
  右下放不下就翻到左上。
- `fixed` —— 每次都出现在 `dialog.fixedX` / `dialog.fixedY` 这个**屏幕坐标**上，
  与鼠标位置无关。多显示器下用的是虚拟桌面坐标系（副屏摆在主屏左边时 x 是负数），
  所以定位基于 `SystemInformation.VirtualScreen` 而不是单屏的 `WorkingArea` ——
  否则钉在副屏上的窗会被 clamp 回主屏。只有当窗口**完全落在虚拟桌面之外**时才收敛回来，
  不因为贴边而挪动用户指定的坐标。

### Added — 悬浮窗支持自定义宽度和高度 / Custom window size

新配置 `dialog.width` / `dialog.height`（0 = 自适应，默认）。

- 设了 `width`：预览图**等比缩放铺满**窗宽（`PictureBox` 的 `Zoom` 模式负责居中留白），
  而不是继续按 `previewMaxWidth` 独立算然后被窗口裁掉。此时 `previewMaxWidth` 不参与。
- 设了 `height`：多出来的高度全部给**注释框**（窗里唯一适合拉伸的控件 ——
  拉伸预览会糊，拉伸按钮行没意义）。注释框保底 40px。
- 尺寸给得过小时不会把控件挤爆：窗宽不低于按钮行所需宽度
  （`pad*2 + bw*2 + gap` = 198），窗高不低于「预览 + 注释 40 + 勾选框 + 按钮行」。

### Changed — 新增字段全部进 watcher 特征串 / All new fields join the restart key

`configKey()` 与 `ClipboardWatcher.writeWatcherConfig()` 都补齐了 5 个新字段。
助手只在**启动时**读一次 `watcher-config.json`，所以漏一个就表现为
「设置页改了没反应」—— 和 2026-10-29 定位的那类 bug 同一个坑。

### Tests

- `test/test-dialog-fixed.ps1`（新，14 项）：进程内 `Invoke-Expression` 抠出
  `Show-CaptureDialog` 实测 —— cursor 模式跟指针、fixed 模式钉坐标且与指针无关、
  固定尺寸生效、控件不越界、多余高度给了注释框、0/0 回到自适应、尺寸过小时按钮仍排得下。
  指针全程用 `$script:PointerOverride` 模拟，不动真实鼠标。
- `test/test-dialog-layout.ps1`：源码级断言同步更新（窗宽取大改为三目写法），
  新增「固定宽度时预览按窗宽缩放」「支持 fixed 定位」「fixed 用 VirtualScreen」三条。
- `test/test-config-shape.mjs`：钉住 5 个新字段的摊平（含负数 `fixedX`）、
  `Config` schema 里存在且默认值正确、枚举外 `positionMode` 被拒、
  以及 `writeWatcherConfig()` 真的把它们写进 json。
- `package.json` 新增 `test:window:fixed` 脚本。

### Note — 一个非插件问题：剪贴板被 Electron 锁死

实测期间遇到 `OpenClipboard` 一直返回错误 5（拒绝访问），owner 是
`DeepSeek Harness` 自己的 `Chrome_MessageWindow` —— 剪贴板句柄没释放。
这不是本插件的 bug，但会让任何剪贴板类测试（包括插件自身的监听）失效，
重启 Harness 即恢复。写在这里是因为排查时很容易误判成插件问题。

## [0.3.1] - 2026-10-29

### Added — 可下载的安装包 / Downloadable release artifact

打了 `v0.3.1` tag 并发布 GitHub Release，附带 `dsh-screenshot-capture-0.3.1.tgz`：

<https://github.com/passing11/dsh-screenshot-capture/releases/download/v0.3.1/dsh-screenshot-capture-0.3.1.tgz>

README 的安装章节重写，明确区分三种装法，并警告 **npm 上的同名包是上游 0.2.4**，
不含本 fork 的任何改动 —— 之前踩过的坑：profile 里声明成 `"0.2.4"` 时，
任何一次 `pnpm install` 都会把手工 `cp` 进去的改动覆盖回 npm 版本。

三种方式均实测通过（干净 profile 各装一次，装出来都是 0.3.1）：
`github:passing11/dsh-screenshot-capture`、Release 的 `.tgz` 绝对路径、本地目录 link。

### Changed — 指针位置统一走 `Get-PointerPosition`，测试不再挪真实鼠标 / Tests no longer move the real cursor

`clip-dialog.ps1` 新增 `Get-PointerPosition`：默认返回真实光标，但自动化测试可以把
`$script:PointerOverride` 设成一个返回 `Point` 的 scriptblock 来**模拟**指针位置。
窗口定位与「指针在窗上就冻结倒计时」两处判断都改走这个入口。

动机是测试可靠性，不是产品行为：

- 以前的窗口测试直接写 `[System.Windows.Forms.Cursor]::Position` 挪真光标。
  测试跑几秒，这几秒里用户没法用鼠标；更糟的是**用户一动鼠标就跟测试抢**，
  产品逻辑是对的，测试却报「用时不足」—— 实测 4 次跑 2 过 2 挂。
- 现在纯逻辑驱动，不碰硬件。同一套窗口测试连跑 8 轮 × 3 个文件 = 24 次全过
  （改之前失败率约 30%）。

### Fixed — 布局测试偶发挂死 / Layout test could hang forever

`test-dialog-layout.ps1` 原来用 `[System.Windows.Forms.Form]::ActiveForm` 找窗体，
拿到 `null` 时后面 `SendKeys` 的 Esc 发不出去，模态窗永远不返回，测试挂到超时。
改为从 `Application.OpenForms` 按标题找（不依赖焦点）并直接 `Close()`，另加一个
15 秒看门狗兜底关窗。同样的 `ActiveForm` 依赖也从 hover 测试里去掉了。

## [0.3.0] - 2026-10-29

### Removed — 去掉「复制截图」按钮 / Dropped the "copy screenshot" button

那个按钮什么也没做：剪贴板里本来就还是原图，点它跟直接按 Esc 一样。想让剪贴板
留着不动的用户按 Esc、或者让窗自己超时关就行，不需要专门一个按钮。

现在悬浮窗只有 **存文档 / 存图片** 两个按钮。Esc 与自动关闭的行为不变（不写库、
剪贴板原样保留），只是内部动作名从 `copy` 改成 `ignore` 更贴切。

> `core.mjs` 仍然认 `copy`，这样升级前已在跑的旧 PowerShell 助手不会因为动作名
> 变了而落进「未知动作」分支。

### Fixed — 去掉按钮后预览图被横向裁掉 / Preview clipped after the button row shrank

窗宽原来只按按钮行算（`pad*2 + bw*3 + gap*2`），预览图按 `previewMaxWidth` 独立算，
两者谁也不管谁。三键时代窗宽 292、图 320，本来就超了 28px 没被发现；去掉一个按钮后
窗宽掉到 198，320 宽的预览直接缺了一半。

现在 `$totalW = [Math]::Max($rowW, $pw + $pad * 2)` —— 取「按钮行」与「预览图」
较宽的那个。顺带把预览图的 `Location.X` 从硬编码的 `8` 改成 `$pad`。

### Tests

- `test/test-dialog-layout.ps1`（`npm run test:window:layout`）—— 读出真实窗体的
  控件树，断言：只有两个按钮、没有「复制截图」、预览图与注释框都在窗内且宽度对齐、
  所有按钮不越界。这条是专门为上面那个裁切漏子加的。

## [0.2.9] - 2026-10-29

### Changed — 鼠标停在窗口上时不再倒计时 / Pause while the pointer is over the window

上一版有意**不**监听鼠标移动，理由是窗口就弹在光标旁边，轻微抖动会不断重置、
永远关不掉。实际用下来这个取舍反了：指针压在窗上往往正是用户在读预览、准备点
按钮的时刻，这时候关窗是在跟人抢手。

现在的规则是：

- 指针在窗**内** → 倒计时冻结，不关。
- 指针**离开** → 重新给满一轮。所以「5 秒」的语义是「你不碰它 5 秒」，
  不是「从弹出算 5 秒」。
- 判据是屏幕坐标比较 `Cursor.Position` 与 `Form.Bounds`，不是 MouseEnter/Leave
  事件 —— 窗按 `offsetX/offsetY` 摆在光标右下方，刚弹出时指针本来就在窗**外**，
  不移动的话照常倒计时，行为与之前一致。

### Tests

- `test/test-autoclose-hover.ps1`（`npm run test:window:hover`）—— 把
  `offsetX/offsetY` 设成 0 让指针一开始就落在窗内，然后用一个跑在同一个消息泵里的
  Timer 在 3 秒后把光标挪走，断言：悬停期间窗没被关、离开后重新给满一轮才关、
  最终走忽略分支。

## [0.2.8] - 2026-10-29

### Fixed — profile 条目里写的 config 一直被静默丢弃 / Profile config silently dropped

上一版加的 `dialogAutoCloseSec` 在设置面板里看得见、改得动，但改完没有任何反应：
`%TEMP%\dsh-capture\watcher-config.json` 里永远是 `autoCloseSec: 0`。

- **根因**：宿主交给插件的配置是**扁平**的 —— `apply(ctx, input)` 的 `input` 和
  `settings.describe()` 的 `row.user` 都用 Config schema 里的字段名当键
  （`dialogAutoCloseSec`）。而代码里两处都写的是 `toFlat(plain(input))` /
  `toFlat(plain(row.user))`，`toFlat()` 要的是**嵌套**结构（`dialog.autoCloseSec`）。
  于是每个字段都读成 `undefined`，紧接着 `dropDefaults()` 把它们全过滤掉 ——
  profile 条目里 `config: { dialogAutoCloseSec: 5 }` 从来没进过 watcher。
- 这个 bug 从 0.1.x 就存在，只是没暴露：`~/.dsh-screenshot-capture/config.json`
  那一层用的确实是嵌套结构，走 `toFlat()` 恰好是对的；而宿主 profile 条目里的扁平
  config 才是**真正的权威值**，一直被无视。任何在设置面板里改的字段（不只是自动
  关闭）都属于这一类。

### Added

- `flattenConfig(value)` —— 自动判断输入形态：含嵌套对象就走 `toFlat()`，否则原样透传。
  两处调用点都换成它。
- `test/test-config-shape.mjs` —— 钉住扁平 / 嵌套 / Volatile cell / 空值四种输入形态，
  并端到端验证扁平 config 里的非默认值能活过 `dropDefaults()`。

## [0.2.7] - 2026-10-29

### Added — 悬浮窗可以自动关闭 / Auto-close the floating window

设置页「悬浮窗」组新增 **自动关闭 (秒)**，对应配置字段 `dialog.autoCloseSec`（默认 `0`）。

- `0` = 保持原行为，一直等你点按钮。填了秒数，到点窗口自己收起。
- 收起等同**忽略**（和按 Esc 一样）：`action=copy`、剪贴板原样保留、不写库、不弹下一层。
  故意没做成「自动存文档」—— 没有人确认的截图不该落进笔记里。
- **敲键盘 / 改注释 / 点窗口 / 勾「重点」会重新计时**，免得写到一半窗没了。
  没有监听鼠标移动：窗口就弹在鼠标位置，指针本来就压在上面，任何轻微抖动都会不断
  重置，那样永远关不掉。
- 事件日志的 `choice` 行多一个 `autoClosed` 字段，可以分辨「用户点了忽略」和「超时自动收起」。

实现注意：必须用 `System.Windows.Forms.Timer`，且计时只在窗体的 `Shown` 事件里启动
（构造 + 布局的时间不算进倒计时）。`Threading.Timer` 或 `Start-Sleep` 会在别的线程上
动控件，会炸。

### Changed

- `ClipboardWatcher` 把「写 watcher-config.json」抽成 `writeWatcherConfig()`，
  测试可以只跑这一步，不必真 spawn 一个 PowerShell。

### Tests

- `test/test-autoclose.mjs` —— JS 这半边的字段传递（缺省 0、小数秒、不丢其它字段、秒→毫秒换算）。
- `test/test-autoclose-dialog.ps1`（`npm run test:window`）—— 真窗口行为：到点自动关、
  用时落在 2000–3500ms、不写注释不勾重点、`0` 时不建 Timer、三个重置入口都挂着。

## [0.2.6] - 2026-10-28

### Fixed — 宿主模型没有 reasoning 元数据时 OCR 必然失败 / OCR failed for models without reasoning metadata

现场报错：

```
OCR: （识别失败:宿主模型: 模型返回错误 UNSUPPORTED_REASONING_EFFORT:
provider "workbuddy-global" model "deepseek-v4.1-flash"
does not support reasoning effort "off" | 千问: 未配置 key(可选,配了就能兜底)）
```

- **根因**：`ocr.mjs` 过去无条件写死 `reasoningEffort: "off"`（本意是「识别不要思考，省输出
  预算」）。但 DSH 的 `resolveCallWithInfo()` 里是这段逻辑：

  ```js
  const reasoning = info.reasoning;
  if (reasoning === void 0) {
    if (requested !== void 0) throw new LlmError(`provider "…" model "…" does not support reasoning effort "…"`, "UNSUPPORTED_REASONING_EFFORT");
  }
  ```

  也就是说：**模型只要没有 reasoning 元数据，传任何 effort 值都会在发出网络请求之前被拒**。
  `workbuddy-global/deepseek-v4.1-flash` 恰好没有 reasoning 元数据，于是整条识别链在第一步
  就断了，回落到千问又因为没配 key 而报第二条错 —— 两条拼成上面那句。

- **修法**：新增 `pickReasoningEffort()`，调用前先 `llm.resolveModelInfo(provider, model)` 查
  真实能力再决定：
  - 没有 `reasoning` 元数据 → **整个字段省略**（不传即走适配器默认，这是唯一能过的形状）；
  - 有 `reasoning.efforts` 且含 `off` → 传 `off`（保留原本「识别不思考」的意图）；
  - 有 `reasoning` 但没有 `off` → 用它的 `defaultEffort`；
  - 两者都没有，或能力查询本身失败 → 省略。

- **额外兜底**：若能力查询与实际 dispatch 之间对不上（适配器 HMR、目录抖动），捕获到
  `UNSUPPORTED_REASONING_EFFORT` 时**去掉 effort 自动重试一次**，并打一条 warn ——
  少一个控制项，好过整条识别失败。

- **新增回归测试** `test/test-reasoning.mjs`（已并入 `npm test`）：用假宿主复现四种元数据形态，
  断言「无 reasoning 元数据时绝不传 effort」且识别仍成功。不需要 key、不联网。

## [0.2.5] - 2026-10-28

### Changed — DSH 0.2 元数据与卡片分类对齐 / DSH 0.2 metadata & card-kind alignment

**No behavior change.** Three declaration-level fixes so the package states its DSH 0.2 support
explicitly instead of relying on the peer range alone.

- `package.json` 增加 `dsh.manifestVersion: 1`（包清单格式版本；DSH 0.2 的
  `@deepseek-ai/dsh-package-manifest` 定义的当前值为 `1`）。
- `package.json` 增加 `engines.dsh: ">=0.0.1-rc.1 <0.3.0-0"`。**注意这条会接管版本判定**：DSH 的
  `unmetRequirements()` 在插件自带 `engines.dsh` 时**只**看这个范围，`peerDependencies` 里的
  `@deepseek-ai/dsh-*` 检查全部跳过。选定范围实测覆盖 `0.0.1-rc.1` / `0.1.5-rc.3` / `0.1.7-rc.2` /
  `0.2.0-rc.1` / `0.2.0` / `0.2.1` / `0.2.1-rc.3`，`0.3.0-rc.1` 起拒绝。
- `repository` / `homepage` / `bugs` 指向 fork `passing11/dsh-screenshot-capture`（`author` 保留上游
  `wangzhanchao883` 署名）。
- `index.mjs` 的 `textTool().presentCall()` 把 `kind: "text"` 改为 `kind: "read"`：DSH 0.2 的
  `ToolCallKind` 枚举是 `read | edit | delete | move | search | execute | fetch | other`，`"text"` 不在其中
  （运行时不做校验，只是该工具卡片不参与分类）。

### Verified — DSH `0.2.1-rc.3` 本地实测

- 独立 profile `scc-compat-test` 用 `dsh plugin add` 安装成功，`dsh --profile scc-compat-test --dump-config`
  退出码 0、363 行、无 `FAILED` / `rejected` / `incompatible`。
- `--dump-config-schema` 里 `config66` 的 13 个字段全部存在且全部 `x-cordis.volatile: true`。
- desktop profile 上插件实际运行：`screenshot_status` 报「监听:运行中」，Web 设置页 `settings.section`
  的 occupants 里本插件 `active: true`。

## [0.2.4] - 2026-10-02

**发布通道迁移 —— 无代码变更、无行为变更。**

改用 npm Trusted Publishing（GitHub Actions + OIDC）发布，不再依赖任何长期令牌。
本版本用于验证新的发布链路，并让该版本带上 provenance（可验证的来源证明）。

## [0.2.3] - 2026-09-29

### Changed — DSH 0.2 compatibility / 兼容 DSH 0.2

**No functional code changed** — the peer range is the whole of it, the same shape our other plugins use.
Verified locally on **DSH `0.2.0-rc.1`**: `--dump-config` composes the plugin with no `FAILED` /
`rejected`, an isolated instance starts with zero `did not activate`, and the settings projection
still reports the entry as `applies: live` with all 13 fields.

- **Raised the peer upper bound.** `@deepseek-ai/dsh-tools` went from
  `>=0.0.1-rc.1 <0.1.0 || >=0.1.0-rc.1 <0.2.0-0` to
  `>=0.0.1-rc.1 <0.1.0 || >=0.1.0-rc.1 <0.2.0-0 || >=0.2.0-rc.1 <0.3.0-0`.
  The old bound excludes **every** `0.2.0` prerelease, and the harness gate compares the **whole DSH
  version** (not the version of `dsh-tools` actually installed). 0.1.7 merely skipped such a plugin at
  startup; 0.2.0 rejects it at install time (`installation rejected` / `nothing was installed`).
- `@deepseek-ai/schemastery` moved from `dependencies` to an **optional peer**
  (`>=3.18.0 <4.0.0` + `peerDependenciesMeta.optional`), matching our other plugins: the harness
  resolves `@deepseek-ai/*` imports from its own package tree, and the non-optional `dsh-tools` peer
  pulls `schemastery` down transitively anyway.
- Semver notes, verified against npm's own `semver` in **both** modes (`_diag/scc-peer-semver.mjs`):

  | version | old range | new range |
  |---|---|---|
  | `0.1.5-rc.3` / `0.1.7-rc.2` | true | true |
  | `0.2.0-rc.1` / `0.2.0` / `0.2.1` | **false** | **true** |
  | `0.3.0-rc.1` | false | false |

  With `includePrerelease: true` — what the harness gate passes — that table is the whole story. In
  plain (flagless) mode the explicit `>=0.2.0-rc.1` branch is what makes `0.2.0-rc.1` match at all
  (node-semver's prerelease-tuple rule), and in that mode `0.1.7-rc.2` would be rejected too — which is
  why the gate always passes the flag.

## [0.2.2] - 2026-09-29

OCR now runs on the **host's own multimodal model by default (zero extra API key)**, plus fixes for
the DSH 0.1.7 settings/volatile contract and for losing OCR text when two captures land back to back.
`0.2.1` was never published — it carried the 0.1.7 adaptation but was still broken in two of the ways
fixed below, so this release ships both.

### Added

- **Host-model OCR by default (`ocr.mode: "host"`).** No third-party key required: the image goes
  through the host attachment service (`attachments.saveImage` → `ImageAttachmentRef`) and is
  recognized with `ctx.llm.stream({ provider, model, reasoningEffort: "off" })` using the current
  default model, falling back to the first catalog model that declares
  `inputModalities: ["text", "image"]`. The new `ocr.hostModel` pins an exact model id; leave it
  empty to follow the DSH model selection. Measured on a real 57 KB screenshot: 2.7 s / 513
  characters, billed at the model's normal text price.
- **Fallback chain**: host model → Tongyi Qianwen (when a key is configured) → the note records
  **both** failure reasons instead of staying silent.
- **Clipboard helper auto-restart**: when `clip-dialog.ps1` exits unexpectedly the watcher restarts
  it with backoff (2s → 30s, up to 5 attempts) and warns loudly. Previously a single crash meant
  "screenshots silently stop working" until DSH was restarted.
- **Duplicate-screen guard.** Windows' snipping tool can push the *same* screen to the clipboard
  twice within a few seconds (measured: two images 1 px apart, 3 s apart), which used to mean two
  dialogs and two archived copies for one screenshot. The helper now compares a coarse 32×32 grey
  fingerprint against the last captures and skips near-identical ones inside `dupWindowMs`
  (default 6000 ms, `config.json` only; `0` disables the guard) and logs `{"t":"dup"}`.

### Changed

- **Simpler OCR section in the settings panel.** It now offers just 识别通道
  (`host` = the DSH model, `off`) plus 宿主模型 (`ocrHostModel`, empty = follow the DSH default).
  The Qwen model / API-key fields are gone from the panel — the Tongyi fallback still works and
  reads its key from `DASHSCOPE_API_KEY` or `config.json`.

### Fixed

- **Settings read-back no longer wipes `config.json`.** `settings.describe()` returns three layers:
  `value` / `base` carry schema defaults (`vaultPath: ""`), only `row.user` holds explicitly
  configured fields. Merging `value` clobbered the configured vault path, so the watcher never
  started: screenshots produced no dialog and no note.
- **Volatile cells are unwrapped.** DSH 0.1.7 hands every `.volatile()` field to `apply(ctx, input)`
  as a Volatile cell (`{ get() }`) — `JSON.stringify(cell)` is `{}` and `path.join(cell, …)` throws.
  Config is now unwrapped recursively and fields equal to the schema defaults are dropped, so an
  existing `config.json` keeps working.
- **Two captures in a row no longer lose OCR text.** Every dialog choice did its own
  read-modify-write on the daily note; with two captures ~3 s apart (OCR takes ~3 s) the second write
  clobbered the first, leaving `> OCR: 识别中…` in the note forever. Choices are now serialized,
  `updateEntryOcr` locates the entry by image file name (CRLF-tolerant) and **returns a failure
  reason instead of silently returning null**, and note writes retry on transient `EBUSY`/`EPERM`.
- Same-second captures no longer overwrite each other's attachment file
  (`…_文档.png` / `…_文档_2.png`).
- **The OCR text is no longer lost when the note is briefly locked.** Cloud-sync folders and
  Obsidian hold the note open for short windows; a failed write used to leave `> OCR: 识别中…`
  behind with the recognized text gone. Writes now back off over ~4.6 s, fall back to
  "write a temp file and replace", retry the whole update once after 800 ms, and if everything
  still fails the text is salvaged to `%TEMP%\dsh-capture\pending-ocr.jsonl` with a loud warning.
- The dialog helper's duplicate-screen fingerprint also covers the case where the second clipboard
  push differs by a pixel or two, which byte comparison would have missed.

### Compatibility

- Host-model OCR needs DSH with the `llm` + `attachments` services and a model that declares image
  input; without them the plugin falls back to Tongyi Qianwen, and with no key at all it records the
  reason in the note.

## [0.2.1] - 2026-09-26 (unpublished, shipped in 0.2.2)

Adapted to DSH 0.1.7's schema-driven settings contract (host + web client).

### Changed

- **Settings panel migrated off the removed `settingsScope` client service.**
  DSH 0.1.7 deleted `settingsScope` and replaced it with `configForms`, backed by
  a single shared mirror of the Host settings document. The web client now reads
  and writes through `ctx.configForms.get("<entry id>")`; `inject` declares
  `configForms` instead of `settingsScope`. The rendered component is unchanged —
  the controller exposes the same `getSnapshot` / `subscribe` / `set` surface and
  the same snapshot shape as before.
- **Host side no longer registers its own schema+value copy.** `settings.register`
  is gone in 0.1.7. The plugin now exports its schema as a named `Config`
  (`export const Config = z.object({...})`, no `default` export) and the settings
  service projects the live profile entry through it. Values are read back with
  `settings.describe()`; the removed `watch` is not needed because Loader hot
  reload re-applies the plugin with the new entry config.
- Every writable field is tagged `.volatile()` — without it the settings service
  silently drops the whole entry from its form, and a per-field write is rejected
  with `Config field "x" is not volatile`.
- `@deepseek-ai/schemastery` dependency raised to `^3.18.4` (`.volatile()` was
  added in 3.18.4; 3.18.1 throws `volatile is not a function` at module load).
  A defensive `vol()` wrapper keeps older schemastery installs from crashing.
- `dsh.client.inject` no longer lists `@deepseek-ai/dsh-client-runtime`, which no
  longer exists in 0.1.7.
- `@deepseek-ai/dsh-tools` peer range left untouched — it already matches
  `0.1.7-rc.2` under `includePrerelease` semantics.

### Fixed

- With an empty `vaultPath` the plugin no longer runs `ensureVault` at startup.
  `join("", "收件箱")` resolved to a relative path and created `收件箱/知识库/…`
  directories in the process working directory — exactly what the "disables
  capture and warns rather than creating unrelated directories" promise said it
  would not do.

### Compatibility

- Settings page requires DSH 0.1.7+. On older builds the host features (clipboard
  watcher, floating window, OCR, tools) still work; the settings page simply does
  not appear.

## [0.2.0] - 2026-08-24

### Added

- **Comment / key-point marking**: the floating dialog now has a comment input
  and a "重点 / key point" checkbox. Marking a capture as a key point writes a
  `# **重点**` heading above its note.
- **Config example** (`config.example.json`) and a committed 1×1 `test/sample.png`
  so the unit tests run on any checkout.

### Changed

- Default `vaultPath` is now empty instead of pointing at a private local path.
  When unconfigured the plugin disables capture and warns rather than creating
  unrelated directories.
- Test scripts derive the repo root from `import.meta.url` instead of a
  hardcoded path, and the OCR test skips (rather than fails) when no API key is
  configured.
- `peerDependencies` range for `@deepseek-ai/dsh-tools` now includes an explicit
  prerelease branch so it matches prerelease harness builds.

## [0.1.0] - 2026-08-22

### Added

- Initial release: clipboard watcher + system floating window (copy / save-doc /
  save-image), instant OCR via Tongyi Qianwen, Obsidian per-day note merging,
  and an evening AI organization pass (categories, backlinks, daily summary,
  archive).
- Web settings page under DSH 设置 →「截图入库」with live reload.
