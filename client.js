/* dsh-screenshot-capture client bundle — 浏览器半端(Web 设置页)。
 * 以经典脚本形式注册到 window.__ModuleLoader__;工厂内用 require 取 React,
 * 不能用 JSX(无构建步骤),一律 React.createElement。 */
window.__ModuleLoader__.load({
  id: "dsh-screenshot-capture",
  factory: (require) => {
    var module = { exports: {} };
    var exports = module.exports;

    const React = require("react");
    const h = React.createElement;
    const { useEffect, useRef, useState } = React;

    const NS = "settings.screenshotCapture";
    const SETTINGS_NAMESPACE = "dsh-screenshot-capture";

    const zh = {
      nav: "截图入库",
      loading: "正在读取配置…",
      unavailable: "配置面板不可用(设置服务未挂载)。请直接编辑配置 JSON 文件。",
      saved: "已保存",
      error: "保存失败:",
      rejected: "宿主拒绝了这次修改(配置未变)",
      general: "通用",
      enabled: "启用剪贴板监听",
      enabledHint: "关闭后不再监听剪贴板,悬浮窗也不会弹出",
      vaultPath: "Obsidian 库路径",
      vaultPathHint: "截图笔记会写入这个库",
      pollIntervalMs: "剪贴板轮询间隔 (ms)",
      cooldownMs: "截图冷却时间 (ms)",
      ocr: "OCR 文字识别",
      ocrMode: "识别通道",
      ocrModeHost: "宿主大模型(默认,零配置)",
      ocrModeOff: "关闭(只存图不识别)",
      ocrHostModel: "宿主模型",
      ocrHostModelHint: "留空 = 跟随 DSH 当前默认模型;填模型 id 可强制指定",
      ocrFallbackHint: "宿主模型不可用时自动回落通义千问(key 从环境变量 DASHSCOPE_API_KEY 读取,无需在此配置)",
      dialog: "悬浮窗",
      dialogPositionMode: "出现位置",
      dialogPositionModeHint: "「跟随鼠标」在光标旁弹出;「固定坐标」出现在下面填的位置,和鼠标无关;「记住上次位置」沿用你上次关窗口时摆放的位置和大小。三种模式互不影响,随时可以切换。",
      dialogPositionCursor: "跟随鼠标",
      dialogPositionFixed: "固定坐标",
      dialogPositionRemember: "记住上次位置",
      dialogRememberHint: "沿用上次关闭窗口时的位置和大小。第一次用(还没有记录)时会退回「跟随鼠标」的行为。",
      dialogFixedX: "固定 X (px)",
      dialogFixedY: "固定 Y (px)",
      dialogWidth: "宽度 (px,0=自适应)",
      dialogHeight: "高度 (px,0=自适应)",
      dialogSizeHint: "填 0 表示按内容自适应。设了宽度时预览图会等比缩放到窗宽;设了高度时多出来的空间给注释框。",
      dialogSizeRememberHint: "这两种模式下的「宽度 / 高度」只在「跟随鼠标」「固定坐标」模式生效;切到「记住上次位置」后由记录决定。",
      dialogPreviewMaxWidth: "预览最大宽度 (px)",
      dialogPreviewMaxWidthHint: "仅在宽度填 0(自适应)时生效。",
      dialogOffsetX: "横向偏移 (px)",
      dialogOffsetY: "纵向偏移 (px)",
      dialogAutoCloseSec: "自动关闭 (秒,0=不关)",
      dialogAutoCloseHint: "到点自动收起,等同「忽略」:剪贴板原样保留、不写库。敲键盘 / 改注释 / 点窗口会重新计时。",
    };

    const en = {
      nav: "Screenshot Capture",
      loading: "Reading configuration…",
      unavailable: "Configuration panel unavailable (settings service not mounted). Edit the config JSON file directly instead.",
      saved: "Saved",
      error: "Save failed:",
      rejected: "the host rejected this change (config unchanged)",
      general: "General",
      enabled: "Enable clipboard watching",
      enabledHint: "When off, clipboard watching and the floating window are disabled",
      vaultPath: "Obsidian vault path",
      vaultPathHint: "Screenshots are stored into this vault",
      pollIntervalMs: "Clipboard poll interval (ms)",
      cooldownMs: "Screenshot cooldown (ms)",
      ocr: "OCR",
      ocrMode: "Recognition channel",
      ocrModeHost: "Host model (default, zero config)",
      ocrModeOff: "Off (store without OCR)",
      ocrHostModel: "Host model",
      ocrHostModelHint: "Leave empty to follow the current DSH default model; set a model id to pin one",
      ocrFallbackHint: "Falls back to Tongyi Qianwen when the host model is unavailable (key read from DASHSCOPE_API_KEY; not configured here)",
      dialog: "Floating window",
      dialogPositionMode: "Position",
      dialogPositionModeHint: "\"Follow cursor\" pops up next to the pointer; \"Fixed\" appears at the coordinates below, regardless of the pointer; \"Remember last\" reuses the position and size you left the window at. The three modes are independent — switch freely.",
      dialogPositionCursor: "Follow cursor",
      dialogPositionFixed: "Fixed coordinates",
      dialogPositionRemember: "Remember last",
      dialogRememberHint: "Reuses the position and size from the last time you closed the window. With no record yet it falls back to \"Follow cursor\".",
      dialogFixedX: "Fixed X (px)",
      dialogFixedY: "Fixed Y (px)",
      dialogWidth: "Width (px, 0 = auto)",
      dialogHeight: "Height (px, 0 = auto)",
      dialogSizeHint: "0 means size to content. With a fixed width the preview scales to fit it; with a fixed height the extra space goes to the note box.",
      dialogSizeRememberHint: "These only apply in \"Follow cursor\" and \"Fixed\" modes; \"Remember last\" takes its geometry from the record instead.",
      dialogPreviewMaxWidth: "Preview max width (px)",
      dialogPreviewMaxWidthHint: "Only used when width is 0 (auto).",
      dialogOffsetX: "Horizontal offset (px)",
      dialogOffsetY: "Vertical offset (px)",
      dialogAutoCloseSec: "Auto-close (s, 0 = never)",
      dialogAutoCloseHint: "Collapses on its own when time is up — same as ignoring: clipboard untouched, nothing stored. Typing, editing the note or clicking the window restarts the countdown.",
    };

    const STYLES = [
      ".scc-config{max-width:640px;display:flex;flex-direction:column;gap:16px;color:var(--dsw-alias-label-primary)}",
      ".scc-group{border:1px solid var(--dsw-alias-border-l2);border-radius:10px;padding:14px;background:var(--dsw-alias-bg-layer-2)}",
      ".scc-group h3{margin:0 0 12px;font-size:13px;font-weight:600}",
      ".scc-field{display:flex;flex-direction:column;gap:4px;margin-bottom:10px}",
      ".scc-field label{font-size:12px;font-weight:500}",
      ".scc-field input[type=text],.scc-field input[type=number],.scc-field input[type=password],.scc-field select{height:30px;border:1px solid var(--dsw-alias-border-l2);background:var(--dsw-alias-bg-layer-1);color:var(--dsw-alias-label-primary);border-radius:6px;padding:0 8px;font:inherit;font-size:13px;box-sizing:border-box}",
      ".scc-hint{font-size:11px;color:var(--dsw-alias-label-tertiary)}",
      ".scc-switch{display:flex;align-items:center;gap:8px;margin-bottom:6px}",
      ".scc-switch input{accent-color:var(--dsw-alias-state-business-primary)}",
      ".scc-status{font-size:12px;color:var(--dsw-alias-label-tertiary);min-height:16px}",
      ".scc-status-bad{color:var(--dsw-alias-state-error-primary)}",
      ".scc-row{display:flex;gap:12px}",
      ".scc-row .scc-field{flex:1}",
      ".scc-seg{display:inline-flex;border:1px solid var(--dsw-alias-border-l2);border-radius:6px;overflow:hidden}",
      ".scc-seg-btn{height:30px;padding:0 14px;border:0;background:var(--dsw-alias-bg-layer-1);color:var(--dsw-alias-label-secondary);font:inherit;font-size:13px;cursor:pointer}",
      ".scc-seg-btn+.scc-seg-btn{border-left:1px solid var(--dsw-alias-border-l2)}",
      ".scc-seg-btn:hover{background:var(--dsw-alias-bg-layer-2)}",
      ".scc-seg-on,.scc-seg-on:hover{background:var(--dsw-alias-state-business-primary);color:#fff}",
    ].join("");

    /** 一行标签 + 控件 + 提示 */
    function Field({ label, hint, children }) {
      return h("div", { className: "scc-field" },
        h("label", null, label),
        children,
        hint ? h("div", { className: "scc-hint" }, hint) : null,
      );
    }

    /** 文本输入:本地草稿,失焦/回车时才提交 */
    function TextInput({ value, onCommit, password }) {
      const [draft, setDraft] = useState(value);
      useEffect(() => setDraft(value), [value]);
      return h("input", {
        type: password ? "password" : "text",
        value: draft,
        onChange: (e) => setDraft(e.target.value),
        onBlur: () => {
          if (draft !== value) onCommit(draft);
        },
        onKeyDown: (e) => {
          if (e.key === "Enter") e.target.blur();
        },
      });
    }

    /** 数字输入:解析失败则回退当前值 */
    function NumberInput({ value, onCommit, min, max }) {
      const [draft, setDraft] = useState(String(value ?? ""));
      useEffect(() => setDraft(String(value ?? "")), [value]);
      const commit = () => {
        const n = Number(draft);
        if (Number.isFinite(n) && n !== value) onCommit(n);
        else setDraft(String(value ?? ""));
      };
      return h("input", {
        type: "number",
        min,
        max,
        value: draft,
        onChange: (e) => setDraft(e.target.value),
        onBlur: commit,
        onKeyDown: (e) => {
          if (e.key === "Enter") e.target.blur();
        },
      });
    }

    /**
     * 分段选择(单选按钮组)。
     *
     * 这里**故意不用 `<select>`**:设置页最初用的就是 select,结果「出现位置」
     * 选了「固定坐标」却存不进去 —— 其余几个数字框都能存,唯独这一个不行。
     * 与其去猜宿主渲染层对 select 的合成事件怎么处理,不如换成最原始的一组
     * radio:每个按钮各自带一个 onClick,事件源和目标都是它自己,没有中间层。
     */
    function Segmented({ value, options, onSelect }) {
      return h(
        "div",
        { className: "scc-seg" },
        options.map((opt) =>
          h(
            "button",
            {
              key: opt.value,
              type: "button",
              className: opt.value === value ? "scc-seg-btn scc-seg-on" : "scc-seg-btn",
              onClick: () => {
                if (opt.value !== value) onSelect(opt.value);
              },
            },
            opt.label,
          ),
        ),
      );
    }

    /** 设置页:绑定 settings 命名空间,展示并保存配置 */
    function ConfigSection({ scope, t }) {
      const [snap, setSnap] = useState(() => scope.getSnapshot());
      const [status, setStatus] = useState("");
      const statusTimer = useRef(null);
      useEffect(() => scope.subscribe(() => setSnap(scope.getSnapshot())), [scope]);
      useEffect(() => () => {
        if (statusTimer.current) clearTimeout(statusTimer.current);
      }, []);
      const flash = (msg, bad = false) => {
        setStatus(bad ? `__bad__${msg}` : msg);
        if (statusTimer.current) clearTimeout(statusTimer.current);
        statusTimer.current = setTimeout(() => setStatus(""), 4000);
      };
      /**
       * 保存一个字段。
       *
       * `scope.set()` 返回的是**布尔值** —— Host 拒绝时返回 `false`,只有传输层
       * 出错才会 reject。以前这里只写了 `.then(() => flash("已保存"))`,于是
       * **失败也报「已保存」**:用户以为存上了,配置其实没变(「出现位置」选固定
       * 坐标不生效就是这么来的)。现在显式检查返回值。
       *
       * 被拒时重试一次:Host 的 `write` 会拿 `expectedRevision` 和当前 revision
       * 比对,不一致就抛 `SETTINGS_CONFLICT`。而 revision 的种子里含
       * `fiber.uid` —— **插件每重载一次 revision 就 +1**,客户端镜像随即过期。
       * 控制器在拒绝后会自己 `mirror.load()` 把 revision 拉新,所以紧接着再写
       * 一次就能成功。不重试的话,用户得手动再点一遍才有反应。
       */
      const save = (field, v) => {
        const attempt = (retry) => {
          Promise.resolve(scope.set(field, v))
            .then((ok) => {
              if (ok !== false) {
                flash(t("saved"));
                return;
              }
              if (retry) {
                attempt(false);
                return;
              }
              flash(`${t("error")} ${t("rejected")}`, true);
            })
            .catch((err) => {
              if (retry) {
                attempt(false);
                return;
              }
              flash(`${t("error")} ${err && err.message ? err.message : String(err)}`, true);
            });
        };
        attempt(true);
      };

      if (snap.status === "loading") return h("p", { className: "scc-status" }, t("loading"));
      if (snap.status === "unavailable") return h("p", { className: "scc-status" }, t("unavailable"));
      const v = snap.value || {};

      return h("div", { className: "scc-config" }, [
        h("div", { className: "scc-group" }, [
          h("h3", null, t("general")),
          h("div", { className: "scc-switch" }, [
            h("input", {
              type: "checkbox",
              id: "scc-enabled",
              checked: !!v.enabled,
              onChange: (e) => save("enabled", e.target.checked),
            }),
            h("label", { htmlFor: "scc-enabled" }, t("enabled")),
          ]),
          h("div", { className: "scc-hint" }, t("enabledHint")),
          Field({
            label: t("vaultPath"),
            hint: t("vaultPathHint"),
            children: h(TextInput, { value: v.vaultPath || "", onCommit: (val) => save("vaultPath", val) }),
          }),
          h("div", { className: "scc-row" }, [
            Field({
              label: t("pollIntervalMs"),
              children: h(NumberInput, { value: v.pollIntervalMs, min: 50, max: 60000, onCommit: (n) => save("pollIntervalMs", n) }),
            }),
            Field({
              label: t("cooldownMs"),
              children: h(NumberInput, { value: v.cooldownMs, min: 0, max: 120000, onCommit: (n) => save("cooldownMs", n) }),
            }),
          ]),
        ]),
        h("div", { className: "scc-group" }, [
          h("h3", null, t("ocr")),
          Field({
            label: t("ocrMode"),
            children: h(Segmented, {
              value: v.ocrMode || "host",
              options: [
                { value: "host", label: t("ocrModeHost") },
                { value: "off", label: t("ocrModeOff") },
              ],
              onSelect: (val) => save("ocrMode", val),
            }),
          }),
          Field({
            label: t("ocrHostModel"),
            hint: t("ocrHostModelHint"),
            children: h(TextInput, { value: v.ocrHostModel || "", onCommit: (val) => save("ocrHostModel", val) }),
          }),
          h("div", { className: "scc-hint" }, t("ocrFallbackHint")),
        ]),
        h("div", { className: "scc-group" }, [
          h("h3", null, t("dialog")),
          Field({
            label: t("dialogPositionMode"),
            hint: t("dialogPositionModeHint"),
            children: h(Segmented, {
              value: v.dialogPositionMode || "cursor",
              options: [
                { value: "cursor", label: t("dialogPositionCursor") },
                { value: "fixed", label: t("dialogPositionFixed") },
                { value: "remember", label: t("dialogPositionRemember") },
              ],
              onSelect: (val) => save("dialogPositionMode", val),
            }),
          }),
          (v.dialogPositionMode || "cursor") === "remember"
            ? h("div", { className: "scc-hint" }, t("dialogRememberHint"))
            : null,
          (v.dialogPositionMode || "cursor") === "fixed"
            ? h("div", { className: "scc-row" }, [
                Field({
                  label: t("dialogFixedX"),
                  children: h(NumberInput, { value: v.dialogFixedX, min: -20000, max: 20000, onCommit: (n) => save("dialogFixedX", n) }),
                }),
                Field({
                  label: t("dialogFixedY"),
                  children: h(NumberInput, { value: v.dialogFixedY, min: -20000, max: 20000, onCommit: (n) => save("dialogFixedY", n) }),
                }),
              ])
            : (v.dialogPositionMode || "cursor") === "cursor"
              ? h("div", { className: "scc-row" }, [
                  Field({
                    label: t("dialogOffsetX"),
                    children: h(NumberInput, { value: v.dialogOffsetX, min: -1000, max: 1000, onCommit: (n) => save("dialogOffsetX", n) }),
                  }),
                  Field({
                    label: t("dialogOffsetY"),
                    children: h(NumberInput, { value: v.dialogOffsetY, min: -1000, max: 1000, onCommit: (n) => save("dialogOffsetY", n) }),
                  }),
                ])
              : null,
          (v.dialogPositionMode || "cursor") === "remember"
            ? null
            : h("div", { className: "scc-row" }, [
                Field({
                  label: t("dialogWidth"),
                  hint: t("dialogSizeHint"),
                  children: h(NumberInput, { value: v.dialogWidth, min: 0, max: 4000, onCommit: (n) => save("dialogWidth", n) }),
                }),
                Field({
                  label: t("dialogHeight"),
                  children: h(NumberInput, { value: v.dialogHeight, min: 0, max: 4000, onCommit: (n) => save("dialogHeight", n) }),
                }),
              ]),
          (v.dialogPositionMode || "cursor") === "remember"
            ? h("div", { className: "scc-hint" }, t("dialogSizeRememberHint"))
            : null,
          Field({
            label: t("dialogPreviewMaxWidth"),
            hint: t("dialogPreviewMaxWidthHint"),
            children: h(NumberInput, { value: v.dialogPreviewMaxWidth, min: 100, max: 2000, onCommit: (n) => save("dialogPreviewMaxWidth", n) }),
          }),
          Field({
            label: t("dialogAutoCloseSec"),
            hint: t("dialogAutoCloseHint"),
            children: h(NumberInput, { value: v.dialogAutoCloseSec, min: 0, max: 3600, onCommit: (n) => save("dialogAutoCloseSec", n) }),
          }),
        ]),
        h(
          "div",
          { className: status.startsWith("__bad__") ? "scc-status scc-status-bad" : "scc-status" },
          status.startsWith("__bad__") ? status.slice(7) : status,
        ),
      ]);
    }

    function apply(ctx) {
      ctx.effect(() => {
        const tag = document.createElement("style");
        tag.setAttribute("data-plugin", "dsh-screenshot-capture");
        tag.textContent = STYLES;
        document.head.appendChild(tag);
        return () => {
          if (tag.parentNode) tag.parentNode.removeChild(tag);
        };
      }, "dsh-screenshot-capture: styles");

      ctx.effect(() => {
        return ctx.locale.register(NS, { zh, en });
      }, "dsh-screenshot-capture: dictionaries");

      const t = ctx.locale.bind(NS);
      // DSH 0.1.7:客户端设置服务由 settingsScope(每插件各自 bind 一份视图)换成了
      // configForms(全体共用一份 Host 设置文档镜像)。get(entryId) 的 entryId 就是
      // host 条目 id。返回的 ConfigFormController 与旧 scope 方法同签名
      // (getSnapshot / subscribe / set),所以下面的组件体一行都不用改。
      const scope = ctx.configForms.get(SETTINGS_NAMESPACE);
      const injected = () => ({ scope });

      ctx.slots.inject("settings.section", () => ctx.slots.register({
        name: "settings.section",
        id: "screenshot-capture",
        order: 200,
        label: () => t("nav"),
        locale: NS,
        inject: injected,
      }, ConfigSection));
    }

    module.exports = {
      name: "dsh-screenshot-capture",
      inject: ["slots", "locale", "configForms"],
      apply,
    };
    return module.exports;
  },
});
