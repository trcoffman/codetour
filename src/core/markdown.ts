// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

// The syntax of "CodeTour-flavored markdown" (see the README), shared by the
// player (which turns it into links) and the validator.

export const SHELL_SCRIPT_PATTERN = /^>>\s+(?<script>.*)$/gm;

export const COMMAND_PATTERN =
  /(?<commandPrefix>\(command:[\w+\.]+\?)(?<params>\[[^\]\)]+\])/gm;

export const TOUR_REFERENCE_PATTERN =
  /(?:\[(?<linkTitle>[^\]]+)\])?\[(?=\s*[^\]\s])(?<tourTitle>[^\]#]+)?(?:#(?<stepNumber>\d+))?\](?!\()/gm;

export const FILE_REFERENCE_PATTERN = /(\!)?(\[[^\]]+\]\()(\.[^\)]+)(?=\))/gm;

export const CODE_FENCE_PATTERN = /```[^\n]+\n(.+)\n```/gms;

/** A command link, e.g. `[text](command:codetour.navigateToStep?2)`. */
const COMMAND_LINK_PATTERN =
  /\]\(command:(?<name>[\w+\.]+)(?:\?(?<args>\[[^\]\)]*\]|[^\s\)"]+))?/gm;

export type Reference =
  | { kind: "step"; step: number }
  | { kind: "tour"; title: string; step?: number }
  | { kind: "command"; name: string; args: unknown[] }
  | { kind: "file"; path: string; image: boolean };

/** Parses command arguments (`?[...]`, `?2`, or URL-encoded JSON). */
export function parseCommandArgs(raw: string | undefined): unknown[] {
  if (!raw) {
    return [];
  }
  let text = raw;
  if (/%[0-9a-f]{2}/i.test(text)) {
    try {
      text = decodeURIComponent(text);
    } catch {}
  }
  try {
    const value = JSON.parse(text);
    return Array.isArray(value) ? value : [value];
  } catch {
    return [text];
  }
}

/** Parses a step command such as `codetour.navigateToStep?2`. */
export function parseCommand(command: string): { name: string; args: unknown[] } {
  const index = command.indexOf("?");
  if (index === -1) {
    return { name: command, args: [] };
  }
  return {
    name: command.slice(0, index),
    args: parseCommandArgs(command.slice(index + 1))
  };
}

function* allMatches(pattern: RegExp, text: string) {
  const regex = new RegExp(pattern.source, pattern.flags);
  let match;
  while ((match = regex.exec(text))) {
    yield match;
    if (match[0] === "") {
      regex.lastIndex++;
    }
  }
}

/** Blanks out code blocks and inline code, which don't contain links. */
function withoutCode(text: string) {
  const blank = (match: string) => match.replace(/[^\n]/g, " ");
  return text.replace(/```[\s\S]*?```/g, blank).replace(/`[^`\n]*`/g, blank);
}

/** Finds the links to steps, tours, commands and files in a description. */
export function findReferences(description: string): Reference[] {
  const text = withoutCode(description);
  const references: Reference[] = [];

  for (const match of allMatches(COMMAND_LINK_PATTERN, text)) {
    references.push({
      kind: "command",
      name: match.groups!.name,
      args: parseCommandArgs(match.groups!.args)
    });
  }

  for (const match of allMatches(FILE_REFERENCE_PATTERN, text)) {
    references.push({ kind: "file", path: match[3], image: !!match[1] });
  }

  for (const match of allMatches(TOUR_REFERENCE_PATTERN, text)) {
    const { tourTitle, stepNumber } = match.groups!;
    const step = stepNumber ? Number(stepNumber) : undefined;
    if (!tourTitle) {
      references.push({ kind: "step", step: step! });
    } else {
      references.push({ kind: "tour", title: tourTitle, step });
    }
  }

  return references;
}
