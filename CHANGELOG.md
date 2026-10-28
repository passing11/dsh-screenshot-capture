# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
