import assert from "node:assert/strict";
import test from "node:test";
import { createConfigTransport } from "../src/config-transport.js";
import { migrateLegacyPreferences, namespace } from "../src/preferences.js";

function fixture({ accepted = true } = {}) {
  let section = { ns: namespace, revision: 1, value: {}, user: {} };
  let snapshot = { status: "ready", writable: true, mode: "host", revision: 1 };
  let mirrorError = null;
  const writes = [];
  let ensured = 0;
  let disposedForm = false;
  const form = {
    getSnapshot: () => snapshot,
    subscribe: () => () => {},
    dispose: () => { disposedForm = true; },
    async mutate(ops, revision) {
      writes.push({ ops, revision });
      if (accepted === true) {
        const value = { ...section.value };
        for (const op of ops) value[op.path[0]] = op.value;
        section = { ...section, value, user: value, revision: revision + 1 };
        snapshot = { ...snapshot, revision: section.revision };
      }
      return accepted;
    },
  };
  const transport = createConfigTransport({
    get: ns => { assert.equal(ns, namespace); return form; },
    describe: () => ({
      ensure: async () => { ensured++; },
      getSnapshot: () => ({
        status: "ready", error: mirrorError,
        view: { writable: snapshot.writable, namespaces: [section] },
      }),
    }),
  });
  return {
    transport, writes,
    setSnapshot: value => { snapshot = { ...snapshot, ...value }; },
    setError: value => { mirrorError = value; },
    get ensured() { return ensured; },
    get disposedForm() { return disposedForm; },
  };
}

test("migration uses shared mirror and a single fenced official form mutation", async () => {
  const f = fixture();
  const result = await migrateLegacyPreferences(f.transport, { chatContentMaxWidth: 1200 });
  assert.equal(result.value.chatContentMaxWidth, 1200);
  assert.equal(result.value.legacyDefaultsMigrationVersion, 1);
  assert.equal(f.writes.length, 1);
  assert.equal(f.writes[0].revision, 1);
  assert.equal(f.writes[0].ops.length, 2);
  assert.equal(f.ensured, 2);
});

test("Host refusal cannot be reported as migration success", async () => {
  const f = fixture({ accepted: false });
  await assert.rejects(migrateLegacyPreferences(f.transport, {}), /did not accept/);
});

test("legacy void mutation contract is not accepted as a commit", async () => {
  const f = fixture({ accepted: null });
  await assert.rejects(migrateLegacyPreferences(f.transport, {}), /did not accept/);
});

test("rejects stale, memory-only and read-only writes before the wire", async () => {
  for (const changed of [{ revision: 2 }, { writable: false }, { mode: "memory" }]) {
    const f = fixture();
    f.setSnapshot(changed);
    await assert.rejects(f.transport.set("chatContentMaxWidth", 1100, 1));
    assert.equal(f.writes.length, 0);
  }
});

test("simultaneous editors cannot overwrite each other using the same revision", async () => {
  const f = fixture();
  const result = await Promise.allSettled([
    f.transport.set("chatContentMaxWidth", 1100, 1),
    f.transport.set("chatContentMaxWidth", 1400, 1),
  ]);
  assert.deepEqual(result.map(item => item.status), ["fulfilled", "rejected"]);
  assert.equal(f.writes.length, 1);
});

test("namespace and preference allowlists reject arbitrary writes", async () => {
  const f = fixture();
  await assert.rejects(f.transport.mutate("other", [], 1));
  await assert.rejects(f.transport.set("apiKey", "secret", 1));
  await assert.rejects(f.transport.set("permissionNotificationsEnabled", 1, 1));
  assert.equal(f.writes.length, 0);
});

test("a failed mirror refresh is not treated as fresh migration data", async () => {
  const f = fixture();
  f.setError("connection lost");
  await assert.rejects(migrateLegacyPreferences(f.transport, {}), /connection lost/);
  assert.equal(f.writes.length, 0);
});

test("unload cancels queued writes but leaves the shared form alive", async () => {
  const f = fixture();
  const pending = f.transport.set("chatContentMaxWidth", 1100, 1);
  f.transport.dispose();
  await assert.rejects(pending, /closed/);
  await assert.rejects(f.transport.describe(), /closed/);
  assert.equal(f.writes.length, 0);
  assert.equal(f.disposedForm, false);
});
