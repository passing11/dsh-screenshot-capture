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
  dialog: { offsetX: 40, offsetY: 8, previewMaxWidth: 500, autoCloseSec: 12 },
  ocr: { mode: "host", hostModel: "a/b" },
};
const nestedOut = flattenConfig(nestedIn);
assert.equal(nestedOut.dialogAutoCloseSec, 12, "嵌套 input.dialog.autoCloseSec 应摊平");
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

console.log("[config-shape-test] 全部通过");
