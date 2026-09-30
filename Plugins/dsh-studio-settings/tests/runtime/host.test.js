import assert from "node:assert/strict";
import { cp, mkdir, mkdtemp, readFile, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";
import test from "node:test";
import { migrateLegacyPreferences, namespace } from "../../src/preferences.js";

// Explicit opt-in: integration tests never discover or boot the user's profile.
const runtime = process.env.DSH_TEST_RUNTIME;
test("real Harness Loader persists Studio settings with conflict and restart safety", {
  skip: runtime ? false : "Set DSH_TEST_RUNTIME to an installed harness package directory",
}, async t => {
  const require = createRequire(join(resolve(runtime), "package.json"));
  const load = name => import(pathToFileURL(require.resolve(name)).href);
  const [{ boot, initProfile, readProfilePatches }, { default: ConfigEditor }, { default: Settings }] =
    await Promise.all([
      load("@deepseek-ai/dsh-app-boot"),
      load("@deepseek-ai/dsh-config-editor"),
      load("@deepseek-ai/dsh-settings"),
    ]);
  const home = await realpath(await mkdtemp(join(tmpdir(), "dsh-studio-settings-test-")));
  const roots = [];
  t.after(async () => {
    for (const ctx of roots.reverse()) await ctx.fiber.dispose();
    await rm(home, { recursive: true, force: true });
  });
  const dir = join(home, "profiles", "test");
  initProfile(dir, ["studio-fixture", "dsh-studio-settings"]);
  const bundle = join(dir, "node_modules", "studio-fixture");
  const plugin = join(dir, "node_modules", "dsh-studio-settings");
  await mkdir(bundle, { recursive: true });
  await cp(fileURLToPath(new URL("../../src", import.meta.url)), join(plugin, "src"), { recursive: true });
  await cp(fileURLToPath(new URL("../../package.json", import.meta.url)), join(plugin, "package.json"));
  await cp(fileURLToPath(new URL("../../cordis.patch.yml", import.meta.url)), join(plugin, "cordis.patch.yml"));
  await symlink(join(resolve(runtime), "node_modules"), join(plugin, "node_modules"), "dir");
  await writeFile(join(home, "package.json"), '{"name":"studio-integration-test"}');
  await writeFile(join(bundle, "package.json"), JSON.stringify({
    name: "studio-fixture", version: "1.0.0", dsh: { bundle: { patch: "cordis.patch.yml" } },
  }));
  await writeFile(join(bundle, "cordis.patch.yml"), JSON.stringify([{ insert: [
    { id: "config-editor", name: "cordis:editor" },
    { id: "settings", name: "cordis:settings" },
  ] }]));
  await writeFile(join(dir, "cordis.yml"), "[]\n");
  const profile = {
    name: "test", startedBundles: ["studio-fixture", "dsh-studio-settings"], dir,
    patchPath: join(dir, "cordis.patch.yml"), installAnchor: join(home, "package.json"),
    cwd: home, home, overlays: [], telemetryDisabledEnv: undefined,
  };
  async function start() {
    const ctx = await boot("test", join(dir, "cordis.yml"), readProfilePatches("test", profile), ctx => {
      ctx.provide("profileContext", profile);
      ctx.provide("appReady", { onReady: listener => { listener(); return () => {}; } });
      Object.assign(ctx.loader.builtins, { editor: ConfigEditor, settings: Settings });
    });
    roots.push(ctx);
    return ctx;
  }
  let ctx = await start();
  const section = () => ctx.settings.describe().find(row => row.ns === namespace);
  assert.equal(section().value.chatContentMaxWidth, 1000);
  assert.equal(section().autoGenerate, false);
  assert.equal(section().value.permissionNotificationsEnabled, true);
  const transport = {
    describe: async () => ({ writable: true, namespaces: ctx.settings.describe() }),
    mutate: async (ns, ops, revision) => {
      await ctx.settings.mutate(ns, ops, revision);
      return section();
    },
  };
  await migrateLegacyPreferences(transport, {
    chatContentMaxWidth: 1232, permissionNotificationsEnabled: false,
    workspacePath: join(home, "workspace"),
  });
  assert.equal(section().value.legacyDefaultsMigrationVersion, 1);
  assert.equal(section().value.permissionNotificationsEnabled, false);
  const committedPatch = await readFile(profile.patchPath, "utf8");
  assert.match(committedPatch, /1232/);
  const revision = section().revision;
  const writes = await Promise.allSettled([
    ctx.settings.mutate(namespace, [{ op: "set", path: ["chatContentMaxWidth"], value: 1400 }], revision),
    ctx.settings.mutate(namespace, [{ op: "set", path: ["chatContentMaxWidth"], value: 1600 }], revision),
  ]);
  assert.equal(writes.filter(write => write.status === "fulfilled").length, 1);
  assert.equal(writes.filter(write => write.status === "rejected").length, 1);
  const lastWidth = section().value.chatContentMaxWidth;
  for (const [key, value] of [
    ["chatContentMaxWidth", 1], ["permissionNotificationsEnabled", 1],
    ["turnCompletionNotification", "invalid"], ["workspacePath", "relative"],
    ["legacyDefaultsMigrationVersion", 0.5],
  ]) {
    await assert.rejects(ctx.settings.mutate(namespace, [{ op: "set", path: [key], value }]));
  }
  await ctx.fiber.dispose();
  roots.pop();
  ctx = await start();
  assert.equal(section().value.chatContentMaxWidth, lastWidth);
  assert.equal(section().value.permissionNotificationsEnabled, false);
  const before = await readFile(profile.patchPath, "utf8");
  await migrateLegacyPreferences(transport, { chatContentMaxWidth: 900 });
  assert.equal(await readFile(profile.patchPath, "utf8"), before);
});
