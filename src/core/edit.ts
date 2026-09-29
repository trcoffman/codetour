// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

import { splitLines } from "./anchor";
import { CodeTour, CodeTourStep } from "./types";

/** Escapes text so it matches literally in a regular expression. */
export function escapeRegExp(text: string) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/**
 * The pattern the recorder uses to anchor a step to a line's content, or
 * undefined if the line is blank or not unique in the file.
 */
export function getLinePattern(contents: string, line: number) {
  const text = (splitLines(contents)[line] || "").trim();
  if (!text) {
    return;
  }

  const pattern = "^[^\\S\\n]*" + escapeRegExp(text);
  const matches = contents.match(new RegExp(pattern, "gm"));
  return matches && matches.length === 1 ? pattern : undefined;
}

export interface Location {
  file: string;
  /** 1-based */
  line?: number;
  /** 1-based, inclusive (a selection of whole lines) */
  lastLine?: number;
  /** The only line containing this text. */
  text?: string;
  /**
   * With `text`: select up to the next line containing this that isn't
   * indented more than the first line (e.g. the `}` that closes a block).
   */
  endText?: string;
}

/**
 * Parses a location: `FILE`, `FILE:LINE`, `FILE:FIRST-LAST`, `FILE:/TEXT/`
 * or `FILE:/START/-/END/`.
 */
export function parseLocation(location: string): Location {
  let match = location.match(/^(.+?):\/(.+?)\/-\/(.+)\/$/);
  if (match) {
    return { file: match[1], text: match[2], endText: match[3] };
  }
  match = location.match(/^(.+?):\/(.*)\/$/);
  if (match) {
    return { file: match[1], text: match[2] };
  }
  match = location.match(/^(.+?):(\d+)-(\d+)$/);
  if (match) {
    return { file: match[1], line: Number(match[2]), lastLine: Number(match[3]) };
  }
  match = location.match(/^(.+?):(\d+)$/);
  if (match) {
    return { file: match[1], line: Number(match[2]) };
  }
  if (location && !location.includes(":")) {
    return { file: location };
  }
  throw new Error(
    `invalid location ${JSON.stringify(location)} (expected FILE:LINE, FILE:FIRST-LAST, FILE:/TEXT/ or FILE:/START/-/END/)`
  );
}

export type Anchoring = Pick<CodeTourStep, "line" | "pattern" | "selection">;

/**
 * Works out how to anchor a step to a location in a file's contents.
 * With `pattern`, the step is anchored to the line's content.
 */
export function anchorToLocation(
  location: Location,
  contents: string,
  { pattern = false }: { pattern?: boolean } = {}
): Anchoring {
  const lines = splitLines(contents);
  let line = location.line;

  if (location.text !== undefined) {
    const matches: number[] = [];
    lines.forEach((text, index) => {
      if (text.includes(location.text!)) {
        matches.push(index + 1);
      }
    });
    if (matches.length === 0) {
      throw new Error(`${JSON.stringify(location.text)} doesn't appear in ${location.file}`);
    } else if (matches.length > 1) {
      throw new Error(
        `${JSON.stringify(location.text)} appears on ${matches.length} lines of ${location.file} (${matches
          .slice(0, 10)
          .join(", ")}${matches.length > 10 ? ", …" : ""}); use a longer text or FILE:LINE`
      );
    }
    line = matches[0];
  }

  if (location.endText !== undefined) {
    const indent = (text: string) => text.match(/^\s*/)![0].length;
    const startIndent = indent(lines[line! - 1]);
    const offset = lines
      .slice(line! - 1)
      .findIndex(text => text.includes(location.endText!) && indent(text) <= startIndent);
    if (offset === -1) {
      throw new Error(
        `${JSON.stringify(location.endText)} doesn't appear in ${location.file} after line ${line} without being indented more than that line`
      );
    }
    location = { ...location, lastLine: line! + offset };
  }

  if (location.lastLine !== undefined) {
    if (pattern) {
      throw new Error("a pattern anchors a single line; use FILE:LINE or FILE:/TEXT/ with --pattern");
    }
    if (location.lastLine < line! || location.lastLine > lines.length) {
      throw new Error(
        `invalid line range ${line}-${location.lastLine} (${location.file} has ${lines.length} lines)`
      );
    }
    return {
      selection: {
        start: { line: line!, character: 1 },
        // Positions are 1-based and count UTF-16 code units, like JS strings.
        end: { line: location.lastLine, character: lines[location.lastLine - 1].length + 1 }
      }
    };
  }

  if (line === undefined) {
    return {};
  }
  if (line < 1 || line > lines.length) {
    throw new Error(`line ${line} is outside of ${location.file} (${lines.length} lines)`);
  }
  if (pattern && location.text !== undefined) {
    // Anchor to the given text (unique, see above) rather than the whole line.
    return { pattern: escapeRegExp(location.text) };
  }
  if (pattern) {
    const linePattern = getLinePattern(contents, line - 1);
    if (!linePattern) {
      throw new Error(
        `line ${line} of ${location.file} is blank or not unique, so it can't be anchored by pattern`
      );
    }
    return { pattern: linePattern };
  }
  return { line };
}

/** Creates a step with its keys in the order the recorder writes them. */
export function createStep(fields: Partial<CodeTourStep>): CodeTourStep {
  const order = fields.file
    ? fields.selection
      ? ["title", "file", "selection", "description"]
      : ["title", "file", "description", "line", "pattern"]
    : fields.directory
    ? ["title", "directory", "description"]
    : ["title", "description"];

  const step: any = {};
  for (const key of [...order, ...Object.keys(fields)]) {
    if (key === "description") {
      step.description = fields.description || "";
    } else if ((fields as any)[key] !== undefined) {
      step[key] = (fields as any)[key];
    }
  }
  return step;
}

/** Replaces how a step is anchored (file, directory, line, pattern, ...). */
export function reanchorStep(step: CodeTourStep, fields: Partial<CodeTourStep>) {
  for (const key of ["file", "directory", "uri", "contents", "line", "pattern", "selection"]) {
    delete (step as any)[key];
  }
  Object.assign(step, fields);
}

function checkStep(tour: CodeTour, number: number) {
  if (!Number.isInteger(number) || !tour.steps[number - 1]) {
    throw new Error(`the tour doesn't have a step #${number} (it has ${plural(tour.steps.length, "step")})`);
  }
}

export function plural(count: number, noun: string) {
  return `${count} ${noun}${count === 1 ? "" : "s"}`;
}

/** Inserts a step at a 1-based position (the end by default). */
export function insertStep(tour: CodeTour, step: CodeTourStep, position = tour.steps.length + 1) {
  if (!Number.isInteger(position) || position < 1 || position > tour.steps.length + 1) {
    throw new Error(`invalid position ${position} (the tour has ${plural(tour.steps.length, "step")})`);
  }
  tour.steps.splice(position - 1, 0, step);
  return position;
}

/** Moves a step (1-based) to another position. */
export function moveStep(tour: CodeTour, from: number, to: number) {
  checkStep(tour, from);
  if (!Number.isInteger(to) || to < 1 || to > tour.steps.length) {
    throw new Error(`invalid position ${to} (the tour has ${plural(tour.steps.length, "step")})`);
  }
  const [step] = tour.steps.splice(from - 1, 1);
  tour.steps.splice(to - 1, 0, step);
}

/** Removes steps (1-based). */
export function removeSteps(tour: CodeTour, numbers: number[]) {
  numbers.forEach(number => checkStep(tour, number));
  [...new Set(numbers)]
    .sort((a, b) => b - a)
    .forEach(number => tour.steps.splice(number - 1, 1));
}
