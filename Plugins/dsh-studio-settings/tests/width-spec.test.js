import assert from "node:assert/strict";
import test from "node:test";

import { contentWidthRange, parseContentWidth } from "../src/width-spec.js";

test("a draft inside the range is the number to write", () => {
  assert.equal(parseContentWidth("900"), 900);
  assert.equal(parseContentWidth(" 1200 "), 1200);
  assert.equal(parseContentWidth(String(contentWidthRange.min)), contentWidthRange.min);
  assert.equal(parseContentWidth(String(contentWidthRange.max)), contentWidthRange.max);
});

test("a draft outside the range is not a width", () => {
  assert.equal(parseContentWidth(String(contentWidthRange.min - 1)), undefined);
  assert.equal(parseContentWidth(String(contentWidthRange.max + 1)), undefined);
  assert.equal(parseContentWidth("0"), undefined);
  assert.equal(parseContentWidth("-1000"), undefined);
});

test("a draft that is not a number, or nothing at all, is not a width", () => {
  assert.equal(parseContentWidth(""), undefined);
  assert.equal(parseContentWidth("   "), undefined);
  assert.equal(parseContentWidth(undefined), undefined);
  assert.equal(parseContentWidth("wide"), undefined);
  assert.equal(parseContentWidth("900px"), undefined);
  assert.equal(parseContentWidth("Infinity"), undefined);
  assert.equal(parseContentWidth("NaN"), undefined);
});

test("the field keeps the value it was given, including a fractional width", () => {
  // The Host schema accepts any number in the range, so the page must not
  // round a value it was handed.
  assert.equal(parseContentWidth("1000.5"), 1000.5);
  assert.equal(parseContentWidth("1e3"), 1000);
});
