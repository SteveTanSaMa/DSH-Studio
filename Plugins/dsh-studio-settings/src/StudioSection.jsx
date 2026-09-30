/**
 * The DSH Studio page inside Harness's own settings dialog.
 *
 * The page is a `settings.section` occupant, so it inherits the official nav row,
 * panel chrome, and locale bindings. It is assembled from the same pieces an
 * official page uses and nothing else: preference rows for the switches and the
 * one value, `Menu` for the selector, `Button` / `Input` / `Tag` / `PathLabel`
 * for the rest. That is what makes it read as a first-party page and follow the
 * Harness theme in both light and dark modes.
 *
 * Every row writes as soon as it is used — the value row commits the number it
 * shows when the field is left — so no row carries a save of its own.
 *
 * Operations the page cannot perform itself (native panels, process control) go
 * over the app bridge; everything else is a settings write.
 */
import React, { useState, useSyncExternalStore } from "react";
import {
  Button,
  IconChevronDownOutlineRegular,
  Input,
  Menu,
  PathLabel,
  Switch,
  Tag,
} from "@deepseek-ai/dsh-client-ui-primitives";
import { namespace } from "./preferences.js";
import { parseContentWidth } from "./width-spec.js";

/**
 * One labelled row, with its control on the trailing edge.
 *
 * @param props.title - row label.
 * @param props.hint - second line, usually the row's description.
 * @param props.invalid - whether that second line reports a refused value.
 * @param props.children - the row's control.
 */
function Row({ title, hint, invalid, children }) {
  return (
    <div className="dshStudioRow">
      <div className="dshStudioRowText">
        <div className="dshStudioRowTitle">{title}</div>
        {hint ? (
          <div className={invalid ? "dshStudioRowHint dshStudioRowHintInvalid" : "dshStudioRowHint"}>
            {hint}
          </div>
        ) : null}
      </div>
      <div className="dshStudioRowControl">{children}</div>
    </div>
  );
}

/**
 * Render the DSH Studio settings page.
 *
 * @param props.transport - Official settings scope for the `dsh-studio` namespace.
 * @param props.nativeAction - Bridge for operations only the app can perform.
 * @param props.t - Locale-bound translator for this plugin's namespace.
 * @returns the page element tree.
 */
export function StudioSection({ transport, nativeAction, t }) {
  const snapshot = useSyncExternalStore(
    transport.subscribe, transport.getSnapshot, transport.getSnapshot,
  );
  const [widthDraft, setWidthDraft] = useState(null);
  const [widthRefused, setWidthRefused] = useState(false);
  const [busy, setBusy] = useState(false);
  const [failed, setFailed] = useState(false);
  const [profiles, setProfiles] = useState(null);
  const [profileName, setProfileName] = useState("");
  const [pendingDelete, setPendingDelete] = useState("");
  const [completionOpen, setCompletionOpen] = useState(false);
  const [operation, setOperation] = useState("");
  const [runtimeStatus, setRuntimeStatus] = useState(null);

  const value = snapshot.status === "ready" ? snapshot.value : undefined;
  const writable = snapshot.writable && snapshot.mode === "host";
  const disabled = busy || !writable;
  const completionOptions = ["whenNotFocused", "always", "never"];

  const save = async (key, next) => {
    setFailed(false);
    setBusy(true);
    try {
      await transport.set(key, next, snapshot.revision);
      // The app keeps acting on these after Harness has stored them, so each
      // committed value is reported back over the bridge.
      await nativeAction("preference.sync", { key, value: next }).catch(() => undefined);
    } catch {
      setFailed(true);
    } finally {
      setBusy(false);
    }
  };

  /**
   * Refresh the workspace value the page shows.
   *
   * The app owns the workspace: it admits the directory and relaunches Harness
   * against it before answering, so a refused mirror write is not a failure the
   * user needs to see — the next settings read shows the app's value again.
   */
  const mirrorWorkspacePath = async (path) => {
    if (!path) return;
    try {
      const document = await transport.describe();
      const section = document.namespaces.find(item => item.ns === namespace);
      if (!section || section.value?.workspacePath === path) return;
      await transport.set("workspacePath", path, section.revision);
    } catch {
      return;
    }
  };

  const run = async (action, payload = {}) => {
    setFailed(false);
    setOperation(action);
    try {
      const result = await nativeAction(action, payload);
      if (action === "profile.list") setProfiles(result);
      if (action === "runtime.check") setRuntimeStatus(result);
      if (action === "workspace.choose" && result?.changed) {
        await mirrorWorkspacePath(result.workspacePath);
      }
      return result;
    } catch {
      setFailed(true);
      return undefined;
    } finally {
      setOperation("");
    }
  };

  if (snapshot.status !== "ready" || !value) {
    return (
      <section className="dshStudioSection" aria-label={t("nav")}>
        <h2 className="dshStudioHeading">{t("nav")}</h2>
        <p className="dshStudioNotice" role="status">
          {t(snapshot.status === "loading" ? "loading" : "unavailable")}
        </p>
      </section>
    );
  }

  const applyProfileChange = async (action, payload) => {
    const result = await run(action, payload);
    setPendingDelete("");
    if (result) {
      setProfileName("");
      await run("profile.list");
    }
  };

  const committedWidth = value.chatContentMaxWidth;
  // The draft is the field's own text while it has focus; without one the row
  // shows what the app is actually using.
  const widthText = widthDraft ?? String(committedWidth);
  // An emptied field is not a mistake yet: it is a field the user is about to
  // type into, so it only turns red once the text says something unusable.
  const widthEntered = widthDraft !== null && widthDraft.trim() !== "";
  const widthInvalid = widthEntered && parseContentWidth(widthDraft) === undefined;

  /** Type into the width field: the draft is not written until the field is left. */
  const editWidth = (text) => {
    setWidthDraft(text);
    setWidthRefused(false);
  };

  /**
   * Write the number the field shows.
   *
   * A draft that is not a width is refused here rather than sent: the app would
   * clamp it, and a field that silently becomes another number is worse than one
   * that says the number is out of range. Clearing the field asks for nothing, so
   * the row falls back to the applied value without reporting an error.
   */
  const commitWidth = () => {
    if (widthDraft === null) return;
    const width = parseContentWidth(widthDraft);
    setWidthDraft(null);
    // Only text that was meant to be a width can be refused by it.
    setWidthRefused(widthEntered && width === undefined);
    if (width === undefined || width === committedWidth) return;
    void save("chatContentMaxWidth", width);
  };

  return (
    <section className="dshStudioSection" aria-label={t("nav")}>
      <h2 className="dshStudioHeading">{t("nav")}</h2>
      <p className="dshStudioIntro">{t("intro")}</p>
      {failed && (
        <p className="dshStudioError" role="alert">{t("operationFailed")}</p>
      )}
      {!writable && (
        <p className="dshStudioNotice" role="status">{t("readOnly")}</p>
      )}

      <div className="dshStudioGroup">
        <h3 className="dshStudioGroupHead">{t("conversation")}</h3>
        <div className="dshStudioRows">
          <Row
            title={t("width")}
            hint={widthInvalid || widthRefused ? t("invalidWidth") : t("widthHint")}
            invalid={widthInvalid || widthRefused}>
            <input
              id="dsh-studio-content-width"
              className="dshStudioNumber dshStudioNumberWidth"
              type="text"
              inputMode="numeric"
              aria-label={t("width")}
              aria-invalid={widthInvalid || undefined}
              disabled={disabled}
              value={widthText}
              onChange={event => { editWidth(event.target.value); }}
              onBlur={commitWidth}
              onKeyDown={event => {
                if (event.key !== "Enter") return;
                commitWidth();
              }} />
          </Row>
        </div>
      </div>

      <div className="dshStudioGroup">
        <h3 className="dshStudioGroupHead">{t("notifications")}</h3>
        <div className="dshStudioRows">
          <Row title={t("completion")} hint={t("completionHint")}>
            <Menu
              open={completionOpen}
              onClose={() => { setCompletionOpen(false); }}
              items={completionOptions.map(option => ({ id: option, label: t(option) }))}
              selectedId={value.turnCompletionNotification}
              onSelect={option => {
                setCompletionOpen(false);
                void save("turnCompletionNotification", option);
              }}
              align="end"
              portal
              anchor={(
                <button
                  type="button"
                  className="dshStudioSelector"
                  disabled={disabled}
                  aria-haspopup="menu"
                  aria-expanded={completionOpen}
                  aria-label={t("completion")}
                  onClick={() => { setCompletionOpen(open => !open); }}>
                  {t(value.turnCompletionNotification)}
                  <IconChevronDownOutlineRegular className="dshStudioChevron" />
                </button>
              )} />
          </Row>
          <Row title={t("permissions")} hint={t("permissionsHint")}>
            <Switch
              checked={value.permissionNotificationsEnabled}
              disabled={disabled}
              label={t("permissions")}
              onChange={next => { void save("permissionNotificationsEnabled", next); }} />
          </Row>
          <Row title={t("questions")} hint={t("questionsHint")}>
            <Switch
              checked={value.questionNotificationsEnabled}
              disabled={disabled}
              label={t("questions")}
              onChange={next => { void save("questionNotificationsEnabled", next); }} />
          </Row>
        </div>
      </div>

      <div className="dshStudioGroup">
        <h3 className="dshStudioGroupHead">{t("workspace")}</h3>
        <div className="dshStudioRows">
          <div className="dshStudioRow">
            <div className="dshStudioRowText">
              <div className="dshStudioRowTitle">{t("workspacePath")}</div>
              <PathLabel
                className="dshStudioPath"
                path={value.workspacePath ?? t("workspaceUnknown")} />
              <div className="dshStudioRowHint">{t("workspaceHint")}</div>
            </div>
            <div className="dshStudioRowControl">
              <Button
                variant="outline"
                size="sm"
                disabled={!!operation}
                onClick={() => { void run("workspace.choose"); }}>
                {t("choose")}
              </Button>
            </div>
          </div>
        </div>
      </div>

      <div className="dshStudioGroup">
        <h3 className="dshStudioGroupHead">{t("profiles")}</h3>
        <div className="dshStudioRows">
          <Row title={t("profileTitle")} hint={t("profilesHint")}>
            <Button
              variant="outline"
              size="sm"
              disabled={!!operation}
              onClick={() => { void run("profile.list"); }}>
              {t("refresh")}
            </Button>
          </Row>
          {(profiles?.profiles ?? []).map(profile => (
            <div className="dshStudioRow" key={profile.name}>
              <div className="dshStudioRowText">
                <div className="dshStudioProfileName">
                  <span className="dshStudioRowTitle">{profile.name}</span>
                  {profile.name === profiles.active && <Tag tone="solid">{t("active")}</Tag>}
                  {!profile.selectable && <Tag tone="warning">{t("unusable")}</Tag>}
                </div>
                {profile.problem
                  ? <div className="dshStudioProfileDetail">{profile.problem}</div>
                  : null}
              </div>
              <div className="dshStudioRowControl">
                {pendingDelete === profile.name ? (
                  <>
                    <Button
                      variant="outline"
                      size="sm"
                      disabled={!!operation}
                      onClick={() => { void applyProfileChange("profile.delete", { name: profile.name }); }}>
                      {t("confirmDelete")}
                    </Button>
                    <Button
                      variant="ghost"
                      size="sm"
                      disabled={!!operation}
                      onClick={() => { setPendingDelete(""); }}>
                      {t("cancel")}
                    </Button>
                  </>
                ) : (
                  <>
                    <Button
                      variant="outline"
                      size="sm"
                      disabled={!!operation || profile.name === profiles.active || !profile.selectable}
                      onClick={() => { void applyProfileChange("profile.select", { name: profile.name }); }}>
                      {t("select")}
                    </Button>
                    <Button
                      variant="ghost"
                      size="sm"
                      disabled={!!operation}
                      onClick={() => { setPendingDelete(profile.name); }}>
                      {t("delete")}
                    </Button>
                  </>
                )}
              </div>
            </div>
          ))}
          {profiles !== null && profiles.profiles.length === 0 && (
            <Row title={t("profilesEmpty")} />
          )}
          <Row title={t("create")} hint={t("profileNameHint")}>
            <Input
              className="dshStudioName"
              value={profileName}
              placeholder={t("profileName")}
              aria-label={t("profileName")}
              disabled={!!operation}
              onChange={event => { setProfileName(event.currentTarget.value); }} />
            <Button
              variant="outline"
              size="sm"
              disabled={!!operation || !profileName.trim()}
              onClick={() => { void applyProfileChange("profile.create", { name: profileName.trim() }); }}>
              {t("create")}
            </Button>
          </Row>
        </div>
      </div>

      <div className="dshStudioGroup">
        <h3 className="dshStudioGroupHead">{t("maintenance")}</h3>
        <div className="dshStudioRows">
          <Row
            title={t("runtimeTitle")}
            hint={runtimeStatus === null
              ? t("runtimeHint")
              : t("runtimeSummary")
                .replace("{runtime}", runtimeStatus.runtimeVersion ?? t("unknown"))
                .replace("{available}", runtimeStatus.availableVersion ?? t("unknown"))}>
            <Button
              variant="outline"
              size="sm"
              disabled={!!operation}
              onClick={() => { void run("runtime.check"); }}>
              {t("checkRuntime")}
            </Button>
            <Button
              variant="outline"
              size="sm"
              disabled={!!operation || runtimeStatus?.updateAvailable !== true}
              onClick={() => { void run("runtime.update"); }}>
              {t("updateRuntime")}
            </Button>
            <Button
              variant="outline"
              size="sm"
              disabled={!!operation || runtimeStatus?.rollbackAvailable !== true}
              onClick={() => { void run("runtime.rollback"); }}>
              {t("rollbackRuntime")}
            </Button>
          </Row>
          <Row title={t("presetTitle")} hint={t("presetHint")}>
            <Button
              variant="outline"
              size="sm"
              disabled={!!operation}
              onClick={() => { void run("preset.import"); }}>
              {t("importPreset")}
            </Button>
            <Button
              variant="outline"
              size="sm"
              disabled={!!operation}
              onClick={() => { void run("preset.export"); }}>
              {t("exportPreset")}
            </Button>
          </Row>
          <Row title={t("localTitle")} hint={t("localHint")}>
            <Button
              variant="outline"
              size="sm"
              disabled={!!operation}
              onClick={() => { void run("terminal.open"); }}>
              {t("terminal")}
            </Button>
            <Button
              variant="outline"
              size="sm"
              disabled={!!operation}
              onClick={() => { void run("data.open"); }}>
              {t("dataFolder")}
            </Button>
            <Button
              variant="outline"
              size="sm"
              disabled={!!operation}
              onClick={() => { void run("logs.open"); }}>
              {t("logs")}
            </Button>
          </Row>
          <Row title={t("diagnosticsTitle")} hint={t("diagnosticsHint")}>
            <Button
              variant="outline"
              size="sm"
              disabled={!!operation}
              onClick={() => { void run("diagnostics.copy"); }}>
              {t("copyDiagnostics")}
            </Button>
            <Button
              variant="outline"
              size="sm"
              disabled={!!operation}
              onClick={() => { void run("diagnostics.export"); }}>
              {t("exportDiagnostics")}
            </Button>
          </Row>
        </div>
      </div>
    </section>
  );
}
