import { migrateLegacyPreferences, namespace } from "./preferences.js";

function legacyFromEnvironment() {
  const raw = process.env.DSH_STUDIO_LEGACY_PREFERENCES;
  if (!raw) return undefined;
  try {
    const value = JSON.parse(raw);
    return value && typeof value === "object" && !Array.isArray(value) ? value : undefined;
  } catch {
    return undefined;
  }
}

/**
 * Import the explicitly allowlisted Swift preferences through the official
 * Host settings service. The environment is a one-launch handoff only; the
 * Host profile remains the authority after this atomic, fenced mutation.
 */
export async function migrateLegacyHostPreferences(settings) {
  const legacy = legacyFromEnvironment();
  if (!legacy || typeof settings?.describe !== "function" || typeof settings?.mutate !== "function") {
    return;
  }
  const describe = () => {
    const section = settings.describe({ redactSecrets: true })
      .find(item => item.ns === namespace);
    if (!section) throw new Error("DSH Studio settings namespace is unavailable");
    return { writable: settings.writable !== false, namespaces: [section] };
  };
  await migrateLegacyPreferences({
    describe: async () => describe(),
    mutate: async (ns, operations, expectedRevision) => {
      await settings.mutate(ns, operations, expectedRevision);
      return describe().namespaces[0];
    },
  }, legacy);
}
