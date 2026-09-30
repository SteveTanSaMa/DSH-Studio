import { build } from "esbuild";
import { fileURLToPath } from "node:url";

// Harness serves client modules through its own loader and shared React.
await build({
  absWorkingDir: fileURLToPath(new URL("..", import.meta.url)),
  entryPoints: ["src/client.jsx"],
  outfile: "lib/client.js",
  bundle: true,
  format: "cjs",
  platform: "browser",
  target: "safari16",
  external: ["react", "@deepseek-ai/dsh-client-ui-primitives"],
  banner: { js: 'window.__ModuleLoader__.load({id:"dsh-studio-settings",factory:(require)=>{var module={exports:{}};var exports=module.exports;' },
  footer: { js: "return module.exports;}});" },
});
