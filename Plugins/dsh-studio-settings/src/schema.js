import { defaults, migrationField } from "./preferences.js";

// Accept the Runtime's schema implementation, so the plugin never bundles a
// second copy of Cordis/Schemastery into the Host.
export function createPreferencesSchema(z, { volatile = true } = {}) {
  const fields = {
    workspacePath: z.string().pattern(/^\/[^\0]*$/u).required(false),
    chatContentMaxWidth: z.number().min(748).max(2400).default(defaults.chatContentMaxWidth),
    turnCompletionNotification: z.union([
      z.const("never"), z.const("always"), z.const("whenNotFocused"),
    ]).default(defaults.turnCompletionNotification),
    permissionNotificationsEnabled: z.boolean().default(defaults.permissionNotificationsEnabled),
    questionNotificationsEnabled: z.boolean().default(defaults.questionNotificationsEnabled),
    [migrationField]: z.number().min(0).max(Number.MAX_SAFE_INTEGER).step(1).default(0),
  };
  return z.object(Object.fromEntries(Object.entries(fields).map(([key, field]) => [
    key, volatile ? field.volatile() : field,
  ])));
}
