/**
 * The DSH Studio page stylesheet.
 *
 * A client plugin cannot import another package's CSS module, so the sheet is
 * injected once from `apply`. Every rule is copied from the first-party page it
 * mirrors — `ui-settings-plugins` / `ui-agent-preset` for the section frame and
 * group heads, `ui-settings-general` for the preference rows, `ui-primitives`
 * for the field frame — and expressed only through the shared `--dsw-alias-*`
 * tokens and radius scale, so the page follows the theme and the light/dark
 * switch exactly like an official one.
 */
export const styles = `
.dshStudioSection {
  display: flex;
  flex-direction: column;
  gap: 12px;
  max-width: 720px;
  color: var(--dsw-alias-label-primary);
}

.dshStudioHeading {
  margin: 0;
  font-size: 18px;
  font-weight: 600;
}

.dshStudioIntro {
  margin: 0;
  font-size: 13px;
  color: var(--dsw-alias-label-tertiary);
}

/* Status lines: the same shape the shared form frame uses for its own notices. */
.dshStudioNotice {
  margin: 0;
  font-size: 12px;
  line-height: 1.5;
  color: var(--dsw-alias-label-tertiary);
}

.dshStudioError {
  margin: 0;
  font-size: 12px;
  color: var(--dsw-alias-state-error-primary);
}

/* Named block of related settings (figma group + its head). */
.dshStudioGroup {
  display: flex;
  flex-direction: column;
  gap: 10px;
}

/* Group-to-group breathing room: the section's 12px gap plus 20px. */
.dshStudioGroup + .dshStudioGroup {
  margin-top: 20px;
}

.dshStudioGroupHead {
  margin: 0;
  font-size: 12px;
  font-weight: 600;
  letter-spacing: .06em;
  text-transform: uppercase;
  color: var(--dsw-alias-label-tertiary);
}

/* Preference rows: one column, no gap, the hairline is the separator. */
.dshStudioRows {
  display: flex;
  flex-direction: column;
  min-width: 0;
}

.dshStudioRow {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 24px;
  padding: 16px 0;
  border-bottom: 0.5px solid var(--dsw-alias-border-l2);
}

/* The column strips the trailing separator wherever the rows end. */
.dshStudioRows > :last-child {
  border-bottom: none;
}

.dshStudioRowText {
  display: flex;
  flex-direction: column;
  min-width: 0;
}

.dshStudioRowTitle {
  font-size: 14px;
  line-height: 20px;
}

.dshStudioRowHint {
  margin-top: 4px;
  color: var(--dsw-alias-label-secondary);
  font-size: 12px;
  line-height: 18px;
}

/* The row's second line while it reports a refused value: the colour the
   official invalid message uses, on the line the description already holds. */
.dshStudioRowHintInvalid {
  color: var(--dsw-alias-state-error-primary);
}

/* A row's inline value field. The frame is the official settings value field;
   only the width it takes beside a row title is this page's own. */
.dshStudioNumber {
  height: 34px;
  padding: 0 12px;
  border: 0.5px solid var(--dsw-alias-border-l4);
  border-radius: var(--dsw-radius-md);
  background: var(--dsw-alias-bg-layer-3);
  font: inherit;
  font-size: 13px;
  line-height: 1.5;
  color: var(--dsw-alias-label-primary);
}

.dshStudioNumber:focus-visible {
  outline: none;
  border-color: var(--dsw-alias-state-business-primary);
}

.dshStudioNumber:disabled {
  color: var(--dsw-alias-label-tertiary);
  cursor: default;
}

.dshStudioNumber[aria-invalid='true'] {
  border-color: var(--dsw-alias-state-error-primary);
}

.dshStudioNumberWidth {
  width: 104px;
}

.dshStudioRowControl {
  display: flex;
  flex: none;
  flex-wrap: wrap;
  align-items: center;
  gap: 8px;
}

/* The row's own path line, under the title. */
.dshStudioPath {
  margin-top: 4px;
  max-width: 100%;
}

/* The selector pill of the Language row: the standard control size. */
.dshStudioSelector {
  display: inline-flex;
  align-items: center;
  gap: 12px;
  height: 36px;
  padding: 0 14px;
  border: none;
  border-radius: var(--dsw-radius-md);
  background: var(--dsw-alias-bg-module-platform);
  font: inherit;
  font-size: 14px;
  line-height: 22px;
  color: var(--dsw-alias-label-primary);
  cursor: pointer;
}

.dshStudioSelector:hover:enabled {
  background: var(--dsw-alias-interactive-bg-hover);
}

/* A disabled control dims instead of changing colour, the same treatment the
   shared Button and the preset creator button apply. */
.dshStudioSelector:disabled {
  opacity: .4;
  cursor: default;
}

.dshStudioChevron {
  flex: none;
}

/* Profile rows hold a name, its tags, and the row's own actions. */
.dshStudioProfileName {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 8px;
  min-width: 0;
}

.dshStudioProfileDetail {
  flex-basis: 100%;
  margin-top: 4px;
  color: var(--dsw-alias-label-secondary);
  font-size: 12px;
  line-height: 18px;
  overflow-wrap: anywhere;
}

/* The inline create form: a row whose control is a name field and its action. */
.dshStudioName {
  width: 200px;
}
`;
