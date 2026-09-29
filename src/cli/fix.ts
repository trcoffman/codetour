// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

// Re-anchors steps after the code changed. The base is the commit where the
// tour file was last changed: steps that are the same in that version of the
// tour are assumed to have been correct for that commit's code, and their
// lines are mapped through the diff between that code and the working tree
// (following renamed files). Steps added or changed since then were written
// against the current code, so they're left alone.

import * as fs from "fs";
import * as path from "path";
import { resolveStepLine, splitLines } from "../core/anchor";
import { findLine, mapLine, parseHunks } from "../core/drift";
import { parseTour } from "../core/tourFile";
import { CodeTour, CodeTourStep } from "../core/types";
import { git, repositoryRoot } from "./git";
import { readText } from "./workspace";

export interface StepFix {
  step: number;
  status: "moved" | "unresolved";
  changes: string[];
  message?: string;
  file?: string;
  line?: number;
  selection?: [number, number];
}

export interface FixPlan {
  base?: string;
  /** Why the tour was skipped. */
  skipped?: string;
  steps: StepFix[];
}

function realpath(file: string) {
  try {
    return fs.realpathSync(file);
  } catch {
    return file;
  }
}

function toPosix(file: string) {
  return file.split(path.sep).join("/");
}

/** Identifies how a step is anchored, to find steps unchanged since the base. */
function anchorKey(step: CodeTourStep) {
  if (!step.file || step.contents !== undefined) {
    return;
  }
  const { line, selection, pattern } = step;
  const anchor = line
    ? `line ${line}`
    : selection
    ? `selection ${JSON.stringify(selection)}`
    : pattern
    ? `pattern ${pattern}`
    : undefined;
  return anchor && `${step.file}\0${anchor}`;
}

/** Files renamed since `base` (repository-relative old path → new path). */
function findRenames(repo: string, base: string) {
  const renames = new Map<string, string>();
  const output = git(repo, ["diff", "-M", "--name-status", "--no-color", base]) || "";
  for (const line of output.split("\n")) {
    const match = line.match(/^R\d*\t([^\t]+)\t([^\t]+)$/);
    if (match) {
      renames.set(match[1], match[2]);
    }
  }
  return renames;
}

export function planFix(tour: CodeTour, root: string, { base: givenBase }: { base?: string } = {}): FixPlan {
  if (tour.ref && tour.ref !== "HEAD") {
    return { skipped: `it's pinned to ${JSON.stringify(tour.ref)}, so it doesn't drift`, steps: [] };
  }
  const repo = repositoryRoot(root);
  if (!repo) {
    return { skipped: "the workspace isn't a git repository", steps: [] };
  }
  const repoRoot = realpath(repo);
  const tourPath = toPosix(path.relative(repoRoot, realpath(tour.id)));

  const base = givenBase || (git(repo, ["log", "-1", "--format=%H", "--", tourPath]) || "").trim();
  if (!base) {
    return { skipped: "the tour hasn't been committed yet, so there's nothing to compare it with", steps: [] };
  }
  const short = base.slice(0, 12);

  const baseSource = git(repo, ["show", `${base}:${tourPath}`]);
  if (baseSource === undefined) {
    return { base, skipped: `the tour didn't exist at ${short}`, steps: [] };
  }
  let baseTour: CodeTour;
  try {
    baseTour = parseTour(baseSource, tour.id);
  } catch {
    return { base, skipped: `the tour isn't valid at ${short}`, steps: [] };
  }
  const unchanged = new Set(baseTour.steps.map(anchorKey).filter(key => key !== undefined));

  const renames = findRenames(repo, base);
  const files = new Map<string, { oldText: string; oldLines: string[]; newText: string; newLines: string[]; diff: string } | undefined>();
  const plan: FixPlan = { base, steps: [] };

  tour.steps.forEach((step, index) => {
    const key = anchorKey(step);
    if (!key || !unchanged.has(key)) {
      return;
    }
    const oldPath = toPosix(path.relative(repoRoot, realpath(path.resolve(root, step.file!))));
    const newPath = renames.get(oldPath) || oldPath;
    const cacheKey = `${oldPath}\0${newPath}`;
    if (!files.has(cacheKey)) {
      const oldText = git(repo, ["show", `${base}:${oldPath}`]);
      const newText = readText(path.join(repoRoot, newPath));
      files.set(
        cacheKey,
        oldText !== undefined && newText !== undefined
          ? {
              oldText,
              oldLines: splitLines(oldText),
              newText,
              newLines: splitLines(newText),
              diff: git(repo, ["diff", "-U0", "--no-color", "-M", base, "--", oldPath, newPath]) || ""
            }
          : undefined
      );
    }

    const fix: StepFix = { step: index + 1, status: "moved", changes: [] };
    const file = files.get(cacheKey);
    if (!file) {
      const exists = fs.existsSync(path.join(repoRoot, newPath));
      plan.steps.push({
        ...fix,
        status: "unresolved",
        message: exists
          ? `${step.file} didn't exist at ${short}`
          : `${step.file} no longer exists (if it was renamed, stage the rename with \`git mv\` or \`git add\` so fix can follow it)`
      });
      return;
    }

    if (newPath !== oldPath) {
      fix.file = toPosix(path.relative(root, path.join(repoRoot, newPath)));
      fix.changes.push(`file ${step.file} → ${fix.file}`);
    }
    const shownFile = fix.file || step.file!;

    if (!step.line && !step.selection) {
      // A pattern step: it follows its line by itself, unless the line changed.
      const now = resolveStepLine({ ...tour, steps: [{ ...step, file: shownFile }] }, 0, file.newText);
      if (now.problem) {
        const then = resolveStepLine(tour, index, file.oldText);
        const oldLine = then.line !== undefined ? file.oldLines[then.line] : undefined;
        fix.status = "unresolved";
        fix.message = `the pattern no longer matches ${shownFile}${
          oldLine !== undefined ? ` (at ${short} it matched line ${then.line! + 1}: ${JSON.stringify(oldLine.trim())})` : ""
        }; re-anchor it by hand`;
      }
      if (fix.status === "unresolved" || fix.changes.length > 0) {
        plan.steps.push(fix);
      }
      return;
    }

    const hunks = parseHunks(file.diff);
    const remap = (line: number, what: string) => {
      const mapped = mapLine(hunks, line);
      const newLine = mapped.line ?? findLine(file.newLines, file.oldLines[line - 1], line + mapped.shift);
      if (newLine === undefined) {
        fix.status = "unresolved";
        fix.message = `${what} ${line} of ${shownFile} (${JSON.stringify(
          (file.oldLines[line - 1] || "").trim()
        )}) changed since ${short}; re-anchor it by hand`;
        return line;
      }
      if (newLine !== line) {
        fix.changes.push(`${what} ${line} → ${newLine}`);
      }
      return newLine;
    };

    if (step.line) {
      fix.line = remap(step.line, "line");
    }
    if (step.selection) {
      fix.selection = [remap(step.selection.start.line, "selection start"), remap(step.selection.end.line, "selection end")];
    }
    if (fix.status === "unresolved" || fix.changes.length > 0) {
      plan.steps.push(fix);
    }
  });

  return plan;
}

/**
 * Applies a plan (not saved). Steps that couldn't be re-anchored are left
 * untouched, so `validate` and `fix` keep reporting them until they're fixed
 * by hand. Returns the number of changed steps.
 */
export function applyFix(tour: CodeTour, plan: FixPlan) {
  let changed = 0;
  for (const fix of plan.steps) {
    if (fix.status !== "moved") {
      continue;
    }
    const step = tour.steps[fix.step - 1];
    if (fix.file) {
      step.file = fix.file;
    }
    if (fix.line !== undefined) {
      step.line = fix.line;
    }
    if (fix.selection && step.selection) {
      step.selection.start.line = fix.selection[0];
      step.selection.end.line = fix.selection[1];
    }
    changed++;
  }
  return changed;
}
