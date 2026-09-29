// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

// Re-anchoring steps after the code changed ("tour drift"). A step's line is
// mapped through the diff between the code it was written for and the
// current code.

export interface Hunk {
  oldStart: number;
  oldCount: number;
  newStart: number;
  newCount: number;
}

/** Parses the hunk headers of `git diff -U0` output. */
export function parseHunks(diff: string): Hunk[] {
  const hunks: Hunk[] = [];
  const header = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/gm;
  let match;
  while ((match = header.exec(diff))) {
    hunks.push({
      oldStart: Number(match[1]),
      oldCount: match[2] === undefined ? 1 : Number(match[2]),
      newStart: Number(match[3]),
      newCount: match[4] === undefined ? 1 : Number(match[4])
    });
  }
  return hunks;
}

/**
 * Maps a 1-based line of the old file to the new file. Returns `line`
 * undefined when the line itself changed (`shift` is still the offset of the
 * lines before it).
 */
export function mapLine(hunks: Hunk[], line: number): { line?: number; shift: number } {
  let shift = 0;
  for (const hunk of hunks) {
    if (hunk.oldCount === 0) {
      // Lines were inserted after `oldStart`.
      if (hunk.oldStart < line) {
        shift += hunk.newCount;
      } else {
        break;
      }
    } else if (line < hunk.oldStart) {
      break;
    } else if (line < hunk.oldStart + hunk.oldCount) {
      return { shift };
    } else {
      shift += hunk.newCount - hunk.oldCount;
    }
  }
  return { line: line + shift, shift };
}

/**
 * Finds where a changed line's old text went: the match nearest to `near`
 * (1-based), exact matches first, then ignoring indentation.
 */
export function findLine(lines: string[], text: string | undefined, near: number) {
  if (!text || !text.trim()) {
    return;
  }
  for (const same of [
    (line: string) => line === text,
    (line: string) => line.trim() === text.trim()
  ]) {
    let best: number | undefined;
    lines.forEach((line, index) => {
      const number = index + 1;
      if (same(line) && (best === undefined || Math.abs(number - near) < Math.abs(best - near))) {
        best = number;
      }
    });
    if (best !== undefined) {
      return best;
    }
  }
}
