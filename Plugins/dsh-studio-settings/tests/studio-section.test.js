import assert from "node:assert/strict";
import test from "node:test";
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";

const require = createRequire(import.meta.url);
const React = require("react");
const TestRenderer = require("react-test-renderer");

/**
 * Stand-ins for the primitives the shell shares into its module table.
 *
 * The page must never bundle its own copy, so the test supplies them the same way
 * the browser does: through the factory's `require`. Each stub keeps the contract
 * the page relies on (a switch reports the next state, a row action reports the
 * press) so the assertions below are about what the page passes, not styling.
 */
const primitives = {
  Button: ({ children, ...rest }) => React.createElement("button", rest, children),
  Switch: ({ checked, label, onChange, disabled }) => React.createElement("button", {
    role: "switch", "aria-label": label, "aria-checked": checked, disabled,
    onClick: () => { onChange(!checked); },
  }),
  Input: ({ className, ...rest }) => React.createElement("input", { className, ...rest }),
  Tag: ({ tone, children }) => React.createElement("span", { "data-tone": tone }, children),
  PathLabel: ({ path }) => React.createElement("span", null, path),
  IconChevronDownOutlineRegular: () => React.createElement("svg", null),
  Menu: ({ anchor }) => anchor,
};

/**
 * Load the shipped bundle the way Harness does and materialize its factory.
 * @returns the bundle exports, as the module table would see them.
 */
function loadBundle() {
  let registration;
  globalThis.window = { __ModuleLoader__: { load: value => { registration = value; } } };
  globalThis.document = {
    createElement: () => ({ dataset: {}, remove() {} }),
    head: { append() {} },
  };
  const code = readFileSync(new URL("../lib/client.js", import.meta.url), "utf8");
  new Function(code)();
  assert.ok(registration, "bundle registered itself with the module loader");
  assert.equal(registration.chunk, undefined);
  return registration.factory(specifier => {
    if (specifier === "react") return React;
    if (specifier === "@deepseek-ai/dsh-client-ui-primitives") return primitives;
    throw new Error(`unexpected external ${specifier}`);
  });
}

/**
 * The Host side of the settings service, as the plugin's transport sees it.
 *
 * This is the real contract rather than a shortcut: `configForms.get` hands back
 * one controller per namespace, every write lands in `mutate`, and the accepted
 * revision is what the next fenced write is checked against.
 *
 * @param initial - the namespace section the Host holds.
 * @param options - a read-only document, and a deliberately stale mirror value.
 * @returns the service plus every mutation it was asked to apply.
 */
function createConfigForms(initial, { writable = true, mirrored = initial } = {}) {
  let section = { ...initial };
  let mirrorValue = { ...mirrored };
  let revision = 7;
  let cached;
  const listeners = new Set();
  const calls = { mutations: [] };
  // The shared controller hands out one snapshot object until something changes;
  // a fresh object per read would make the page's subscription loop forever.
  const invalidate = () => { cached = undefined; };
  const notify = () => {
    invalidate();
    for (const listener of listeners) listener();
  };
  const controller = {
    getSnapshot: () => cached ??= {
      status: "ready",
      value: section,
      base: undefined,
      user: section,
      revision,
      writable,
      mode: "host",
    },
    subscribe: listener => { listeners.add(listener); return () => { listeners.delete(listener); }; },
    async mutate(operations, expectedRevision) {
      calls.mutations.push({ operations, expectedRevision });
      invalidate();
      for (const operation of operations) {
        if (operation.op === "set") section = { ...section, [operation.path[0]]: operation.value };
      }
      revision += 1;
      mirrorValue = { ...section };
      notify();
      return true;
    },
  };
  const mirror = {
    ensure: async () => true,
    getSnapshot: () => ({
      status: "ready",
      writable,
      error: undefined,
      view: {
        writable,
        hasDocument: true,
        namespaces: [{ ns: "dsh-studio", value: { ...mirrorValue }, revision }],
      },
    }),
  };
  return {
    get: () => controller,
    describe: () => mirror,
    // The page is registered as served straight away, as it is whenever the Host
    // composes the namespace this plugin's Host half declares.
    whileServed: (namespaces, register) => { register(new Set(namespaces)); return () => {}; },
    calls,
  };
}

/**
 * Run the bundle's `apply` against a capturing context.
 * @param configForms - the Host-facing service the plugin binds to.
 * @returns the registered section and the face its page is rendered with.
 */
function captureSection(configForms) {
  const exports = loadBundle();
  const registered = [];
  const ctx = {
    effect: fn => { fn(); return () => {}; },
    slots: {
      inject: (name, register) => { register(); registered.push(name); },
      register: (options, component) => { registered.push({ options, component }); return () => {}; },
    },
    locale: { register: () => {}, bind: () => key => key },
    configForms,
  };
  exports.apply(ctx);
  const entry = registered.find(item => typeof item === "object" && item.options?.name === "settings.section");
  return { options: entry.options, component: entry.component, face: entry.options.inject() };
}

const preferenceValues = {
  chatContentMaxWidth: 1000,
  turnCompletionNotification: "whenNotFocused",
  permissionNotificationsEnabled: true,
  questionNotificationsEnabled: true,
  workspacePath: "/Users/example/Workspace",
};

/** Render the page over a real transport and form, returning the renderer. */
async function renderSection(value, options = {}) {
  const configForms = createConfigForms(value, options);
  const { component, face } = captureSection(configForms);
  const actions = [];
  const nativeAction = async (action, payload) => {
    actions.push({ action, payload });
    if (action === "profile.list") {
      return { active: "web", profiles: [{ name: "web", selectable: true, bundles: [] }] };
    }
    if (action === "workspace.choose") {
      return { changed: true, workspacePath: "/Users/example/Workspace" };
    }
    return { ok: true };
  };
  let renderer;
  await TestRenderer.act(async () => {
    renderer = TestRenderer.create(React.createElement(component, {
      ...face,
      nativeAction,
      t: key => key,
    }));
  });
  return { renderer, calls: configForms.calls, actions };
}

/**
 * Collect the props of every rendered (host) element matching a predicate.
 *
 * Composite nodes are skipped so a match is always something the browser would
 * actually have: the props on a host element are the ones the page passed down.
 */
function findAll(renderer, predicate) {
  return renderer.root.findAll(node => typeof node.type === "string", { deep: true })
    .map(node => node.props)
    .filter(predicate);
}

const widthFieldProps = () => props => props.id === "dsh-studio-content-width";

test("the bundle registers a settings section for the DSH Studio namespace", () => {
  const exports = loadBundle();
  assert.deepEqual(exports.inject, ["slots", "locale", "configForms"]);
  assert.equal(typeof exports.apply, "function");

  const { options, component } = captureSection(createConfigForms(preferenceValues));
  assert.equal(options.id, "dsh-studio");
  assert.equal(options.order, 100);
  assert.equal(options.locale, "dsh-studio.settings");
  assert.equal(typeof options.label, "function");
  assert.equal(typeof component, "function");
});

test("the page renders in the official section shape: heading, intro, and named groups", async () => {
  const { renderer } = await renderSection(preferenceValues);
  const json = JSON.stringify(renderer.toJSON());

  for (const text of [
    "nav", "intro", "conversation", "width",
    "notifications", "completion", "permissions", "questions",
    "workspace", "workspacePath",
    "profiles", "maintenance", "runtimeTitle", "diagnosticsTitle",
  ]) {
    assert.ok(json.includes(`"${text}"`), `expected the page to render ${text}`);
  }
  assert.ok(json.includes(preferenceValues.workspacePath), "the workspace path is shown");

  // The frame the official pages use: one heading, one intro, then group heads.
  const headings = renderer.root.findAllByType("h2").map(node => node.props.children);
  assert.deepEqual(headings, ["nav"]);
  const groupHeads = renderer.root.findAllByType("h3").map(node => node.props.children);
  assert.deepEqual(groupHeads, ["conversation", "notifications", "workspace", "profiles", "maintenance"]);
});

test("every row action uses the compact control size the official rows use", async () => {
  const { renderer } = await renderSection(preferenceValues);
  // The shared Button defaults to the 36px control; a row mixes several of them,
  // so one that forgets `size="sm"` makes the action cluster uneven.
  const actions = findAll(renderer, props => props.variant !== undefined && props.children !== undefined);
  assert.ok(actions.length >= 10, "the page offers the maintenance actions");
  for (const action of actions) {
    assert.equal(action.size, "sm", `${action.children} is not the compact control size`);
  }
});

test("the width is an inline row seeded from the stored value", async () => {
  const { renderer } = await renderSection(preferenceValues);
  const field = findAll(renderer, widthFieldProps())[0];

  assert.equal(field.value, "1000", "the field is seeded from the stored value");
  assert.equal(field["aria-invalid"], undefined);
  assert.equal(field.disabled, false);
  assert.ok(field.className.includes("dshStudioNumber"), "the field carries the value-field frame");

  // The row keeps the value beside its title: the field is a row control, not a
  // block of its own.
  const node = renderer.root.findAll(
    candidate => typeof candidate.type === "string" && candidate.props.id === "dsh-studio-content-width",
  )[0];
  let ancestor = node.parent;
  while (ancestor && !String(ancestor.props?.className ?? "").includes("dshStudioRowControl")) {
    ancestor = ancestor.parent;
  }
  assert.ok(ancestor, "the field is rendered as the row's control");
});

test("leaving the field writes the number once, with no save to press", async () => {
  const { renderer, calls, actions } = await renderSection(preferenceValues);
  const field = findAll(renderer, widthFieldProps())[0];

  await TestRenderer.act(async () => {
    field.onChange({ target: { value: "900" } });
  });
  assert.deepEqual(calls.mutations, [], "a draft is not a write");
  assert.equal(findAll(renderer, widthFieldProps())[0].value, "900");

  await TestRenderer.act(async () => {
    findAll(renderer, widthFieldProps())[0].onBlur();
  });

  assert.deepEqual(calls.mutations, [{
    operations: [{ op: "set", path: ["chatContentMaxWidth"], value: 900 }],
    expectedRevision: 7,
  }]);
  assert.deepEqual(actions, [
    { action: "preference.sync", payload: { key: "chatContentMaxWidth", value: 900 } },
  ]);
  assert.equal(findAll(renderer, widthFieldProps())[0].value, "900", "the field shows the accepted value");
  assert.equal(findAll(renderer, widthFieldProps())[0]["aria-invalid"], undefined);
  assert.ok(
    !JSON.stringify(renderer.toJSON()).includes("invalidWidth"),
    "a written value leaves no message behind",
  );
});

test("the return key commits the draft the same way leaving the field does", async () => {
  const { renderer, calls } = await renderSection(preferenceValues);
  const field = findAll(renderer, widthFieldProps())[0];

  await TestRenderer.act(async () => {
    field.onChange({ target: { value: "1200" } });
  });
  await TestRenderer.act(async () => {
    findAll(renderer, widthFieldProps())[0].onKeyDown({ key: "Enter" });
  });

  assert.deepEqual(calls.mutations, [{
    operations: [{ op: "set", path: ["chatContentMaxWidth"], value: 1200 }],
    expectedRevision: 7,
  }]);

  // A key that is not the return key leaves the draft alone.
  await TestRenderer.act(async () => {
    findAll(renderer, widthFieldProps())[0].onChange({ target: { value: "1300" } });
  });
  await TestRenderer.act(async () => {
    findAll(renderer, widthFieldProps())[0].onKeyDown({ key: "Tab" });
  });
  assert.equal(calls.mutations.length, 1, "only the return key commits");
});

test("a width outside the renderable range is refused before it reaches the Host", async () => {
  const { renderer, calls } = await renderSection(preferenceValues);

  await TestRenderer.act(async () => {
    findAll(renderer, widthFieldProps())[0].onChange({ target: { value: "5000" } });
  });
  assert.equal(findAll(renderer, widthFieldProps())[0]["aria-invalid"], true);
  assert.ok(
    JSON.stringify(renderer.toJSON()).includes("invalidWidth"),
    "the row explains the range while the draft is out of it",
  );

  await TestRenderer.act(async () => {
    findAll(renderer, widthFieldProps())[0].onBlur();
  });

  assert.deepEqual(calls.mutations, [], "an out-of-range draft is never written");
  assert.equal(
    findAll(renderer, widthFieldProps())[0].value,
    "1000",
    "the field falls back to the value the app is using",
  );
  assert.ok(
    JSON.stringify(renderer.toJSON()).includes("invalidWidth"),
    "and the row keeps saying why until the next edit",
  );
});

test("clearing the field falls back to the applied value without complaining", async () => {
  const { renderer, calls } = await renderSection(preferenceValues);

  await TestRenderer.act(async () => {
    findAll(renderer, widthFieldProps())[0].onChange({ target: { value: "" } });
  });
  // An empty field is a field about to be typed into, not a refused value.
  assert.equal(findAll(renderer, widthFieldProps())[0]["aria-invalid"], undefined);
  assert.ok(
    !JSON.stringify(renderer.toJSON()).includes("invalidWidth"),
    "an emptied field says nothing about the range",
  );

  await TestRenderer.act(async () => {
    findAll(renderer, widthFieldProps())[0].onKeyDown({ key: "Enter" });
  });

  assert.deepEqual(calls.mutations, [], "nothing to write");
  const field = findAll(renderer, widthFieldProps())[0];
  assert.equal(field.value, "1000", "the field shows the value the app is using");
  assert.equal(field["aria-invalid"], undefined);
  assert.ok(
    !JSON.stringify(renderer.toJSON()).includes("invalidWidth"),
    "and the row is back to its description",
  );
});

test("the page carries no save of its own", async () => {
  const { renderer } = await renderSection(preferenceValues);
  const rendered = JSON.stringify(renderer.toJSON());

  for (const label of ["save", "saving", "overridden", "reset"]) {
    assert.ok(!rendered.includes(`"${label}"`), `the page must not render ${label}`);
  }
});

test("a notification switch writes the boolean it was asked for", async () => {
  const { renderer, calls, actions } = await renderSection(preferenceValues);
  const toggle = findAll(renderer, props => props.role === "switch" && props["aria-label"] === "permissions")[0];
  assert.ok(toggle, "the permission switch is rendered");

  await TestRenderer.act(async () => {
    toggle.onClick();
  });

  assert.deepEqual(calls.mutations, [{
    operations: [{ op: "set", path: ["permissionNotificationsEnabled"], value: false }],
    expectedRevision: 7,
  }]);
  assert.equal(actions[0].action, "preference.sync");
  assert.equal(actions[0].payload.value, false);
});

test("a read-only document disables every control", async () => {
  const { renderer, calls } = await renderSection(preferenceValues, { writable: false });
  const json = JSON.stringify(renderer.toJSON());
  assert.ok(json.includes("readOnly"), "the form states that the document is read-only");

  assert.equal(findAll(renderer, widthFieldProps())[0].disabled, true);
  assert.equal(findAll(renderer, props => props.role === "switch")[0].disabled, true);
  assert.deepEqual(calls.mutations, []);
});

test("choosing a workspace mirrors the admitted path the app returned", async () => {
  const { renderer, calls, actions } = await renderSection(preferenceValues, {
    mirrored: { ...preferenceValues, workspacePath: "/Users/example/Stale" },
  });
  const choose = findAll(renderer, props => props.children === "choose")[0];
  assert.ok(choose, "the choose action is rendered");

  await TestRenderer.act(async () => {
    choose.onClick();
  });

  assert.deepEqual(actions.map(entry => entry.action), ["workspace.choose"]);
  assert.deepEqual(calls.mutations, [{
    operations: [{ op: "set", path: ["workspacePath"], value: "/Users/example/Workspace" }],
    expectedRevision: 7,
  }]);
});

test("a workspace the page already shows is not written again", async () => {
  const { renderer, calls } = await renderSection(preferenceValues);
  const choose = findAll(renderer, props => props.children === "choose")[0];

  await TestRenderer.act(async () => {
    choose.onClick();
  });

  assert.deepEqual(calls.mutations, []);
});

test("the active profile is tagged and the runnable ones can be switched to", async () => {
  const { renderer, actions } = await renderSection(preferenceValues);
  await TestRenderer.act(async () => {
    findAll(renderer, props => props.children === "refresh")[0].onClick();
  });

  const tags = findAll(renderer, props => props["data-tone"] !== undefined);
  assert.deepEqual(tags.map(tag => tag["data-tone"]), ["solid"], "the active profile carries the selection tag");
  const switchProfile = findAll(renderer, props => props.children === "select")[0];
  assert.equal(switchProfile.disabled, true, "the profile already in use is not offered again");

  const remove = findAll(renderer, props => props.children === "delete")[0];
  await TestRenderer.act(async () => {
    remove.onClick();
  });
  assert.equal(actions.length, 1, "the first press only asks for confirmation");

  await TestRenderer.act(async () => {
    findAll(renderer, props => props.children === "confirmDelete")[0].onClick();
  });
  assert.deepEqual(actions.map(entry => entry.action), ["profile.list", "profile.delete", "profile.list"]);
  assert.deepEqual(actions[1].payload, { name: "web" });
});
