import z from "@deepseek-ai/schemastery";
import { createPreferencesSchema } from "./schema.js";
import { migrateLegacyHostPreferences } from "./host-migration.js";

export const Config = createPreferencesSchema(z);

export function apply(ctx) {
  // The dedicated Studio section owns presentation, not the generated Plugins
  // form. Keep configuration persistence entirely with the official service.
  ctx.inject(["settings"], child => {
    if (typeof child.settings.configure !== "function") {
      throw new Error("DSH Studio settings requires the Config-based Harness settings service");
    }
    child.effect(() => child.settings.configure({ auto: false }, ctx.fiber));
    child.effect(() => {
      void migrateLegacyHostPreferences(child.settings).catch(error => {
        child.logger.warn("dsh-studio: legacy preference migration was not completed", error);
      });
    });
  });
}
