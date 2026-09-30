/**
 * The conversation-column width field's rule.
 *
 * Kept free of imports on purpose: the range is this app's own rule (it is what
 * the injected layout can actually render and what the Swift store clamps to),
 * so it is stated and tested here rather than inherited from a shared number
 * field.
 */

/** Range the conversation column may take, in CSS pixels. */
export const contentWidthRange = Object.freeze({ min: 748, max: 2400 });

/**
 * Read one draft of the width field.
 *
 * The field writes what it is given, so a draft outside the range is not a
 * width: the caller keeps the applied value and says why instead of sending a
 * write the app would have to clamp.
 *
 * @param text - what the field currently shows.
 * @param range - inclusive bounds the draft must fall inside.
 * @returns the number to write, or `undefined` when the draft is not a width.
 */
export function parseContentWidth(text, range = contentWidthRange) {
  const trimmed = String(text ?? "").trim();
  if (trimmed === "") return undefined;
  const value = Number(trimmed);
  if (!Number.isFinite(value) || value < range.min || value > range.max) return undefined;
  return value;
}
