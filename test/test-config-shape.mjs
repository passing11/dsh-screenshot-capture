/**
 * 配置形状:宿主交给插件的 config 到底是**扁平**还是**嵌套**。
 *
 * 背景(2026-10-29 定位的真故障):`apply(ctx, input)` 的 input 和
 * `settings.describe()` 的 `row.user` 都是**扁平**的 —— 键名就是 Config schema
 * 里那些(`dialogAutoCloseSec`)。而 `toFlat()` 吃的是**嵌套**结构
 * (`dialog.autoCloseSec`)。两处早前都直接写了 `toFlat(...)` 去处理扁平输入,
 * 于是每个字段都读成 undefined、被 `dropDefaults()` 过滤干净 —— profile 条目里
 * 写的 `config: { dialogAutoCloseSec: 5 }` 永远进不了 watcher,设置页里改的值
 * 也一样。`config.json` 那一层恰好是嵌套结构,所以这个 bug 藏了很久。
 *
 * 这个测试直接钉住 `flattenConfig()` 的三种输入形态,防止再次退化。
 */
import assert from "node:assert/strict";

const { flattenConfig } = await import("../index.mjs");

/** 扁平输入(宿主实际给的形态)必须原样透传 */
const flatIn = { enabled: true, vaultPath: "E:\\v", dialogAutoCloseSec: 5 };
assert.deepEqual(flattenConfig(flatIn), flatIn, "扁平输入应原样透传");

/** 嵌套输入(config.json 的形态)必须被摊平 */
const nestedIn = {
  enabled: true,
  vaultPath: "E:\\v",
  dialog: { positionMode: "fixed", fixedX: -1200, fixedY: 40, offsetX: 40, offsetY: 8, previewMaxWidth: 500, width: 520, height: 640, autoCloseSec: 12 },
  ocr: { mode: "host", hostModel: "a/b" },
};
const nestedOut = flattenConfig(nestedIn);
assert.equal(nestedOut.dialogAutoCloseSec, 12, "嵌套 input.dialog.autoCloseSec 应摊平");
assert.equal(nestedOut.dialogPositionMode, "fixed", "嵌套 input.dialog.positionMode 应摊平");
assert.equal(nestedOut.dialogFixedX, -1200, "副屏在主屏左边时 x 为负,不能丢符号");
assert.equal(nestedOut.dialogFixedY, 40);
assert.equal(nestedOut.dialogWidth, 520);
assert.equal(nestedOut.dialogHeight, 640);
assert.equal(nestedOut.dialogOffsetX, 40);
assert.equal(nestedOut.dialogPreviewMaxWidth, 500);
assert.equal(nestedOut.ocrMode, "host");
assert.equal(nestedOut.ocrHostModel, "a/b");
assert.equal(nestedOut.vaultPath, "E:\\v");
assert.equal(nestedOut.dialog, undefined, "摊平后不应残留嵌套键");

/** Volatile cell(config.mjs 的 plain() 负责解包) */
const cellified = flattenConfig({ dialogAutoCloseSec: { get: () => 7 } });
assert.equal(cellified.dialogAutoCloseSec, 7, "Volatile cell 应被解包");

/** 空 / 非对象输入不能炸 */
assert.deepEqual(flattenConfig(undefined), {});
assert.deepEqual(flattenConfig(null), {});
assert.deepEqual(flattenConfig({}), {});

/**
 * 端到端:扁平 config 里的非默认值必须活过 dropDefaults 那一关。
 * 这里用真实的 DEFAULT_CONFIG 作参照 —— autoCloseSec 默认 0,写 5 就该留下。
 */
const { DEFAULT_CONFIG } = await import("../config.mjs");
const flatWithValue = flattenConfig({ ...flatIn, dialogAutoCloseSec: 5, cooldownMs: DEFAULT_CONFIG.cooldownMs });
const nonDefault = Object.fromEntries(
  Object.entries(flatWithValue).filter(([k, v]) => {
    const defaults = { cooldownMs: DEFAULT_CONFIG.cooldownMs };
    return v !== undefined && !Object.is(v, defaults[k]);
  }),
);
assert.equal(nonDefault.dialogAutoCloseSec, 5, "自定义的 autoCloseSec 不能被当成默认值丢掉");

/**
 * 新字段必须进 Config schema —— 漏一个就表现为「设置页改了没反应」:
 * 宿主按 schema 过滤写入,不在 schema 里的键会被静默丢弃。
 */
const { Config } = await import("../index.mjs");
const { plain: unwrap } = await import("../config.mjs");
const parsed = unwrap(Config({}));
for (const key of [
  "dialogPositionMode", "dialogFixedX", "dialogFixedY",
  "dialogWidth", "dialogHeight",
]) {
  assert.ok(key in parsed, `Config 里缺少 ${key}`);
}
assert.equal(parsed.dialogPositionMode, "cursor", "默认应跟随鼠标(保持历史行为)");
assert.equal(parsed.dialogWidth, 0, "宽度默认 0 = 自适应");
assert.equal(parsed.dialogHeight, 0, "高度默认 0 = 自适应");

/** 枚举外的 positionMode 必须被 schema 拒绝 */
assert.throws(() => Config({ dialogPositionMode: "nope" }), "positionMode 应只接受 cursor/fixed");

/** watcher 配置要把新字段真的传给 PowerShell 助手(漏传 = 设置页改了没效果) */
const { ClipboardWatcher } = await import("../clipboard.mjs");
const w = new ClipboardWatcher({
  pollIntervalMs: 200,
  cooldownMs: 2000,
  dialog: { positionMode: "fixed", fixedX: -1200, fixedY: 40, offsetX: 5, offsetY: 6, previewMaxWidth: 400, width: 520, height: 640, autoCloseSec: 3 },
});
const written = w.writeWatcherConfig();
assert.equal(written.positionMode, "fixed", "watcher 配置缺 positionMode");
assert.equal(written.fixedX, -1200, "watcher 配置缺 fixedX");
assert.equal(written.fixedY, 40, "watcher 配置缺 fixedY");
assert.equal(written.width, 520, "watcher 配置缺 width");
assert.equal(written.height, 640, "watcher 配置缺 height");
assert.equal(written.previewMaxWidth, 400);
assert.equal(written.autoCloseSec, 3);
assert.equal(written.offsetX, 5);
assert.equal(written.offsetY, 6);

console.log("[config-shape-test] 全部通过");
