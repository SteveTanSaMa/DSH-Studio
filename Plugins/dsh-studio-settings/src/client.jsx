import { registerStudioSection } from "./registration.js";
import { StudioSection } from "./StudioSection.jsx";
import { styles } from "./styles.js";

export const inject = ["slots", "locale", "configForms"];

export function apply(ctx) {
  // The stylesheet is owned by this page and is added only while the plugin is
  // loaded, so unloading the plugin leaves no rule behind.
  ctx.effect(() => {
    const element = document.createElement("style");
    element.dataset.plugin = "dsh-studio-settings";
    element.textContent = styles;
    document.head.append(element);
    return () => { element.remove(); };
  }, "dsh-studio-settings: stylesheet");
  registerStudioSection(ctx, StudioSection);
}
