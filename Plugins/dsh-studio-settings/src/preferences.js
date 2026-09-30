// This namespace must also be the Loader entry id on Config-based runtimes.
export const namespace = "dsh-studio";
export const migrationField = "legacyDefaultsMigrationVersion";
export const migrationVersion = 1;

export const defaults = Object.freeze({
  chatContentMaxWidth: 1000,
  turnCompletionNotification: "whenNotFocused",
  permissionNotificationsEnabled: true,
  questionNotificationsEnabled: true,
});

export const preferenceKeys = Object.freeze([
  ...Object.keys(defaults),
  "workspacePath",
]);

export function validatePreference(key, value) {
  switch (key) {
    case "chatContentMaxWidth":
      return typeof value === "number" && Number.isFinite(value)
        && value >= 748 && value <= 2400;
    case "turnCompletionNotification":
      return ["never", "always", "whenNotFocused"].includes(value);
    case "permissionNotificationsEnabled":
    case "questionNotificationsEnabled":
      return typeof value === "boolean";
    case "workspacePath":
      // Filesystem admission remains native; never expand or rewrite user paths here.
      return typeof value === "string" && value.startsWith("/")
        && !value.includes("\0") && value.trim().length > 0;
    default:
      return false;
  }
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

/**
 * Import only explicitly stored legacy keys into absent Host user overrides.
 * The marker and preferences are one revision-fenced write. No secrets, runtime
 * metadata, or arbitrary UserDefaults keys may enter this namespace.
 */
export function planLegacyMigration(section, legacy) {
  if (!isRecord(section) || section.ns !== namespace
      || !Number.isSafeInteger(section.revision) || section.revision < 0
      || !isRecord(section.value)
      || (section.user !== undefined && !isRecord(section.user))
      || !isRecord(legacy)) {
    throw new TypeError("Invalid DSH Studio migration snapshot");
  }
  const user = section.user ?? {};
  const marker = user[migrationField] ?? section.value[migrationField] ?? 0;
  if (!Number.isSafeInteger(marker) || marker < 0) {
    throw new TypeError("Invalid DSH Studio migration version");
  }
  if (marker >= migrationVersion) {
    return { expectedRevision: section.revision, operations: [], rejectedKeys: [] };
  }

  const operations = [];
  const rejectedKeys = [];
  for (const key of preferenceKeys) {
    if (!Object.hasOwn(legacy, key) || Object.hasOwn(user, key)) continue;
    let value = legacy[key];
    // Match the legacy store's width normalization, including its default for NaN.
    if (key === "chatContentMaxWidth" && typeof value === "number") {
      value = Number.isFinite(value) ? Math.min(2400, Math.max(748, value)) : defaults[key];
    }
    if (!validatePreference(key, value)) {
      rejectedKeys.push(key);
      continue;
    }
    operations.push({ op: "set", path: [key], value });
  }
  // Invalid legacy data requires repair; do not permanently mark a partial import.
  if (rejectedKeys.length) {
    return { expectedRevision: section.revision, operations: [], rejectedKeys };
  }
  operations.push({ op: "set", path: [migrationField], value: migrationVersion });
  return { expectedRevision: section.revision, operations, rejectedKeys };
}

/**
 * Transport returns the committed namespace or throws (including conflicts).
 * Do not retry conflicts with a new revision and the old plan: re-read and re-plan.
 */
export async function migrateLegacyPreferences(transport, legacy) {
  const document = await transport.describe();
  if (!document.writable) throw new Error("Harness settings are read-only");
  const section = document.namespaces.find(item => item.ns === namespace);
  if (!section) throw new Error("DSH Studio settings plugin is unavailable");
  const plan = planLegacyMigration(section, legacy);
  if (plan.rejectedKeys.length) {
    throw new Error(`Invalid legacy settings: ${plan.rejectedKeys.join(", ")}`);
  }
  if (!plan.operations.length) return section;
  const committed = await transport.mutate(namespace, plan.operations, plan.expectedRevision);
  if (committed?.ns !== namespace || committed.value?.[migrationField] !== migrationVersion
      || !Number.isSafeInteger(committed.revision) || committed.revision <= section.revision) {
    throw new Error("Harness did not confirm the settings migration");
  }
  for (const operation of plan.operations) {
    if (committed.value[operation.path[0]] !== operation.value) {
      throw new Error("Harness did not confirm an imported preference");
    }
  }
  return committed;
}
