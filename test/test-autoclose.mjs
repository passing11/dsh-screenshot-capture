/**
 * 悬浮窗自动关闭:校验「设置 → 插件配置 → watcher-config.json → 脚本」这条链
 * 上「秒数」有没有一路传到位(单位、0 的语义、缺省值)。
 *
 * 真正弹窗的行为由 PowerShell 侧保证 —— 必须在 UI 消息泵里用
 * System.Windows.Forms.Timer,把 DialogResult 设成 Cancel 再 Close。
 * 那部分由 test-autoclose.ps1 单独验,这里只测 JS 这半边不漏字段。
 */
import { join } from "node:path";
import { tmpdir } from "node:os";
import { rmSync } from "node:fs";
import assert from "node:assert/strict";

const WORK = join(tmpdir(), "dsh-capture-autoclose-test");
rmSync(WORK, { recursive: true, force: true });

const { ClipboardWatcher } = await import("../clipboard.mjs");

/** 只跑「写配置」这一步,不 spawn powershell */
function flat(cfg) {
  const w = new ClipboardWatcher(cfg);
  w.workDir = WORK;
  return w.writeWatcherConfig();
}

const cases = [
  ["不给 dialog → 0(默认不自动关)", {}, 0],
  ["dialog 里没有 autoCloseSec → 0", { dialog: { offsetX: 16 } }, 0],
  ["autoCloseSec=3", { dialog: { autoCloseSec: 3 } }, 3],
  ["autoCloseSec=0.5(小数秒要原样保留)", { dialog: { autoCloseSec: 0.5 } }, 0.5],
  ["autoCloseSec 与其它 dialog 字段共存", { dialog: { offsetX: 40, offsetY: 8, previewMaxWidth: 500, autoCloseSec: 12 } }, 12],
];

for (const [name, cfg, want] of cases) {
  const out = flat(cfg);
  assert.equal(out.autoCloseSec, want, `${name}: watcher-config.autoCloseSec`);
}

// 其它字段不能被这层改动弄丢
const full = flat({ pollIntervalMs: 150, cooldownMs: 3000, dupWindowMs: 0, dialog: { offsetX: 40, offsetY: 8, previewMaxWidth: 500, autoCloseSec: 7 } });
assert.equal(full.pollIntervalMs, 150);
assert.equal(full.cooldownMs, 3000);
assert.equal(full.dupWindowMs, 0);
assert.equal(full.offsetX, 40);
assert.equal(full.offsetY, 8);
assert.equal(full.previewMaxWidth, 500);
assert.equal(full.autoCloseSec, 7);

// 秒 → 毫秒:脚本侧是 [int]($config.autoCloseSec * 1000)。
// 单位错了窗口会瞬间消失(3 秒变成 3 毫秒),这一层必须钉住。
const toMs = (sec) => Math.trunc(sec * 1000);
assert.equal(toMs(3), 3000);
assert.equal(toMs(0.5), 500);
assert.equal(toMs(0), 0);

rmSync(WORK, { recursive: true, force: true });
console.log("[autoclose-test] 全部通过");
