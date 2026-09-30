import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { join, resolve } from "node:path";
import { runInNewContext } from "node:vm";
import test from "node:test";
import React from "react";
import { act, create } from "react-test-renderer";
import { registerStudioSection } from "../../src/registration.js";
import { namespace } from "../../src/preferences.js";

const runtime = process.env.DSH_TEST_RUNTIME;
test("official SlotRegistry selects only Studio and disposes its registration", {
  skip: runtime ? false : "Set DSH_TEST_RUNTIME to an installed harness package directory",
}, async t => {
  const runtimeRequire = createRequire(join(resolve(runtime), "package.json"));
  const localRequire = createRequire(import.meta.url);
  const { Context } = runtimeRequire("@deepseek-ai/cordis");
  let Renderer;
  const source = await readFile(runtimeRequire.resolve("@deepseek-ai/dsh-client-ui-renderer/client"), "utf8");
  runInNewContext(source, {
    window: { __ModuleLoader__: { load({ factory }) {
      Renderer = factory(name => name.startsWith("react")
        ? localRequire(name) : runtimeRequire(name));
    } } },
    console, setTimeout, clearTimeout, queueMicrotask,
  });
  const ctx = new Context();
  let rendered;
  t.after(async () => {
    act(() => rendered?.unmount());
    await ctx.fiber.dispose();
  });
  await ctx.plugin(Renderer);
  const absent = { key: undefined, hooks: {}, keyedHooks: {}, props: {} };
  const scopeSource = { getSnapshot: () => absent, subscribe: () => () => {} };
  ctx.slots.installScope("session", { current: scopeSource, bindingSource: () => scopeSource });
  const localeSnapshot = { revision: 0 };
  const locale = {
    register: () => () => {},
    bind: () => key => key === "nav" ? "DSH Studio" : key,
    subscribe: () => () => {},
    getSnapshot: () => localeSnapshot,
  };
  ctx.provide("locale", locale);
  ctx.slots.installLocale(locale);
  let served = false;
  let register;
  let remove;
  let transport;
  const snapshot = { status: "ready", revision: 0, mode: "host", writable: true, value: {} };
  ctx.provide("configForms", {
    get: () => ({
      getSnapshot: () => snapshot, subscribe: () => () => {},
    }),
    describe: () => ({ ensure: async () => {}, getSnapshot: () => ({ status: "ready" }) }),
    whileServed: (namespaces, callback) => {
      assert.deepEqual(namespaces, [namespace]);
      register = callback;
      if (served) remove = register();
      return () => { remove?.(); remove = undefined; register = undefined; };
    },
  });
  const Studio = () => React.createElement("div", null, "studio-content");
  const plugin = ctx.plugin({
    inject: ["slots", "locale", "configForms"],
    apply(child) { transport = registerStudioSection(child, Studio); },
  });
  await plugin;
  assert.equal(ctx.slots.entries("settings.section").length, 0);
  let setActive;
  const Shell = ({ renderSlot }) => {
    const [active, select] = React.useState("general");
    setActive = select;
    return React.createElement("main", null,
      renderSlot("settings.section", { close() {} }, { only: active }));
  };
  const closeShell = ctx.slots.register({
    name: "root",
    children: { "settings.section": { kind: "list", scope: "root" } },
  }, Shell);
  ctx.slots.register({ name: "settings.section", id: "general", label: "General" },
    () => React.createElement("div", null, "general-content"));
  served = true;
  remove = register();
  assert.deepEqual(ctx.slots.entries("settings.section").map(entry => entry.options.id),
    ["general", namespace]);
  act(() => { rendered = create(ctx.slots.renderSlot("root", {})); });
  const render = () => JSON.stringify(rendered.toJSON());
  assert.match(render(), /general-content/);
  assert.doesNotMatch(render(), /studio-content/);
  act(() => setActive(namespace));
  assert.match(render(), /studio-content/);
  assert.doesNotMatch(render(), /general-content/);
  act(() => setActive("general"));
  assert.doesNotMatch(render(), /studio-content/);
  assert.equal(ctx.slots.entries("settings.general.item").length, 0);
  remove();
  remove = undefined;
  assert.deepEqual(ctx.slots.entries("settings.section").map(entry => entry.options.id), ["general"]);
  remove = register();
  await plugin.dispose();
  assert.deepEqual(ctx.slots.entries("settings.section").map(entry => entry.options.id), ["general"]);
  await assert.rejects(transport.describe(), /closed/);
  act(() => rendered.unmount());
  rendered = undefined;
  closeShell();
});
