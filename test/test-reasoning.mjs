// 回归测试:宿主模型没有 reasoning 元数据时,绝不能传 reasoningEffort。
//
// 现场故障(2026-10-28):
//   OCR: （识别失败:宿主模型: 模型返回错误 UNSUPPORTED_REASONING_EFFORT:
//        provider "workbuddy-global" model "deepseek-v4.1-flash"
//        does not support reasoning effort "off" | 千问: 未配置 key）
//
// 成因:ocr.mjs 过去硬写 reasoningEffort: "off"。DSH 的 resolveCallWithInfo() 里
//   if (reasoning === void 0) { if (requested !== void 0) throw ... UNSUPPORTED_REASONING_EFFORT }
// 也就是说:模型只要没有 reasoning 元数据,传任何 effort 都在发请求前被拒。
//
// 这个测试用假宿主复现两种情况,不需要 key、不联网:
//   ① 无 reasoning 元数据 → 必须不传该字段,且识别成功
//   ② 有 reasoning 且含 off   → 传 off(保留"识别不思考"的原意)
import { ocrImage } from "../ocr.mjs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const src = join(root, "test", "sample.png");

/** 造一个假宿主:resolveModelInfo 按给定元数据回,stream 记录收到的 options */
function fakeHost(modelInfo) {
  const seen = [];
  return {
    seen,
    host: {
      llm: {
        async resolveModelInfo() {
          return modelInfo;
        },
        async listModels() {
          return [{ provider: "p", id: "m", name: "m", inputModalities: ["text", "image"] }];
        },
        listProviders() {
          return [{ id: "p", name: "p" }];
        },
        stream(options) {
          seen.push(options);
          // 复刻宿主校验:无 reasoning 元数据却带了 effort → 抛错
          if (modelInfo.reasoning === undefined && options.reasoningEffort !== undefined) {
            throw new Error(
              `provider "${options.provider}" model "${options.model}" does not support reasoning effort "${options.reasoningEffort}"`,
            );
          }
          return (async function* () {
            yield { type: "text-delta", index: 0, text: "识别结果 OK" };
            yield { type: "finish", reason: { kind: "stop" } };
          })();
        },
      },
      attachments: {
        imageLimits: { mediaTypes: ["image/png", "image/jpeg"], maxImageBytes: 20 * 1024 * 1024 },
        async saveImage({ mediaType }) {
          return { attachmentId: "sha256:fake", mediaType, bytes: 1, width: 1, height: 1 };
        },
      },
      agentDefaultModel: { currentSelection: () => ({ provider: "p", model: "m" }) },
      logger: { info() {}, warn() {} },
    },
  };
}

const config = { ocr: { mode: "host", hostModel: "", prompt: "识别文字" } };
let failed = 0;

async function check(label, modelInfo, expectField) {
  const { host, seen } = fakeHost(modelInfo);
  try {
    const text = await ocrImage(config, src, host);
    const got = seen[0]?.reasoningEffort;
    const okField = expectField === undefined ? got === undefined : got === expectField;
    const okText = text === "识别结果 OK";
    console.log(
      `${okField && okText ? "OK  " : "FAIL"} ${label} → reasoningEffort=${JSON.stringify(got)} text=${JSON.stringify(text)}`,
    );
    if (!okField || !okText) failed += 1;
  } catch (err) {
    console.log(`FAIL ${label} → 抛错:${err.message}`);
    failed += 1;
  }
}

// ① 现场那个模型:完全没有 reasoning 元数据
await check("无 reasoning 元数据(workbuddy-global/deepseek-v4.1-flash 的情形)", { provider: "p", id: "m", name: "m" }, undefined);

// ② 支持推理且公开了 off → 应传 off
await check(
  "有 reasoning 且含 off",
  { provider: "p", id: "m", name: "m", reasoning: { efforts: [{ id: "off", name: "off" }, { id: "high", name: "high" }] } },
  "off",
);

// ③ 支持推理但没公开 off → 用它的默认档,而不是硬塞 off
await check(
  "有 reasoning 但只有 high/max",
  { provider: "p", id: "m", name: "m", reasoning: { efforts: [{ id: "high", name: "high" }, { id: "max", name: "max" }], defaultEffort: "high" } },
  "high",
);

// ④ 支持推理但既没 off 也没 defaultEffort → 不传
await check(
  "有 reasoning 但无 off 也无 defaultEffort",
  { provider: "p", id: "m", name: "m", reasoning: { efforts: [{ id: "low", name: "low" }] } },
  undefined,
);

if (failed > 0) {
  console.error(`\n[reasoning-test] ${failed} 项失败`);
  process.exitCode = 1;
} else {
  console.log("\n[reasoning-test] 全部通过");
}
