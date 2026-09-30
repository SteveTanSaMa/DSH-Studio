import assert from "node:assert/strict";
import test from "node:test";
import { existsSync, readFileSync } from "node:fs";

import { styles } from "../src/styles.js";
import { contentWidthRange } from "../src/width-spec.js";

/**
 * The declarations each rule of the page is required to carry.
 *
 * Every entry is transcribed from the first-party rule it mirrors, with the
 * upstream file named beside it. The page is only "the same UI language as
 * Harness" while these hold: a changed type size, spacing step, or token would
 * make the mounted page drift away from the pages around it, which is invisible
 * in a diff and obvious on screen. Update an entry only together with the
 * upstream rule it came from.
 */
const goldenRules = [
  {
    ours: ".dshStudioSection",
    upstream: "ui-agent-preset/src/client/AgentPresetSection.module.css .section",
    declarations: {
      display: "flex",
      "flex-direction": "column",
      gap: "12px",
      "max-width": "720px",
      color: "var(--dsw-alias-label-primary)",
    },
  },
  {
    ours: ".dshStudioHeading",
    upstream: "ui-agent-preset/src/client/AgentPresetSection.module.css .title",
    declarations: { margin: "0", "font-size": "18px", "font-weight": "600" },
  },
  {
    ours: ".dshStudioIntro",
    upstream: "ui-agent-preset/src/client/AgentPresetSection.module.css .intro",
    declarations: { margin: "0", "font-size": "13px", color: "var(--dsw-alias-label-tertiary)" },
  },
  {
    ours: ".dshStudioNotice",
    upstream: "ui-primitives/src/settings-form/SettingsForm.module.css .readOnly",
    declarations: {
      margin: "0",
      "font-size": "12px",
      "line-height": "1.5",
      color: "var(--dsw-alias-label-tertiary)",
    },
  },
  {
    ours: ".dshStudioError",
    upstream: "ui-agent-preset/src/client/AgentPresetSection.module.css .error",
    declarations: { margin: "0", "font-size": "12px", color: "var(--dsw-alias-state-error-primary)" },
  },
  {
    ours: ".dshStudioGroup",
    upstream: "ui-agent-preset/src/client/AgentPresetSection.module.css .group",
    declarations: { display: "flex", "flex-direction": "column", gap: "10px" },
  },
  {
    ours: ".dshStudioGroupHead",
    upstream: "ui-agent-preset/src/client/AgentPresetSection.module.css .groupHead",
    declarations: {
      margin: "0",
      "font-size": "12px",
      "font-weight": "600",
      "letter-spacing": ".06em",
      "text-transform": "uppercase",
      color: "var(--dsw-alias-label-tertiary)",
    },
  },
  {
    ours: ".dshStudioRow",
    upstream: "ui-settings-general/src/client/DeveloperToolsRow.module.css .row",
    declarations: {
      display: "flex",
      "align-items": "center",
      "justify-content": "space-between",
      gap: "24px",
      padding: "16px 0",
      "border-bottom": "0.5px solid var(--dsw-alias-border-l2)",
    },
  },
  {
    ours: ".dshStudioRowTitle",
    upstream: "ui-settings-general/src/client/DeveloperToolsRow.module.css .title",
    declarations: { "font-size": "14px", "line-height": "20px" },
  },
  {
    ours: ".dshStudioRowHint",
    upstream: "ui-settings-general/src/client/DeveloperToolsRow.module.css .description",
    declarations: {
      "margin-top": "4px",
      color: "var(--dsw-alias-label-secondary)",
      "font-size": "12px",
      "line-height": "18px",
    },
  },
  {
    ours: ".dshStudioRowHintInvalid",
    upstream: "ui-primitives/src/settings-form/fields.module.css .invalid (its colour, on the row's description line)",
    declarations: { color: "var(--dsw-alias-state-error-primary)" },
  },
  {
    ours: ".dshStudioNumber",
    upstream: "ui-primitives/src/settings-form/fields.module.css .input",
    declarations: {
      height: "34px",
      padding: "0 12px",
      border: "0.5px solid var(--dsw-alias-border-l4)",
      "border-radius": "var(--dsw-radius-md)",
      background: "var(--dsw-alias-bg-layer-3)",
      font: "inherit",
      "font-size": "13px",
      "line-height": "1.5",
      color: "var(--dsw-alias-label-primary)",
    },
  },
  {
    ours: ".dshStudioNumber:focus-visible",
    upstream: "ui-primitives/src/settings-form/fields.module.css .input:focus-visible",
    declarations: {
      outline: "none",
      "border-color": "var(--dsw-alias-state-business-primary)",
    },
  },
  {
    ours: ".dshStudioNumber:disabled",
    upstream: "ui-primitives/src/settings-form/fields.module.css .input:disabled",
    declarations: { color: "var(--dsw-alias-label-tertiary)", cursor: "default" },
  },
  {
    ours: ".dshStudioNumber[aria-invalid='true']",
    upstream: "ui-primitives/src/settings-form/fields.module.css .input[aria-invalid='true']",
    declarations: { "border-color": "var(--dsw-alias-state-error-primary)" },
  },
  {
    ours: ".dshStudioSelector",
    upstream: "locale/src/client/LanguageRow.module.css .selector",
    declarations: {
      display: "inline-flex",
      "align-items": "center",
      gap: "12px",
      height: "36px",
      padding: "0 14px",
      border: "none",
      "border-radius": "var(--dsw-radius-md)",
      background: "var(--dsw-alias-bg-module-platform)",
      font: "inherit",
      "font-size": "14px",
      "line-height": "22px",
      color: "var(--dsw-alias-label-primary)",
      cursor: "pointer",
    },
  },
  {
    ours: ".dshStudioSelector:hover:enabled",
    upstream: "locale/src/client/LanguageRow.module.css .selector:hover",
    declarations: { background: "var(--dsw-alias-interactive-bg-hover)" },
  },
  {
    ours: ".dshStudioSelector:disabled",
    upstream: "ui-primitives/src/Button.module.css .button:disabled",
    declarations: { opacity: ".4", cursor: "default" },
  },
  {
    ours: ".dshStudioChevron",
    upstream: "locale/src/client/LanguageRow.module.css .chevron",
    declarations: { flex: "none" },
  },
];

/** Split one stylesheet into `selector → declarations`. */
function rulesOf(text) {
  const table = new Map();
  for (const match of text.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    const selector = match[1].trim().split("\n").pop().trim();
    const declarations = {};
    for (const entry of match[2].split(";")) {
      const separator = entry.indexOf(":");
      if (separator < 0) continue;
      declarations[entry.slice(0, separator).trim()] = entry.slice(separator + 1).trim();
    }
    table.set(selector, declarations);
  }
  return table;
}

const rules = rulesOf(styles);

test("every mirrored rule carries exactly the upstream declarations", () => {
  for (const rule of goldenRules) {
    const ours = rules.get(rule.ours);
    assert.ok(ours, `${rule.ours} is missing from the stylesheet`);
    assert.deepEqual(
      ours,
      rule.declarations,
      `${rule.ours} drifted from ${rule.upstream}`,
    );
  }
});

test("the stylesheet declares the rules the page renders through", () => {
  for (const selector of [
    ".dshStudioRows",
    ".dshStudioRowText",
    ".dshStudioRowControl",
    ".dshStudioPath",
    ".dshStudioProfileName",
    ".dshStudioProfileDetail",
    ".dshStudioName",
    ".dshStudioNumberWidth",
  ]) {
    assert.ok(rules.has(selector), `${selector} is missing from the stylesheet`);
  }
});

test("every design token the page uses is one the mirrored rules already trust", () => {
  const verified = new Set(
    goldenRules
      .flatMap(rule => Object.values(rule.declarations))
      .flatMap(value => [...value.matchAll(/var\((--[a-z0-9-]+)/g)].map(match => match[1])),
  );
  const used = [...styles.matchAll(/var\((--[a-z0-9-]+)/g)].map(match => match[1]);
  const unverified = [...new Set(used)].filter(token => !verified.has(token));
  assert.deepEqual(
    unverified,
    [],
    "a token no upstream rule uses is a token the runtime theme may not declare",
  );
});

test("the page fixes no colour, radius, or font of its own", () => {
  const literal = /#[0-9a-fA-F]{3,8}\b|rgb\(|hsl\(/;
  const offenders = [...rules].filter(([, declarations]) => Object.values(declarations).some(value => literal.test(value)));
  assert.deepEqual(offenders.map(([selector]) => selector), []);
});

/** Locate the app's settings store by walking up to the checkout that holds it. */
function appSettingsStore() {
  let directory = new URL("../", import.meta.url);
  for (let level = 0; level < 6; level += 1) {
    const candidate = new URL(
      "DSH Studio/Sources/App/Settings/SettingsStore.swift",
      directory,
    );
    if (existsSync(candidate)) return candidate;
    directory = new URL("../", directory);
  }
  return undefined;
}

test("the field's range is the same range the app clamps the stored value to", () => {
  // The page and the Swift shell must agree: a draft the form accepts but the app
  // clamps would silently become a different number after a save.
  const store = appSettingsStore();
  assert.ok(store, "this suite checks a contract with the app, so it runs inside the checkout");
  const bounds = readFileSync(store, "utf8").match(
    /chatContentMaxWidthRange\s*=\s*([0-9.]+)\s*\.\.\.\s*([0-9.]+)/,
  );
  assert.ok(bounds, "the app's accepted width range is declared in SettingsStore.swift");
  assert.deepEqual(
    { min: Number(bounds[1]), max: Number(bounds[2]) },
    { min: contentWidthRange.min, max: contentWidthRange.max },
  );
});
