import { namespace, validatePreference } from "./preferences.js";

/** One shared official ConfigForm, with no direct RPC reader or local writer. */
export function createConfigTransport(configForms) {
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
    // Serialize acknowledgement reads with our writes. The shared provider
    // owns its own wire queue; this queue preserves our migration proof.
    const pending = tail.then(async () => {
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
      // Older settingsScope.mutate returns void even for refused writes. Never
      // interpret that contract as a successful current-generation commit.
      if (accepted !== true) throw new Error("Harness did not accept the settings change");
      const document = await describe();
      const committed = document.namespaces.find(section => section.ns === namespace);
      if (!committed || committed.revision <= expectedRevision) {
        throw new Error("Harness did not publish the settings change");
      }
      return committed;
    });
    tail = pending.catch(() => {});
    return pending;
  }

  return Object.freeze({
    describe,
    mutate,
    getSnapshot: () => form.getSnapshot(),
    subscribe: listener => {
      assertActive();
      return form.subscribe(listener);
    },
    async set(key, value, expectedRevision) {
      if (!validatePreference(key, value)) throw new TypeError("Invalid DSH Studio preference");
      return mutate(namespace, [{ op: "set", path: [key], value }], expectedRevision);
    },
    dispose() {
      disposed = true;
      // ConfigForms owns the shared controller; do not dispose another
      // consumer's form when this plugin unloads.
    },
  });
}
