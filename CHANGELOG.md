# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
