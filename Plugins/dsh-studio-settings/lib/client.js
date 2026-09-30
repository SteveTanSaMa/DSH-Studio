window.__ModuleLoader__.load({id:"dsh-studio-settings",factory:(require)=>{var module={exports:{}};var exports=module.exports;
var __create = Object.create;
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __getProtoOf = Object.getPrototypeOf;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __export = (target, all) => {
  for (var name in all)
    __defProp(target, name, { get: all[name], enumerable: true });
};
var __copyProps = (to, from, except, desc) => {
  if (from && typeof from === "object" || typeof from === "function") {
    for (let key of __getOwnPropNames(from))
      if (!__hasOwnProp.call(to, key) && key !== except)
        __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
  }
  return to;
};
var __toESM = (mod, isNodeMode, target) => (target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(
  // If the importer is in node compatibility mode or this is not an ESM
  // file that has been converted to a CommonJS file using a Babel-
  // compatible transform (i.e. "__esModule" has not been set), then set
  // "default" to the CommonJS "module.exports" for node compatibility.
  isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target,
  mod
));
var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

// src/client.jsx
var client_exports = {};
__export(client_exports, {
  apply: () => apply,
  inject: () => inject
});
module.exports = __toCommonJS(client_exports);

// src/preferences.js
var namespace = "dsh-studio";
var defaults = Object.freeze({
  chatContentMaxWidth: 1e3,
  turnCompletionNotification: "whenNotFocused",
  permissionNotificationsEnabled: true,
  questionNotificationsEnabled: true
});
var preferenceKeys = Object.freeze([
  ...Object.keys(defaults),
  "workspacePath"
]);
function validatePreference(key, value) {
  switch (key) {
    case "chatContentMaxWidth":
      return typeof value === "number" && Number.isFinite(value) && value >= 748 && value <= 2400;
    case "turnCompletionNotification":
      return ["never", "always", "whenNotFocused"].includes(value);
    case "permissionNotificationsEnabled":
    case "questionNotificationsEnabled":
      return typeof value === "boolean";
    case "workspacePath":
      return typeof value === "string" && value.startsWith("/") && !value.includes("\0") && value.trim().length > 0;
    default:
      return false;
  }
}

// src/config-transport.js
function createConfigTransport(configForms) {
  if (typeof configForms?.get !== "function" || typeof configForms?.describe !== "function") {
    throw new Error("The Harness configuration form service is unavailable");
  }
  const form = configForms.get(namespace);
  const mirror = configForms.describe();
  let disposed = false;
  let tail = Promise.resolve();
  function assertActive() {
    if (disposed) throw new Error("DSH Studio settings connection has closed");
  }
  async function describe() {
    assertActive();
    await mirror.ensure();
    assertActive();
    const snapshot = mirror.getSnapshot();
    if (snapshot.status !== "ready" || !snapshot.view || snapshot.error) {
      throw new Error(snapshot.error || "Harness settings are unavailable");
    }
    return structuredClone(snapshot.view);
  }
  function mutate(ns, operations, expectedRevision) {
    if (ns !== namespace || !Number.isSafeInteger(expectedRevision) || expectedRevision < 0) {
      return Promise.reject(new TypeError("Invalid DSH Studio settings mutation"));
    }
    const owned = structuredClone(operations);
    const pending2 = tail.then(async () => {
      assertActive();
      const before = form.getSnapshot();
      if (before.status !== "ready" || !before.writable || before.mode !== "host") {
        throw new Error("Harness settings are not writable");
      }
      if (before.revision !== expectedRevision) {
        throw new Error("Harness settings changed; reload before saving");
      }
      const accepted = await form.mutate(owned, expectedRevision);
      assertActive();
      if (accepted !== true) throw new Error("Harness did not accept the settings change");
      const document2 = await describe();
      const committed = document2.namespaces.find((section) => section.ns === namespace);
      if (!committed || committed.revision <= expectedRevision) {
        throw new Error("Harness did not publish the settings change");
      }
      return committed;
    });
    tail = pending2.catch(() => {
    });
    return pending2;
  }
  return Object.freeze({
    describe,
    mutate,
    getSnapshot: () => form.getSnapshot(),
    subscribe: (listener) => {
      assertActive();
      return form.subscribe(listener);
    },
    async set(key, value, expectedRevision) {
      if (!validatePreference(key, value)) throw new TypeError("Invalid DSH Studio preference");
      return mutate(namespace, [{ op: "set", path: [key], value }], expectedRevision);
    },
    dispose() {
      disposed = true;
    }
  });
}

// src/locales.js
var localeNamespace = "dsh-studio.settings";
var en = {
  nav: "DSH Studio",
  intro: "DSH Studio owns these settings. Everything else in this dialog belongs to Harness.",
  conversation: "Conversation",
  width: "Content width",
  widthHint: "Maximum width of the conversation column, in pixels.",
  invalidWidth: "Enter a number between 748 and 2400.",
  notifications: "Notifications",
  completion: "Turn completed",
  completionHint: "When DSH Studio should raise a system notification for a finished turn.",
  never: "Never",
  always: "Always",
  whenNotFocused: "When not focused",
  permissions: "Permission requests",
  permissionsHint: "Notify when Harness waits for a permission decision.",
  questions: "Questions",
  questionsHint: "Notify when Harness waits for an answer.",
  workspace: "Workspace",
  workspacePath: "Workspace folder",
  workspaceHint: "Harness starts against this folder. Changing it restarts Harness.",
  workspaceUnknown: "Not selected yet",
  choose: "Choose",
  profiles: "Harness Profile",
  profileTitle: "Composition profile",
  profilesHint: "A profile selects which Harness bundles start. Switching restarts Harness.",
  profilesEmpty: "No other profile on this Mac yet.",
  active: "Active",
  unusable: "Unusable",
  select: "Switch",
  delete: "Delete",
  confirmDelete: "Confirm delete",
  cancel: "Cancel",
  create: "Create",
  refresh: "Refresh",
  profileName: "New profile name",
  profileNameHint: "A new profile starts from the same DSH data as the current one.",
  maintenance: "Maintenance",
  runtimeTitle: "Runtime",
  runtimeHint: "Check for a verified Runtime update, or restore the previous build.",
  runtimeSummary: "Installed Runtime {runtime}, available {available}.",
  checkRuntime: "Check",
  updateRuntime: "Apply update",
  rollbackRuntime: "Restore previous",
  unknown: "unknown",
  presetTitle: "Agent Presets",
  presetHint: "Move user-authored Presets between DSH Studio installations.",
  importPreset: "Import Preset",
  exportPreset: "Export Preset",
  localTitle: "Local folders",
  localHint: "Open a terminal scoped to this Runtime, or reveal the app-owned folders.",
  terminal: "Open terminal",
  dataFolder: "Data folder",
  logs: "Open logs",
  diagnosticsTitle: "Diagnostics",
  diagnosticsHint: "Copy a redacted summary, or export a bundle for a bug report.",
  copyDiagnostics: "Copy diagnostics",
  exportDiagnostics: "Export bundle",
  loading: "Loading settings...",
  unavailable: "Studio settings are unavailable.",
  readOnly: "These settings are read-only.",
  operationFailed: "The operation failed. Try again."
};
var zh = {
  nav: "DSH Studio",
  intro: "\u8FD9\u4E9B\u8BBE\u7F6E\u7531 DSH Studio \u7BA1\u7406\uFF0C\u6B64\u5BF9\u8BDD\u6846\u4E2D\u7684\u5176\u4ED6\u8BBE\u7F6E\u5C5E\u4E8E Harness\u3002",
  conversation: "\u5BF9\u8BDD",
  width: "\u5185\u5BB9\u5BBD\u5EA6",
  widthHint: "\u5BF9\u8BDD\u6B63\u6587\u7684\u6700\u5927\u5BBD\u5EA6\uFF0C\u5355\u4F4D\u4E3A\u50CF\u7D20\u3002",
  invalidWidth: "\u8BF7\u8F93\u5165 748 \u5230 2400 \u4E4B\u95F4\u7684\u6570\u503C\u3002",
  notifications: "\u901A\u77E5",
  completion: "\u4EFB\u52A1\u5B8C\u6210",
  completionHint: "\u4F55\u65F6\u4E3A\u5B8C\u6210\u7684\u5BF9\u8BDD\u53D1\u9001\u7CFB\u7EDF\u901A\u77E5\u3002",
  never: "\u4ECE\u4E0D",
  always: "\u59CB\u7EC8",
  whenNotFocused: "\u5E94\u7528\u672A\u805A\u7126\u65F6",
  permissions: "\u6743\u9650\u8BF7\u6C42",
  permissionsHint: "Harness \u7B49\u5F85\u6743\u9650\u786E\u8BA4\u65F6\u901A\u77E5\u3002",
  questions: "\u95EE\u9898",
  questionsHint: "Harness \u7B49\u5F85\u56DE\u7B54\u65F6\u901A\u77E5\u3002",
  workspace: "\u5DE5\u4F5C\u533A",
  workspacePath: "\u5DE5\u4F5C\u533A\u6587\u4EF6\u5939",
  workspaceHint: "Harness \u5728\u8BE5\u6587\u4EF6\u5939\u4E2D\u542F\u52A8\uFF0C\u5207\u6362\u540E\u4F1A\u91CD\u542F Harness\u3002",
  workspaceUnknown: "\u5C1A\u672A\u9009\u62E9",
  choose: "\u9009\u62E9",
  profiles: "Harness Profile",
  profileTitle: "\u7EC4\u5408 Profile",
  profilesHint: "Profile \u51B3\u5B9A\u542F\u52A8\u54EA\u4E9B Harness \u7EC4\u4EF6\uFF0C\u5207\u6362\u540E\u4F1A\u91CD\u542F Harness\u3002",
  profilesEmpty: "\u6B64 Mac \u4E0A\u8FD8\u6CA1\u6709\u5176\u4ED6 Profile\u3002",
  active: "\u5F53\u524D\u4F7F\u7528",
  unusable: "\u4E0D\u53EF\u7528",
  select: "\u5207\u6362",
  delete: "\u5220\u9664",
  confirmDelete: "\u786E\u8BA4\u5220\u9664",
  cancel: "\u53D6\u6D88",
  create: "\u521B\u5EFA",
  refresh: "\u5237\u65B0",
  profileName: "\u65B0 Profile \u540D\u79F0",
  profileNameHint: "\u65B0 Profile \u4E0E\u5F53\u524D Profile \u4F7F\u7528\u540C\u4E00\u4EFD DSH \u6570\u636E\u3002",
  maintenance: "\u7EF4\u62A4",
  runtimeTitle: "Runtime",
  runtimeHint: "\u68C0\u67E5\u5DF2\u9A8C\u8BC1\u7684 Runtime \u66F4\u65B0\uFF0C\u6216\u6062\u590D\u4E0A\u4E00\u4E2A\u6784\u5EFA\u3002",
  runtimeSummary: "\u5DF2\u5B89\u88C5 Runtime {runtime}\uFF0C\u53EF\u7528 {available}\u3002",
  checkRuntime: "\u68C0\u67E5",
  updateRuntime: "\u5E94\u7528\u66F4\u65B0",
  rollbackRuntime: "\u6062\u590D\u4E0A\u4E00\u7248",
  unknown: "\u672A\u77E5",
  presetTitle: "Agent Preset",
  presetHint: "\u5728\u672C\u5730 DSH Studio \u5B89\u88C5\u4E4B\u95F4\u8FC1\u79FB\u7528\u6237\u521B\u5EFA\u7684 Preset\u3002",
  importPreset: "\u5BFC\u5165 Preset",
  exportPreset: "\u5BFC\u51FA Preset",
  localTitle: "\u672C\u5730\u6587\u4EF6\u5939",
  localHint: "\u6253\u5F00\u7ED1\u5B9A\u6B64 Runtime \u7684\u7EC8\u7AEF\uFF0C\u6216\u5B9A\u4F4D\u5E94\u7528\u7BA1\u7406\u7684\u6587\u4EF6\u5939\u3002",
  terminal: "\u6253\u5F00\u7EC8\u7AEF",
  dataFolder: "\u6570\u636E\u6587\u4EF6\u5939",
  logs: "\u6253\u5F00\u65E5\u5FD7",
  diagnosticsTitle: "\u8BCA\u65AD",
  diagnosticsHint: "\u590D\u5236\u8131\u654F\u6458\u8981\uFF0C\u6216\u5BFC\u51FA\u8BCA\u65AD\u5305\u7528\u4E8E\u53CD\u9988\u95EE\u9898\u3002",
  copyDiagnostics: "\u590D\u5236\u8BCA\u65AD\u4FE1\u606F",
  exportDiagnostics: "\u5BFC\u51FA\u8BCA\u65AD\u5305",
  loading: "\u6B63\u5728\u52A0\u8F7D\u8BBE\u7F6E...",
  unavailable: "\u6682\u65F6\u65E0\u6CD5\u83B7\u53D6 Studio \u8BBE\u7F6E\u3002",
  readOnly: "\u5F53\u524D\u8BBE\u7F6E\u4E3A\u53EA\u8BFB\u3002",
  operationFailed: "\u64CD\u4F5C\u5931\u8D25\uFF0C\u8BF7\u91CD\u8BD5\u3002"
};

// src/native-actions.js
var sequence = 0;
var pending = /* @__PURE__ */ new Map();
function receive(reply) {
  const request = pending.get(reply?.requestId);
  if (!request) return;
  pending.delete(reply.requestId);
  clearTimeout(request.timer);
  if (reply.ok) request.resolve(reply.result);
  else request.reject(new Error(reply.error || "Native operation failed"));
}
if (typeof window !== "undefined") {
  window.__dshStudioReceive = receive;
}
function nativeAction(action, payload = {}) {
  const handler = globalThis.window?.webkit?.messageHandlers?.deepseekStudio;
  if (!handler) return Promise.reject(new Error("DSH Studio native bridge unavailable"));
  const requestId = `studio-${Date.now()}-${++sequence}`;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(requestId);
      reject(new Error("Native operation timed out"));
    }, 3e4);
    pending.set(requestId, { resolve, reject, timer });
    handler.postMessage({ type: "dshStudio.action", action, payload, requestId });
  });
}

// src/registration.js
function registerStudioSection(ctx, component) {
  const transport = createConfigTransport(ctx.configForms);
  ctx.effect(() => () => {
    transport.dispose();
  });
  ctx.effect(() => ctx.locale.register(localeNamespace, { en, zh }));
  const t = ctx.locale.bind(localeNamespace);
  ctx.slots.inject("settings.section", () => ctx.configForms.whileServed([namespace], () => ctx.slots.register({
    name: "settings.section",
    id: namespace,
    order: 100,
    label: () => t("nav"),
    locale: localeNamespace,
    inject: () => ({ transport, nativeAction })
  }, component)));
  return transport;
}

// src/StudioSection.jsx
var import_react = __toESM(require("react"), 1);
var import_dsh_client_ui_primitives = require("@deepseek-ai/dsh-client-ui-primitives");

// src/width-spec.js
var contentWidthRange = Object.freeze({ min: 748, max: 2400 });
function parseContentWidth(text, range = contentWidthRange) {
  const trimmed = String(text ?? "").trim();
  if (trimmed === "") return void 0;
  const value = Number(trimmed);
  if (!Number.isFinite(value) || value < range.min || value > range.max) return void 0;
  return value;
}

// src/StudioSection.jsx
function Row({ title, hint, invalid, children }) {
  return /* @__PURE__ */ import_react.default.createElement("div", { className: "dshStudioRow" }, /* @__PURE__ */ import_react.default.createElement("div", { className: "dshStudioRowText" }, /* @__PURE__ */ import_react.default.createElement("div", { className: "dshStudioRowTitle" }, title), hint ? /* @__PURE__ */ import_react.default.createElement("div", { className: invalid ? "dshStudioRowHint dshStudioRowHintInvalid" : "dshStudioRowHint" }, hint) : null), /* @__PURE__ */ import_react.default.createElement("div", { className: "dshStudioRowControl" }, children));
}
function StudioSection({ transport, nativeAction: nativeAction2, t }) {
  const snapshot = (0, import_react.useSyncExternalStore)(
    transport.subscribe,
    transport.getSnapshot,
    transport.getSnapshot
  );
  const [widthDraft, setWidthDraft] = (0, import_react.useState)(null);
  const [widthRefused, setWidthRefused] = (0, import_react.useState)(false);
  const [busy, setBusy] = (0, import_react.useState)(false);
  const [failed, setFailed] = (0, import_react.useState)(false);
  const [profiles, setProfiles] = (0, import_react.useState)(null);
  const [profileName, setProfileName] = (0, import_react.useState)("");
  const [pendingDelete, setPendingDelete] = (0, import_react.useState)("");
  const [completionOpen, setCompletionOpen] = (0, import_react.useState)(false);
  const [operation, setOperation] = (0, import_react.useState)("");
  const [runtimeStatus, setRuntimeStatus] = (0, import_react.useState)(null);
  const value = snapshot.status === "ready" ? snapshot.value : void 0;
  const writable = snapshot.writable && snapshot.mode === "host";
  const disabled = busy || !writable;
  const completionOptions = ["whenNotFocused", "always", "never"];
  const save = async (key, next) => {
    setFailed(false);
    setBusy(true);
    try {
      await transport.set(key, next, snapshot.revision);
      await nativeAction2("preference.sync", { key, value: next }).catch(() => void 0);
    } catch {
      setFailed(true);
    } finally {
      setBusy(false);
    }
  };
  const mirrorWorkspacePath = async (path) => {
    if (!path) return;
    try {
      const document2 = await transport.describe();
      const section = document2.namespaces.find((item) => item.ns === namespace);
      if (!section || section.value?.workspacePath === path) return;
      await transport.set("workspacePath", path, section.revision);
    } catch {
      return;
    }
  };
  const run = async (action, payload = {}) => {
    setFailed(false);
    setOperation(action);
    try {
      const result = await nativeAction2(action, payload);
      if (action === "profile.list") setProfiles(result);
      if (action === "runtime.check") setRuntimeStatus(result);
      if (action === "workspace.choose" && result?.changed) {
        await mirrorWorkspacePath(result.workspacePath);
      }
      return result;
    } catch {
      setFailed(true);
      return void 0;
    } finally {
      setOperation("");
    }
  };
  if (snapshot.status !== "ready" || !value) {
    return /* @__PURE__ */ import_react.default.createElement("section", { className: "dshStudioSection", "aria-label": t("nav") }, /* @__PURE__ */ import_react.default.createElement("h2", { className: "dshStudioHeading" }, t("nav")), /* @__PURE__ */ import_react.default.createElement("p", { className: "dshStudioNotice", role: "status" }, t(snapshot.status === "loading" ? "loading" : "unavailable")));
  }
  const applyProfileChange = async (action, payload) => {
    const result = await run(action, payload);
    setPendingDelete("");
    if (result) {
      setProfileName("");
      await run("profile.list");
    }
  };
  const committedWidth = value.chatContentMaxWidth;
  const widthText = widthDraft ?? String(committedWidth);
  const widthEntered = widthDraft !== null && widthDraft.trim() !== "";
  const widthInvalid = widthEntered && parseContentWidth(widthDraft) === void 0;
  const editWidth = (text) => {
    setWidthDraft(text);
    setWidthRefused(false);
  };
  const commitWidth = () => {
    if (widthDraft === null) return;
    const width = parseContentWidth(widthDraft);
    setWidthDraft(null);
    setWidthRefused(widthEntered && width === void 0);
    if (width === void 0 || width === committedWidth) return;
    void save("chatContentMaxWidth", width);
  };
  return /* @__PURE__ */ import_react.default.createElement("section", { className: "dshStudioSection", "aria-label": t("nav") }, /* @__PURE__ */ import_react.default.createElement("h2", { className: "dshStudioHeading" }, t("nav")), /* @__PURE__ */ import_react.default.createElement("p", { className: "dshStudioIntro" }, t("intro")), failed && /* @__PURE__ */ import_react.default.createElement("p", { className: "dshStudioError", role: "alert" }, t("operationFailed")), !writable && /* @__PURE__ */ import_react.default.createElement("p", { className: "dshStudioNotice", role: "status" }, t("readOnly")), /* @__PURE__ */ import_react.default.createElement("div", { className: "dshStudioGroup" }, /* @__PURE__ */ import_react.default.createElement("h3", { className: "dshStudioGroupHead" }, t("conversation")), /* @__PURE__ */ import_react.default.createElement("div", { className: "dshStudioRows" }, /* @__PURE__ */ import_react.default.createElement(
    Row,
    {
      title: t("width"),
      hint: widthInvalid || widthRefused ? t("invalidWidth") : t("widthHint"),
      invalid: widthInvalid || widthRefused
    },
    /* @__PURE__ */ import_react.default.createElement(
      "input",
      {
        id: "dsh-studio-content-width",
        className: "dshStudioNumber dshStudioNumberWidth",
        type: "text",
        inputMode: "numeric",
        "aria-label": t("width"),
        "aria-invalid": widthInvalid || void 0,
        disabled,
        value: widthText,
        onChange: (event) => {
          editWidth(event.target.value);
        },
        onBlur: commitWidth,
        onKeyDown: (event) => {
          if (event.key !== "Enter") return;
          commitWidth();
        }
      }
    )
  ))), /* @__PURE__ */ import_react.default.createElement("div", { className: "dshStudioGroup" }, /* @__PURE__ */ import_react.default.createElement("h3", { className: "dshStudioGroupHead" }, t("notifications")), /* @__PURE__ */ import_react.default.createElement("div", { className: "dshStudioRows" }, /* @__PURE__ */ import_react.default.createElement(Row, { title: t("completion"), hint: t("completionHint") }, /* @__PURE__ */ import_react.default.createElement(
    import_dsh_client_ui_primitives.Menu,
    {
      open: completionOpen,
      onClose: () => {
        setCompletionOpen(false);
      },
      items: completionOptions.map((option) => ({ id: option, label: t(option) })),
      selectedId: value.turnCompletionNotification,
      onSelect: (option) => {
        setCompletionOpen(false);
        void save("turnCompletionNotification", option);
      },
      align: "end",
      portal: true,
      anchor: /* @__PURE__ */ import_react.default.createElement(
        "button",
        {
          type: "button",
          className: "dshStudioSelector",
          disabled,
          "aria-haspopup": "menu",
          "aria-expanded": completionOpen,
          "aria-label": t("completion"),
          onClick: () => {
            setCompletionOpen((open) => !open);
          }
        },
        t(value.turnCompletionNotification),
        /* @__PURE__ */ import_react.default.createElement(import_dsh_client_ui_primitives.IconChevronDownOutlineRegular, { className: "dshStudioChevron" })
      )
    }
  )), /* @__PURE__ */ import_react.default.createElement(Row, { title: t("permissions"), hint: t("permissionsHint") }, /* @__PURE__ */ import_react.default.createElement(
    import_dsh_client_ui_primitives.Switch,
    {
      checked: value.permissionNotificationsEnabled,
      disabled,
      label: t("permissions"),
      onChange: (next) => {
        void save("permissionNotificationsEnabled", next);
      }
    }
  )), /* @__PURE__ */ import_react.default.createElement(Row, { title: t("questions"), hint: t("questionsHint") }, /* @__PURE__ */ import_react.default.createElement(
    import_dsh_client_ui_primitives.Switch,
    {
      checked: value.questionNotificationsEnabled,
      disabled,
      label: t("questions"),
      onChange: (next) => {
        void save("questionNotificationsEnabled", next);
      }
    }
  )))), /* @__PURE__ */ import_react.default.createElement("div", { className: "dshStudioGroup" }, /* @__PURE__ */ import_react.default.createElement("h3", { className: "dshStudioGroupHead" }, t("workspace")), /* @__PURE__ */ import_react.default.createElement("div", { className: "dshStudioRows" }, /* @__PURE__ */ import_react.default.createElement("div", { className: "dshStudioRow" }, /* @__PURE__ */ import_react.default.createElement("div", { className: "dshStudioRowText" }, /* @__PURE__ */ import_react.default.createElement("div", { className: "dshStudioRowTitle" }, t("workspacePath")), /* @__PURE__ */ import_react.default.createElement(
    import_dsh_client_ui_primitives.PathLabel,
    {
      className: "dshStudioPath",
      path: value.workspacePath ?? t("workspaceUnknown")
    }
  ), /* @__PURE__ */ import_react.default.createElement("div", { className: "dshStudioRowHint" }, t("workspaceHint"))), /* @__PURE__ */ import_react.default.createElement("div", { className: "dshStudioRowControl" }, /* @__PURE__ */ import_react.default.createElement(
    import_dsh_client_ui_primitives.Button,
    {
      variant: "outline",
      size: "sm",
      disabled: !!operation,
      onClick: () => {
        void run("workspace.choose");
      }
    },
    t("choose")
  ))))), /* @__PURE__ */ import_react.default.createElement("div", { className: "dshStudioGroup" }, /* @__PURE__ */ import_react.default.createElement("h3", { className: "dshStudioGroupHead" }, t("profiles")), /* @__PURE__ */ import_react.default.createElement("div", { className: "dshStudioRows" }, /* @__PURE__ */ import_react.default.createElement(Row, { title: t("profileTitle"), hint: t("profilesHint") }, /* @__PURE__ */ import_react.default.createElement(
    import_dsh_client_ui_primitives.Button,
    {
      variant: "outline",
      size: "sm",
      disabled: !!operation,
      onClick: () => {
        void run("profile.list");
      }
    },
    t("refresh")
  )), (profiles?.profiles ?? []).map((profile) => /* @__PURE__ */ import_react.default.createElement("div", { className: "dshStudioRow", key: profile.name }, /* @__PURE__ */ import_react.default.createElement("div", { className: "dshStudioRowText" }, /* @__PURE__ */ import_react.default.createElement("div", { className: "dshStudioProfileName" }, /* @__PURE__ */ import_react.default.createElement("span", { className: "dshStudioRowTitle" }, profile.name), profile.name === profiles.active && /* @__PURE__ */ import_react.default.createElement(import_dsh_client_ui_primitives.Tag, { tone: "solid" }, t("active")), !profile.selectable && /* @__PURE__ */ import_react.default.createElement(import_dsh_client_ui_primitives.Tag, { tone: "warning" }, t("unusable"))), profile.problem ? /* @__PURE__ */ import_react.default.createElement("div", { className: "dshStudioProfileDetail" }, profile.problem) : null), /* @__PURE__ */ import_react.default.createElement("div", { className: "dshStudioRowControl" }, pendingDelete === profile.name ? /* @__PURE__ */ import_react.default.createElement(import_react.default.Fragment, null, /* @__PURE__ */ import_react.default.createElement(
    import_dsh_client_ui_primitives.Button,
    {
      variant: "outline",
      size: "sm",
      disabled: !!operation,
      onClick: () => {
        void applyProfileChange("profile.delete", { name: profile.name });
      }
    },
    t("confirmDelete")
  ), /* @__PURE__ */ import_react.default.createElement(
    import_dsh_client_ui_primitives.Button,
    {
      variant: "ghost",
      size: "sm",
      disabled: !!operation,
      onClick: () => {
        setPendingDelete("");
      }
    },
    t("cancel")
  )) : /* @__PURE__ */ import_react.default.createElement(import_react.default.Fragment, null, /* @__PURE__ */ import_react.default.createElement(
    import_dsh_client_ui_primitives.Button,
    {
      variant: "outline",
      size: "sm",
      disabled: !!operation || profile.name === profiles.active || !profile.selectable,
      onClick: () => {
        void applyProfileChange("profile.select", { name: profile.name });
      }
    },
    t("select")
  ), /* @__PURE__ */ import_react.default.createElement(
    import_dsh_client_ui_primitives.Button,
    {
      variant: "ghost",
      size: "sm",
      disabled: !!operation,
      onClick: () => {
        setPendingDelete(profile.name);
      }
    },
    t("delete")
  ))))), profiles !== null && profiles.profiles.length === 0 && /* @__PURE__ */ import_react.default.createElement(Row, { title: t("profilesEmpty") }), /* @__PURE__ */ import_react.default.createElement(Row, { title: t("create"), hint: t("profileNameHint") }, /* @__PURE__ */ import_react.default.createElement(
    import_dsh_client_ui_primitives.Input,
    {
      className: "dshStudioName",
      value: profileName,
      placeholder: t("profileName"),
      "aria-label": t("profileName"),
      disabled: !!operation,
      onChange: (event) => {
        setProfileName(event.currentTarget.value);
      }
    }
  ), /* @__PURE__ */ import_react.default.createElement(
    import_dsh_client_ui_primitives.Button,
    {
      variant: "outline",
      size: "sm",
      disabled: !!operation || !profileName.trim(),
      onClick: () => {
        void applyProfileChange("profile.create", { name: profileName.trim() });
      }
    },
    t("create")
  )))), /* @__PURE__ */ import_react.default.createElement("div", { className: "dshStudioGroup" }, /* @__PURE__ */ import_react.default.createElement("h3", { className: "dshStudioGroupHead" }, t("maintenance")), /* @__PURE__ */ import_react.default.createElement("div", { className: "dshStudioRows" }, /* @__PURE__ */ import_react.default.createElement(
    Row,
    {
      title: t("runtimeTitle"),
      hint: runtimeStatus === null ? t("runtimeHint") : t("runtimeSummary").replace("{runtime}", runtimeStatus.runtimeVersion ?? t("unknown")).replace("{available}", runtimeStatus.availableVersion ?? t("unknown"))
    },
    /* @__PURE__ */ import_react.default.createElement(
      import_dsh_client_ui_primitives.Button,
      {
        variant: "outline",
        size: "sm",
        disabled: !!operation,
        onClick: () => {
          void run("runtime.check");
        }
      },
      t("checkRuntime")
    ),
    /* @__PURE__ */ import_react.default.createElement(
      import_dsh_client_ui_primitives.Button,
      {
        variant: "outline",
        size: "sm",
        disabled: !!operation || runtimeStatus?.updateAvailable !== true,
        onClick: () => {
          void run("runtime.update");
        }
      },
      t("updateRuntime")
    ),
    /* @__PURE__ */ import_react.default.createElement(
      import_dsh_client_ui_primitives.Button,
      {
        variant: "outline",
        size: "sm",
        disabled: !!operation || runtimeStatus?.rollbackAvailable !== true,
        onClick: () => {
          void run("runtime.rollback");
        }
      },
      t("rollbackRuntime")
    )
  ), /* @__PURE__ */ import_react.default.createElement(Row, { title: t("presetTitle"), hint: t("presetHint") }, /* @__PURE__ */ import_react.default.createElement(
    import_dsh_client_ui_primitives.Button,
    {
      variant: "outline",
      size: "sm",
      disabled: !!operation,
      onClick: () => {
        void run("preset.import");
      }
    },
    t("importPreset")
  ), /* @__PURE__ */ import_react.default.createElement(
    import_dsh_client_ui_primitives.Button,
    {
      variant: "outline",
      size: "sm",
      disabled: !!operation,
      onClick: () => {
        void run("preset.export");
      }
    },
    t("exportPreset")
  )), /* @__PURE__ */ import_react.default.createElement(Row, { title: t("localTitle"), hint: t("localHint") }, /* @__PURE__ */ import_react.default.createElement(
    import_dsh_client_ui_primitives.Button,
    {
      variant: "outline",
      size: "sm",
      disabled: !!operation,
      onClick: () => {
        void run("terminal.open");
      }
    },
    t("terminal")
  ), /* @__PURE__ */ import_react.default.createElement(
    import_dsh_client_ui_primitives.Button,
    {
      variant: "outline",
      size: "sm",
      disabled: !!operation,
      onClick: () => {
        void run("data.open");
      }
    },
    t("dataFolder")
  ), /* @__PURE__ */ import_react.default.createElement(
    import_dsh_client_ui_primitives.Button,
    {
      variant: "outline",
      size: "sm",
      disabled: !!operation,
      onClick: () => {
        void run("logs.open");
      }
    },
    t("logs")
  )), /* @__PURE__ */ import_react.default.createElement(Row, { title: t("diagnosticsTitle"), hint: t("diagnosticsHint") }, /* @__PURE__ */ import_react.default.createElement(
    import_dsh_client_ui_primitives.Button,
    {
      variant: "outline",
      size: "sm",
      disabled: !!operation,
      onClick: () => {
        void run("diagnostics.copy");
      }
    },
    t("copyDiagnostics")
  ), /* @__PURE__ */ import_react.default.createElement(
    import_dsh_client_ui_primitives.Button,
    {
      variant: "outline",
      size: "sm",
      disabled: !!operation,
      onClick: () => {
        void run("diagnostics.export");
      }
    },
    t("exportDiagnostics")
  )))));
}

// src/styles.js
var styles = `
.dshStudioSection {
  display: flex;
  flex-direction: column;
  gap: 12px;
  max-width: 720px;
  color: var(--dsw-alias-label-primary);
}

.dshStudioHeading {
  margin: 0;
  font-size: 18px;
  font-weight: 600;
}

.dshStudioIntro {
  margin: 0;
  font-size: 13px;
  color: var(--dsw-alias-label-tertiary);
}

/* Status lines: the same shape the shared form frame uses for its own notices. */
.dshStudioNotice {
  margin: 0;
  font-size: 12px;
  line-height: 1.5;
  color: var(--dsw-alias-label-tertiary);
}

.dshStudioError {
  margin: 0;
  font-size: 12px;
  color: var(--dsw-alias-state-error-primary);
}

/* Named block of related settings (figma group + its head). */
.dshStudioGroup {
  display: flex;
  flex-direction: column;
  gap: 10px;
}

/* Group-to-group breathing room: the section's 12px gap plus 20px. */
.dshStudioGroup + .dshStudioGroup {
  margin-top: 20px;
}

.dshStudioGroupHead {
  margin: 0;
  font-size: 12px;
  font-weight: 600;
  letter-spacing: .06em;
  text-transform: uppercase;
  color: var(--dsw-alias-label-tertiary);
}

/* Preference rows: one column, no gap, the hairline is the separator. */
.dshStudioRows {
  display: flex;
  flex-direction: column;
  min-width: 0;
}

.dshStudioRow {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 24px;
  padding: 16px 0;
  border-bottom: 0.5px solid var(--dsw-alias-border-l2);
}

/* The column strips the trailing separator wherever the rows end. */
.dshStudioRows > :last-child {
  border-bottom: none;
}

.dshStudioRowText {
  display: flex;
  flex-direction: column;
  min-width: 0;
}

.dshStudioRowTitle {
  font-size: 14px;
  line-height: 20px;
}

.dshStudioRowHint {
  margin-top: 4px;
  color: var(--dsw-alias-label-secondary);
  font-size: 12px;
  line-height: 18px;
}

/* The row's second line while it reports a refused value: the colour the
   official invalid message uses, on the line the description already holds. */
.dshStudioRowHintInvalid {
  color: var(--dsw-alias-state-error-primary);
}

/* A row's inline value field. The frame is the official settings value field;
   only the width it takes beside a row title is this page's own. */
.dshStudioNumber {
  height: 34px;
  padding: 0 12px;
  border: 0.5px solid var(--dsw-alias-border-l4);
  border-radius: var(--dsw-radius-md);
  background: var(--dsw-alias-bg-layer-3);
  font: inherit;
  font-size: 13px;
  line-height: 1.5;
  color: var(--dsw-alias-label-primary);
}

.dshStudioNumber:focus-visible {
  outline: none;
  border-color: var(--dsw-alias-state-business-primary);
}

.dshStudioNumber:disabled {
  color: var(--dsw-alias-label-tertiary);
  cursor: default;
}

.dshStudioNumber[aria-invalid='true'] {
  border-color: var(--dsw-alias-state-error-primary);
}

.dshStudioNumberWidth {
  width: 104px;
}

.dshStudioRowControl {
  display: flex;
  flex: none;
  flex-wrap: wrap;
  align-items: center;
  gap: 8px;
}

/* The row's own path line, under the title. */
.dshStudioPath {
  margin-top: 4px;
  max-width: 100%;
}

/* The selector pill of the Language row: the standard control size. */
.dshStudioSelector {
  display: inline-flex;
  align-items: center;
  gap: 12px;
  height: 36px;
  padding: 0 14px;
  border: none;
  border-radius: var(--dsw-radius-md);
  background: var(--dsw-alias-bg-module-platform);
  font: inherit;
  font-size: 14px;
  line-height: 22px;
  color: var(--dsw-alias-label-primary);
  cursor: pointer;
}

.dshStudioSelector:hover:enabled {
  background: var(--dsw-alias-interactive-bg-hover);
}

/* A disabled control dims instead of changing colour, the same treatment the
   shared Button and the preset creator button apply. */
.dshStudioSelector:disabled {
  opacity: .4;
  cursor: default;
}

.dshStudioChevron {
  flex: none;
}

/* Profile rows hold a name, its tags, and the row's own actions. */
.dshStudioProfileName {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 8px;
  min-width: 0;
}

.dshStudioProfileDetail {
  flex-basis: 100%;
  margin-top: 4px;
  color: var(--dsw-alias-label-secondary);
  font-size: 12px;
  line-height: 18px;
  overflow-wrap: anywhere;
}

/* The inline create form: a row whose control is a name field and its action. */
.dshStudioName {
  width: 200px;
}
`;

// src/client.jsx
var inject = ["slots", "locale", "configForms"];
function apply(ctx) {
  ctx.effect(() => {
    const element = document.createElement("style");
    element.dataset.plugin = "dsh-studio-settings";
    element.textContent = styles;
    document.head.append(element);
    return () => {
      element.remove();
    };
  }, "dsh-studio-settings: stylesheet");
  registerStudioSection(ctx, StudioSection);
}
return module.exports;}});
