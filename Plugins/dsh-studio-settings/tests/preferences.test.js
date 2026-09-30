import assert from "node:assert/strict";
import { test } from "node:test";
import {
  defaults, migrationField, migrateLegacyPreferences, namespace,
  planLegacyMigration, validatePreference,
} from "../src/preferences.js";

const section = (overrides = {}) => ({
  ns: namespace, revision: 7, value: { ...defaults }, user: {}, ...overrides,
});

test("imports explicit legacy preferences and marker in one fenced plan", () => {
  const plan = planLegacyMigration(section(), {
    chatContentMaxWidth: 1200, permissionNotificationsEnabled: false,
    workspacePath: "/Users/example/Project",
  });
  assert.equal(plan.expectedRevision, 7);
  assert.deepEqual(plan.rejectedKeys, []);
  assert.deepEqual(plan.operations, [
    { op: "set", path: ["chatContentMaxWidth"], value: 1200 },
    { op: "set", path: ["permissionNotificationsEnabled"], value: false },
    { op: "set", path: ["workspacePath"], value: "/Users/example/Project" },
    { op: "set", path: [migrationField], value: 1 },
  ]);
});

test("existing Host overrides win, including false and values equal to defaults", () => {
  const plan = planLegacyMigration(section({
    user: { chatContentMaxWidth: 1000, permissionNotificationsEnabled: false },
  }), { chatContentMaxWidth: 1600, permissionNotificationsEnabled: true });
  assert.deepEqual(plan.operations, [{ op: "set", path: [migrationField], value: 1 }]);
});

test("absent legacy keys do not overwrite inherited defaults", () => {
  assert.deepEqual(planLegacyMigration(section(), {}).operations, [
    { op: "set", path: [migrationField], value: 1 },
  ]);
});

test("unknown keys and secrets are not copied", () => {
  const result = planLegacyMigration(section(), {
    apiKey: "do-not-copy", token: "do-not-copy", activeProfile: "web",
    settingsSidebarWidth: 188,
  });
  assert.equal(JSON.stringify(result).includes("do-not-copy"), false);
  assert.equal(result.operations.length, 1);
});

test("completed and newer migrations are idempotent", () => {
  for (const version of [1, 2]) {
    assert.deepEqual(planLegacyMigration(section({
      user: { [migrationField]: version },
    }), { chatContentMaxWidth: 1700 }).operations, []);
  }
});

test("legacy widths preserve previous normalization", () => {
  for (const [input, expected] of [[0, 748], [3000, 2400], [NaN, 1000]]) {
    const plan = planLegacyMigration(section(), { chatContentMaxWidth: input });
    assert.equal(plan.operations[0].value, expected);
  }
});

test("invalid legacy data produces no partial writes or completion marker", () => {
  const plan = planLegacyMigration(section(), {
    chatContentMaxWidth: 1500, questionNotificationsEnabled: 1,
  });
  assert.deepEqual(plan.operations, []);
  assert.deepEqual(plan.rejectedKeys, ["questionNotificationsEnabled"]);
});

test("rejects invalid snapshots and revision fences", () => {
  for (const invalid of [
    section({ ns: "other" }), section({ revision: undefined }),
    section({ revision: -1 }), section({ revision: 1.5 }),
    section({ value: null }), section({ user: [] }),
    section({ value: { [migrationField]: "1" } }),
  ]) {
    assert.throws(() => planLegacyMigration(invalid, {}), TypeError);
  }
});

test("validation does not coerce numbers, booleans, paths or enum values", () => {
  for (const [key, value] of [
    ["chatContentMaxWidth", true], ["chatContentMaxWidth", "1000"],
    ["chatContentMaxWidth", Infinity], ["permissionNotificationsEnabled", 1],
    ["turnCompletionNotification", "sometimes"], ["workspacePath", "~/Project"],
    ["workspacePath", "/tmp/\0bad"], ["unknown", true],
  ]) assert.equal(validatePreference(key, value), false);
  assert.equal(validatePreference("questionNotificationsEnabled", false), true);
});

test("a successful commit is returned only after migration is confirmed", async () => {
  const source = section();
  const calls = [];
  const result = await migrateLegacyPreferences({
    describe: async () => ({ writable: true, namespaces: [source] }),
    mutate: async (ns, ops, revision) => {
      calls.push({ ns, revision });
      return section({
        revision: 8,
        value: { ...source.value, ...Object.fromEntries(ops.map(op => [op.path[0], op.value])) },
      });
    },
  }, { chatContentMaxWidth: 1300 });
  assert.deepEqual(calls, [{ ns: namespace, revision: 7 }]);
  assert.equal(result.value.chatContentMaxWidth, 1300);
  assert.equal(result.value[migrationField], 1);
});

test("conflicts propagate without blind retry or mutation of legacy backup", async () => {
  const conflict = new Error("settings/conflict");
  const legacy = Object.freeze({ chatContentMaxWidth: 1400 });
  let writes = 0;
  await assert.rejects(migrateLegacyPreferences({
    describe: async () => ({ writable: true, namespaces: [section()] }),
    mutate: async () => { writes++; throw conflict; },
  }, legacy), error => error === conflict);
  assert.equal(writes, 1);
  assert.equal(legacy.chatContentMaxWidth, 1400);
});

test("unavailable or read-only Host cannot silently complete migration", async () => {
  for (const document of [
    { writable: false, namespaces: [section()] },
    { writable: true, namespaces: [] },
  ]) {
    await assert.rejects(migrateLegacyPreferences({
      describe: async () => document,
      mutate: async () => assert.fail("must not write"),
    }, {}));
  }
});

test("malformed or unconfirmed write acknowledgements fail", async () => {
  for (const answer of [
    section(), section({ revision: 8, value: { [migrationField]: 1 } }),
    section({ ns: "other", revision: 8, value: { [migrationField]: 1 } }),
  ]) {
    await assert.rejects(migrateLegacyPreferences({
      describe: async () => ({ writable: true, namespaces: [section()] }),
      mutate: async () => answer,
    }, { chatContentMaxWidth: 1400 }));
  }
});
