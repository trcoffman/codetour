// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

// Checks tours for problems: steps pointing at files, lines or patterns that
// don't exist, broken links between steps and tours, and so on.

import * as jsonc from "jsonc-parser";
import { lineOfOffset, resolveStepLine, splitLines } from "./anchor";
import { plural } from "./edit";
import { getTourTitle } from "./labels";
import { findReferences, parseCommand, Reference } from "./markdown";
import { evaluateWhen, TourContext } from "./tourFile";
import { CodeTour, CodeTourStep } from "./types";

export interface Diagnostic {
  severity: "error" | "warning";
  message: string;
  /** 1-based step number */
  step?: number;
  /** 1-based line in the tour file (when its source is known) */
  line: number;
}

/** File access for the validator; paths are relative to the workspace. */
export interface ValidationHost {
  /** A file's contents (as of `ref`, for tours pinned to a git ref). */
  readFile(path: string, ref?: string): string | undefined;
  isDirectory(path: string): boolean;
  /** Whether an absolute path exists (for `file://` URIs). */
  exists(path: string): boolean;
  /** Whether a git ref exists; undefined when that can't be checked. */
  refExists?(ref: string): boolean | undefined;
  context: TourContext;
}

export interface ValidationOptions {
  /** The workspace's tours, for links between tours. */
  tours?: CodeTour[];
  /** The tour file's text, to report the line of each problem. */
  source?: string;
}

/** Maps steps (and tour properties) to lines of the tour file. */
export function sourceLines(source: string | undefined) {
  const tree = source !== undefined ? jsonc.parseTree(source) : undefined;
  const line = (node: jsonc.Node | undefined) =>
    node && source !== undefined ? lineOfOffset(source, node.offset) + 1 : 1;
  return {
    step: (index: number) => line(tree && jsonc.findNodeAtLocation(tree, ["steps", index])),
    property: (name: string) => {
      const node = tree && jsonc.findNodeAtLocation(tree, [name]);
      return line(node && node.parent);
    }
  };
}

function isPosition(value: any) {
  return (
    value &&
    Number.isInteger(value.line) &&
    Number.isInteger(value.character) &&
    value.line >= 1 &&
    value.character >= 1
  );
}

/** Validates a tour. */
export function validateTour(
  tour: CodeTour,
  host: ValidationHost,
  { tours = [], source }: ValidationOptions = {}
): Diagnostic[] {
  const diagnostics: Diagnostic[] = [];
  const lines = sourceLines(source);
  const findTour = (title: unknown) =>
    [tour, ...tours].find(candidate => candidate.title === title);

  const tourProblem = (severity: Diagnostic["severity"], property: string | undefined, message: string) =>
    diagnostics.push({ severity, message, line: property ? lines.property(property) : 1 });

  // Tour properties

  if (tour.when) {
    const { error } = evaluateWhen(tour, host.context);
    if (error) {
      tourProblem("error", "when", `the \`when\` clause ${JSON.stringify(tour.when)} can't be evaluated: ${error}`);
    }
  }
  if (tour.nextTour !== undefined && !findTour(tour.nextTour)) {
    tourProblem("error", "nextTour", `\`nextTour\` refers to a tour that doesn't exist: ${JSON.stringify(tour.nextTour)}`);
  }
  if (tour.ref && tour.ref !== "HEAD" && host.refExists && host.refExists(tour.ref) === false) {
    tourProblem("error", "ref", `the git ref ${JSON.stringify(tour.ref)} doesn't exist`);
  }
  if (tour.steps.length === 0) {
    tourProblem("warning", "steps", "the tour doesn't have any steps");
  }

  // Steps

  const anchored = new Map<string, number>();
  const contents = new Map<string, string | undefined>();
  const readFile = (file: string) => {
    if (!contents.has(file)) {
      contents.set(file, host.readFile(file, tour.ref && tour.ref !== "HEAD" ? tour.ref : undefined));
    }
    return contents.get(file);
  };

  tour.steps.forEach((step: CodeTourStep, index) => {
    const number = index + 1;
    const problem = (severity: Diagnostic["severity"], message: string) =>
      diagnostics.push({ severity, message: `step #${number}${message}`, step: number, line: lines.step(index) });

    if (typeof step.description !== "string" || !step.description.trim()) {
      problem("warning", " doesn't have a description");
    }

    const kinds = ["file", "directory", "uri"].filter(key => (step as any)[key] !== undefined);
    if (kinds.length > 1) {
      problem("warning", `: sets ${kinds.join(" and ")}; only one of them should be set`);
    }

    if (step.file && step.contents === undefined) {
      const errorsBefore = diagnostics.filter(d => d.severity === "error").length;
      const text = readFile(step.file);
      if (text === undefined) {
        problem("error", `: file not found: ${step.file}${tour.ref ? ` (at ${tour.ref})` : ""}`);
      } else {
        const fileLines = splitLines(text);

        if (step.line !== undefined) {
          if (!Number.isInteger(step.line) || step.line < 1) {
            problem("error", ": `line` must be a positive whole number");
          } else if (step.line > fileLines.length) {
            problem("error", `: line ${step.line} is past the end of ${step.file} (${plural(fileLines.length, "line")})`);
          } else if (!fileLines[step.line - 1].trim()) {
            problem("warning", `: line ${step.line} of ${step.file} is blank`);
          }
        }

        const selection: any = step.selection;
        if (selection !== undefined) {
          if (!isPosition(selection && selection.start) || !isPosition(selection && selection.end)) {
            problem("error", ": `selection` needs 1-based `start` and `end` positions");
          } else if (
            selection.start.line > selection.end.line ||
            (selection.start.line === selection.end.line && selection.start.character > selection.end.character)
          ) {
            problem("error", ": the selection ends before it starts");
          } else {
            for (const position of [selection.start, selection.end]) {
              const text = fileLines[position.line - 1];
              if (text === undefined) {
                problem("error", `: the selection goes past the end of ${step.file} (${plural(fileLines.length, "line")})`);
                break;
              } else if (position.character > text.length + 1) {
                problem("error", `: the selection goes past the end of line ${position.line} of ${step.file}`);
                break;
              }
            }
          }
        }

        const anchor = resolveStepLine(tour, index, text);
        if (anchor.problem) {
          problem("error", `: ${anchor.problem} in ${step.file}`);
        } else if (anchor.kind === "pattern") {
          const matches = text.match(new RegExp(step.pattern!, "gm"));
          if (matches && matches.length > 1) {
            problem(
              "warning",
              `: the pattern matches ${matches.length} lines of ${step.file}; the first one (line ${anchor.line! + 1}) is used`
            );
          }
        } else if (anchor.kind === "end") {
          problem("warning", ` doesn't have a line or pattern, so it's shown at the end of ${step.file}`);
        }

        const hasErrors = diagnostics.filter(d => d.severity === "error").length > errorsBefore;
        if (anchor.line !== undefined && !hasErrors) {
          const key = `${step.file}:${anchor.line}`;
          const other = anchored.get(key);
          if (other) {
            problem("warning", ` is on the same line as step #${other} (line ${anchor.line + 1} of ${step.file})`);
          } else {
            anchored.set(key, number);
          }
        }
      }
    } else if (step.directory !== undefined) {
      if (!host.isDirectory(step.directory)) {
        problem("error", `: directory not found: ${step.directory}`);
      }
    } else if (step.uri && step.uri.startsWith("file://")) {
      let path = step.uri;
      try {
        path = decodeURIComponent(step.uri.replace(/^file:\/\//, ""));
      } catch {}
      if (!host.exists(path)) {
        problem("error", `: file not found: ${step.uri}`);
      }
    }

    // Links and commands

    const references: Reference[] = findReferences(step.description || "");
    for (const command of Array.isArray(step.commands) ? step.commands : []) {
      references.push({ kind: "command", ...parseCommand(command) });
    }

    const checkTourLink = (title: unknown, stepNumber: unknown) => {
      const target = findTour(title);
      if (!target) {
        problem("error", ` links to a tour that doesn't exist: ${JSON.stringify(title)}`);
      } else if (stepNumber !== undefined && !target.steps[Number(stepNumber) - 1]) {
        problem(
          "error",
          ` links to step #${stepNumber} of ${JSON.stringify(target.title)}, which has ${plural(target.steps.length, "step")}`
        );
      }
    };

    for (const reference of references) {
      if (reference.kind === "step" || (reference.kind === "command" && reference.name === "codetour.navigateToStep")) {
        const target = reference.kind === "step" ? reference.step : Number(reference.args[0]);
        if (!tour.steps[target - 1]) {
          problem("error", ` links to step #${target}, but the tour has ${plural(tour.steps.length, "step")}`);
        }
      } else if (reference.kind === "tour") {
        // `[Some text]` is only a tour link if a tour has that title (without
        // its "1 - " prefix, like the player).
        const target = [tour, ...tours].find(candidate => getTourTitle(candidate) === reference.title);
        if (target) {
          checkTourLink(target.title, reference.step);
        } else if (reference.step !== undefined) {
          problem("warning", ` links to [${reference.title}#${reference.step}], but no tour is titled ${JSON.stringify(reference.title)}`);
        }
      } else if (reference.kind === "command") {
        if (reference.name === "codetour.startTourByTitle") {
          checkTourLink(reference.args[0], reference.args[1]);
        } else if (reference.name === "codetour.finishTour" && reference.args[0] !== undefined) {
          checkTourLink(reference.args[0], undefined);
        }
      } else if (reference.kind === "file") {
        const path = reference.path.replace(/^\.\//, "");
        if (host.readFile(path) === undefined && !host.isDirectory(path)) {
          problem("warning", ` links to a file that doesn't exist: ${reference.path}`);
        }
      }
    }
  });

  return diagnostics;
}

/** Problems that involve several tours: duplicate titles, several primary tours. */
export function validateWorkspace(tours: CodeTour[]): { tour: CodeTour; diagnostic: Diagnostic }[] {
  const problems: { tour: CodeTour; diagnostic: Diagnostic }[] = [];
  const seen = new Map<string, CodeTour>();
  for (const tour of tours) {
    const other = seen.get(tour.title);
    if (other) {
      problems.push({
        tour,
        diagnostic: { severity: "warning", line: 1, message: `another tour (${other.id}) has the same title` }
      });
    } else {
      seen.set(tour.title, tour);
    }
  }
  const primary = tours.filter(tour => tour.isPrimary);
  if (primary.length > 1) {
    for (const tour of primary) {
      problems.push({
        tour,
        diagnostic: { severity: "warning", line: 1, message: `${primary.length} tours are marked as primary` }
      });
    }
  }
  return problems;
}
