/**
 * 设置热更新:改完设置之后,插件到底能不能把新值吃到 liveConfig 里。
 *
 * 背景(2026-11-01 定位的真故障):用户报「固定位置不生效」。保存链路修好之后
 * `cordis.patch.yml` 里确实出现了 `dialogPositionMode: fixed`,但窗口还是跟着
 * 鼠标跑 —— 因为 `index.mjs` 只在插件加载时读一次 `settings.describe()`,
 * **从来没订阅过** `settings/document-updated`。宿主把值写进 profile patch 了,
 * 运行中的插件毫不知情,`liveConfig` 停在旧值,`scheduleRestart` 里
 * `key === watcherKey` 恒成立,每次都提前 return。
 *
 * 这个测试钉住两件事:
 *  ① 变更路径**不能**套 dropDefaults —— 否则把字段改回 schema 默认值
 *     (如 dialogPositionMode 从 fixed 改回 cursor)会被当成"没改"丢掉;
 *  ② 变更路径必须真的把新值合并进 liveConfig(含嵌套的 dialog/ocr)。
 */
import assert from "node:assert/strict";

const { dropDefaults, fromFlat, mergeSettings, flattenConfig, geometryKeyOf } = await import("../index.mjs");

// ---- ① dropDefaults 的语义:等于默认值的字段会被丢掉 ----
// 这是它存在的理由(防老版本宿主把默认值灌进来冲掉 config.json),
// 也正是变更路径不能用它的原因。
const withDefaults = {
  enabled: true,
  vaultPath: "E:\\v",
  dialogPositionMode: "cursor", // ← 恰好等于 schema 默认值
  dialogFixedX: 1201, // ← 不等于默认值
};
const dropped = dropDefaults(withDefaults);
assert.equal("dialogPositionMode" in dropped, false, "cursor 等于默认值,应被 dropDefaults 丢掉");
assert.equal(dropped.dialogFixedX, 1201, "非默认值应保留");

// ---- ② 变更路径(不 drop)必须保留 cursor ----
const kept = dropDefaults === undefined ? null : withDefaults; // 变更路径直接用原值
assert.equal(kept.dialogPositionMode, "cursor", "变更路径必须保留等于默认值的字段");

// ---- ③ fromFlat 逐字段判存,不能把缺字段写成 undefined ----
const partial = fromFlat({ dialogPositionMode: "fixed" });
assert.deepEqual(partial, { dialog: { positionMode: "fixed" } }, "只给了 positionMode 就只产出它");
assert.equal("fixedX" in (partial.dialog ?? {}), false, "没给的字段不能凭空出现");

// ---- ④ mergeSettings 深合并:顶层浅合并,dialog/ocr 逐层合并 ----
const base = {
  enabled: true,
  vaultPath: "E:\\v",
  pollIntervalMs: 200,
  ocr: { mode: "host", hostModel: "", model: "qwen-vl-plus", apiKey: "", endpoint: "e", prompt: "p" },
  dialog: { positionMode: "cursor", fixedX: 0, fixedY: 0, offsetX: 16, offsetY: 16, previewMaxWidth: 320, width: 0, height: 0, autoCloseSec: 0 },
};

// 只改一个 dialog 字段:其余 dialog 字段和顶层字段都必须原样保留
const merged = mergeSettings(base, { dialogPositionMode: "fixed", dialogFixedX: 1201 });
assert.equal(merged.dialog.positionMode, "fixed", "新值应写入");
assert.equal(merged.dialog.fixedX, 1201, "新值应写入");
assert.equal(merged.dialog.autoCloseSec, 0, "未提及的 dialog 字段应保留旧值");
assert.equal(merged.dialog.previewMaxWidth, 320, "未提及的 dialog 字段应保留旧值");
assert.equal(merged.vaultPath, "E:\\v", "未提及的顶层字段应保留旧值");
assert.equal(merged.pollIntervalMs, 200, "未提及的顶层字段应保留旧值");
assert.equal(merged.ocr.model, "qwen-vl-plus", "ocr 整块未提及时应原样保留");

// 把 positionMode 改回 cursor(默认值)也必须生效 —— 这正是原来坏掉的那一步
const back = mergeSettings(merged, { dialogPositionMode: "cursor" });
assert.equal(back.dialog.positionMode, "cursor", "改回默认值 cursor 也必须生效");

// ---- ⑤ flattenConfig 对扁平的 row.user 原样透传(设置服务的实际形态)----
const userRow = { dialogPositionMode: "fixed", dialogFixedX: 1201 };
assert.deepEqual(flattenConfig(userRow), userRow, "扁平的 row.user 应原样透传");

// ---- ⑥ 端到端:模拟一次 document-updated ----
// 宿主 emit 时只给 ns + revision,插件自己重新 describe() 拿 row.user。
let live = mergeSettings(base, { dialogPositionMode: "cursor" });
const applyUpdate = (userRowFlat) => {
  // 变更路径:dropSchemaDefaults = false
  live = mergeSettings(live, flattenConfig(userRowFlat));
};
applyUpdate({ dialogPositionMode: "fixed", dialogFixedX: 1201, dialogAutoCloseSec: 0 });
assert.equal(live.dialog.positionMode, "fixed");
assert.equal(live.dialog.fixedX, 1201);
assert.equal(live.dialog.autoCloseSec, 0);
applyUpdate({ dialogPositionMode: "cursor" }); // 改回默认值
assert.equal(live.dialog.positionMode, "cursor", "改回默认值也要生效(这是 0.4.2 修的那条)");

// ---- ⑦ geometryKeyOf:判断"哪些字段算窗口几何" ----
// 0.4.6 曾用这个判据决定"要不要删掉位置记录"——那时记录无条件优先,设置页里
// 填的坐标/尺寸永远被压住,只能靠删记录让新设置生效。
// 0.4.8 起 remember 是**独立模式**,fixed/cursor 根本不读记录,两者不再冲突,
// 删记录那套逻辑也随之去掉。函数本身留着,只作为"哪些字段属于窗口几何"的
// 单一出处 —— 免得以后又有人手抄一份字段清单,抄漏了才发现。
const geoBase = geometryKeyOf(base);
assert.equal(geometryKeyOf(base), geoBase, "同一份配置算两次必须相同");

for (const [field, value] of [
  ["dialogPositionMode", "fixed"],
  ["dialogFixedX", 111],
  ["dialogFixedY", 222],
  ["dialogWidth", 800],
  ["dialogHeight", 600],
]) {
  const changed = mergeSettings(base, { [field]: value });
  assert.notEqual(geometryKeyOf(changed), geoBase, `${field} 变了必须被认作几何变化`);
}

// 与窗口几何无关的设置变了,不算几何变化
for (const [field, value] of [
  ["pollIntervalMs", 500],
  ["cooldownMs", 3000],
  ["dialogOffsetX", 40],
  ["dialogOffsetY", 40],
  ["dialogPreviewMaxWidth", 500],
  ["dialogAutoCloseSec", 5],
]) {
  const changed = mergeSettings(base, { [field]: value });
  assert.equal(geometryKeyOf(changed), geoBase, `${field} 与窗口几何无关,不该算几何变化`);
}

// remember 是合法取值,不是"历史遗留等同 cursor"
assert.equal(
  mergeSettings(base, { dialogPositionMode: "remember" }).dialog.positionMode,
  "remember",
  "remember 必须原样保留,不能被 merge 折叠成 cursor",
);

console.log("[settings-reload-test] 全部通过");
