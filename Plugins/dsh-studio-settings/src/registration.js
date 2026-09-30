import { createConfigTransport } from "./config-transport.js";
import { en, zh, localeNamespace } from "./locales.js";
import { namespace } from "./preferences.js";
import { nativeAction } from "./native-actions.js";

export function registerStudioSection(ctx, component) {
  const transport = createConfigTransport(ctx.configForms);
  ctx.effect(() => () => {
    transport.dispose();
  });
  ctx.effect(() => ctx.locale.register(localeNamespace, { en, zh }));
  const t = ctx.locale.bind(localeNamespace);
  // Wait for both the official shell's declaration and the Host namespace.
  // These effects withdraw the page on Host removal or plugin unload.
  ctx.slots.inject("settings.section", () => ctx.configForms.whileServed([namespace], () =>
    ctx.slots.register({
      name: "settings.section",
      id: namespace,
      order: 100,
      label: () => t("nav"),
      locale: localeNamespace,
      inject: () => ({ transport, nativeAction }),
    }, component)));
  return transport;
}
