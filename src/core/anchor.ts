// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

import { getStepMarker } from "./labels";
import { CodeTour } from "./types";

export type AnchorKind =
  | "line" // `line`
  | "selection" // the end of `selection`
  | "pattern" // the first match of `pattern`
  | "marker" // the first match of the step marker (e.g. "CT1.3")
  | "end" // file steps without a line are shown at the end of the file
  | "none"; // steps without a file (content and directory steps)

export interface Anchor {
  /** 0-based line, or undefined if the step doesn't have a line. */
  line?: number;
  kind: AnchorKind;
  /** Why the step couldn't be located. */
  problem?: string;
}

/** 0-based line of a character offset. */
export function lineOfOffset(text: string, offset: number) {
  let line = 0;
  for (let i = 0; i < offset; i++) {
    if (text.charCodeAt(i) === 10) {
      line++;
    }
  }
  return line;
}

/** Splits file contents into lines (without the one after a final newline). */
export function splitLines(contents: string) {
  const lines = contents.split(/\r?\n/);
  if (lines.length > 1 && lines[lines.length - 1] === "") {
    lines.pop();
  }
  return lines;
}

/**
 * Works out which line of a file a step is attached to, the same way the
 * player does: `line`, then the end of `selection`, then (for `file` steps)
 * the first match of `pattern` or of the tour's step marker.
 */
export function resolveStepLine(
  tour: CodeTour,
  stepNumber: number,
  contents: string
): Anchor {
  const step = tour.steps[stepNumber];
  if (step.line) {
    return { line: step.line - 1, kind: "line" };
  }
  if (step.selection) {
    return { line: step.selection.end.line - 1, kind: "selection" };
  }
  if (!step.file) {
    return step.uri || step.contents ? { kind: "end" } : { kind: "none" };
  }

  const pattern = step.pattern || getStepMarker(tour, stepNumber);
  if (!pattern) {
    return { kind: "end" };
  }

  const what = step.pattern ? "pattern" : "step marker";
  let regex;
  try {
    regex = new RegExp(pattern, "m");
  } catch (e) {
    return {
      kind: "end",
      problem: `the ${what} ${JSON.stringify(pattern)} isn't a valid regular expression: ${
        e instanceof Error ? e.message : e
      }`
    };
  }

  const match = contents.match(regex);
  if (!match) {
    return {
      kind: "end",
      problem: `the ${what} ${JSON.stringify(pattern)} doesn't match any line`
    };
  }
  return {
    line: lineOfOffset(contents, match.index!),
    kind: step.pattern ? "pattern" : "marker"
  };
}
