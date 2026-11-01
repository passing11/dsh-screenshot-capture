# Tests

The unit tests run **without DSH** and without any API key. They use a tiny
committed sample image (`sample.png`) and write into scratch `test-vault` /
`format-vault` directories that are `gitignore`d.

## Run

```sh
npm test                      # all JS suites (no key, no DSH needed)
npm run test:window:layout    # floating dialog layout (in-process, no clipboard)
npm run test:window:resize    # dialog resize + relayout (in-process, no clipboard)
npm run test:window:fixed     # fixed position / fixed size
npm run test:window           # auto-close countdown
npm run test:window:hover     # auto-close pauses while the pointer is over the window
npm run test:window:remember  # remember-last-position state file and fallbacks
npm run test:window:live      # real end-to-end (needs a free clipboard)
npm run test:window:resize:live
npm run test:ocr              # live OCR against Qwen — needs DASHSCOPE_API_KEY
```

### What each suite covers

| Suite | Covers |
| --- | --- |
| `test-format.mjs` | per-day note markdown shape |
| `test-storage.mjs` | storage + evening organize (backlinks, summaries) |
| `test-reasoning.mjs` | `reasoningEffort` negotiation against 4 model-metadata shapes |
| `test-autoclose.mjs` | the seconds→milliseconds hand-off to the PowerShell helper |
| `test-config-shape.mjs` | flat ↔ nested config projection |
| `test-single-instance.mjs` | one watcher per machine (lock file, stale locks) |
| `test-settings-reload.mjs` | `settings/document-updated` hot reload, incl. changing back to a default value |
| `test-dialog-layout.ps1` | initial dialog layout: preview not clipped, everything inside the window |
| `test-dialog-resize.ps1` | **resizable border** (`WS_THICKFRAME` on the real handle), minimum size, and the relayout after dragging bigger *and* smaller |
| `test-dialog-fixed.ps1` | fixed position / fixed size, and that content still fits |
| `test-dialog-remember.ps1` | `remember` mode: state file round-trip, fallback to cursor when the record is missing / off-screen / corrupt, and `MinimumSize` clamping |
| `test-autoclose-dialog.ps1` | the countdown actually closes the dialog |
| `test-autoclose-hover.ps1` | hovering pauses the countdown |
| `test-live-fixed.ps1` | real spawn → clipboard → on-screen window rectangle |
| `test-live-resize.ps1` | real spawn → clipboard → `SetWindowPos` resize → `GetWindowRect` |

### Clipboard-dependent tests

`test-live-*.ps1` need to put an image on the clipboard, which is a **globally
exclusive** resource. Chrome and other Electron apps routinely hold it; when
`OpenClipboard` fails the suite prints `SKIP` and exits 0 rather than reporting a
failure. The in-process suites (`test-dialog-layout.ps1`,
`test-dialog-resize.ps1`, `test-dialog-fixed.ps1`) do **not** touch the
clipboard, so they are the reliable ones to run.

`test-ocr.mjs` calls the real Qwen multimodal API, so it needs a key and a
network connection. When no key is configured it simply skips (exit 0), so a
local, key-less run never fails.

## Editing the PowerShell helper

`scripts/clip-dialog.ps1` **must keep its UTF-8 BOM and LF line endings**. With
the BOM, PowerShell reads the file as UTF-8; without it, PowerShell falls back to
the system ANSI codepage (GBK on a Chinese Windows), the Chinese comments turn to
mojibake, and `Parser::ParseFile` fails with an "unexpected token" error. After
any edit, re-check it:

```powershell
$t=$null; $e=$null
[System.Management.Automation.Language.Parser]::ParseFile(
  'scripts\clip-dialog.ps1', [ref]$t, [ref]$e) | Out-Null
if ($e.Count -eq 0) { 'OK' } else { $e | ForEach-Object { $_.Message } }
```
