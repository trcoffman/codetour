// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

import { spawnSync } from "child_process";
import * as path from "path";
import { CodeTour, LAST_EDIT_REF } from "../core/types";

/** Runs git; returns stdout, or undefined when git fails or isn't installed. */
export function git(cwd: string, args: string[]): string | undefined {
  const result = spawnSync("git", ["-C", cwd, ...args], {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024
  });
  if (result.error || result.status !== 0) {
    return undefined;
  }
  return result.stdout;
}

export function repositoryRoot(cwd: string) {
  const root = git(cwd, ["rev-parse", "--show-toplevel"]);
  return root ? root.trim() : undefined;
}

export function resolveRef(cwd: string, ref: string) {
  const commit = git(cwd, ["rev-parse", "--verify", "--quiet", `${ref}^{commit}`]);
  return commit ? commit.trim() : undefined;
}

/**
 * Whether files of a tour pinned to `ref` are read from git rather than the
 * working tree. Mirrors the VS Code extension: the working tree is used when
 * the ref is the current branch or points at the current commit.
 */
export function shouldUseRef(cwd: string, ref: string | undefined) {
  if (!ref || ref === "HEAD" || !repositoryRoot(cwd)) {
    return false;
  }
  const branch = git(cwd, ["symbolic-ref", "--quiet", "--short", "HEAD"]);
  const head = resolveRef(cwd, "HEAD");
  return !(
    (branch && branch.trim() === ref) ||
    head === ref ||
    (head !== undefined && resolveRef(cwd, ref) === head)
  );
}

/** A file as of `ref`; `path` is relative to `cwd`. */
export function showFile(cwd: string, ref: string, path: string) {
  return git(cwd, ["show", `${ref}:./${path}`]);
}

/**
 * The most recent commit that modified the tour file, which is what a
 * `last-edit` tour is pinned to. Undefined (the working tree is used) when
 * the file has uncommitted changes, isn't tracked yet or isn't in a repository.
 */
export function lastEditCommit(tourFile: string) {
  const cwd = path.dirname(tourFile);
  const file = path.basename(tourFile);
  const status = git(cwd, ["status", "--porcelain", "--", file]);
  if (status === undefined || status.trim() !== "") {
    return undefined;
  }
  const commit = git(cwd, ["log", "-1", "--format=%H", "--", file]);
  return commit ? commit.trim() || undefined : undefined;
}

/** The git ref a tour's files are read at, or undefined for the working tree. */
export function tourRef(tour: CodeTour) {
  if (tour.ref === LAST_EDIT_REF) {
    return lastEditCommit(tour.id);
  }
  return tour.ref && tour.ref !== "HEAD" ? tour.ref : undefined;
}
