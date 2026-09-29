// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

import { resolveStepLine, splitLines } from "../core/anchor";
import { getStepLabel } from "../core/labels";
import { findReferences, parseCommand, Reference } from "../core/markdown";
import { CodeTour } from "../core/types";
import { ValidationHost } from "../core/validate";

export interface StepPreview {
  number: number;
  label: string;
  kind: string;
  file?: string;
  directory?: string;
  /** 1-based line the step is shown at */
  line?: number;
  /** 1-based, inclusive */
  selection?: [number, number];
  problem?: string;
  view?: string;
  excerpt?: { line: number; text: string; marked: boolean }[];
  description: string;
  links: { text: string; target: string }[];
}

function describeReference(reference: Reference): { text: string; target: string } {
  switch (reference.kind) {
    case "step":
      return { text: `[#${reference.step}]`, target: `step #${reference.step}` };
    case "tour":
      return {
        text: `[${reference.title}${reference.step ? `#${reference.step}` : ""}]`,
        target: `tour ${JSON.stringify(reference.title)}${reference.step ? ` (step #${reference.step})` : ""}`
      };
    case "file":
      return { text: reference.path, target: reference.path.replace(/^\.\//, "") };
    case "command": {
      const [first, second] = reference.args;
      const target =
        reference.name === "codetour.navigateToStep"
          ? `step #${first}`
          : reference.name === "codetour.startTourByTitle"
          ? `tour ${JSON.stringify(first)}${second ? ` (step #${second})` : ""}`
          : reference.name === "codetour.sendTextToTerminal"
          ? `run \`${first}\``
          : `command ${reference.name}${reference.args.length ? ` ${JSON.stringify(reference.args)}` : ""}`;
      return { text: `command:${reference.name}`, target };
    }
  }
}

/** Collects what a viewer sees for each step of a tour. */
export function previewTour(
  tour: CodeTour,
  host: ValidationHost,
  { context = 3, step: only }: { context?: number; step?: number } = {}
): StepPreview[] {
  const previews: StepPreview[] = [];
  tour.steps.forEach((step, index) => {
    const number = index + 1;
    if (only !== undefined && only !== number) {
      return;
    }

    const preview: StepPreview = {
      number,
      label: getStepLabel(tour, index, false, true),
      kind: "content",
      description: step.description || "",
      links: []
    };

    if (step.file || step.uri) {
      preview.file = step.file || step.uri;
      const contents =
        step.contents !== undefined ? step.contents : step.file ? host.readFile(step.file, tour.ref) : undefined;
      if (contents === undefined) {
        preview.kind = "file";
        preview.problem = "file not found";
      } else {
        const lines = splitLines(contents);
        const anchor = resolveStepLine(tour, index, contents);
        const line = anchor.line !== undefined ? Math.min(anchor.line, lines.length - 1) : lines.length - 1;
        preview.kind = anchor.kind;
        preview.line = line + 1;
        preview.problem = anchor.problem;
        let first = line + 1;
        if (step.selection) {
          preview.selection = [step.selection.start.line, Math.min(step.selection.end.line, lines.length)];
          first = Math.min(first, step.selection.start.line);
        }
        preview.excerpt = [];
        for (let n = Math.max(1, first - context); n <= Math.min(lines.length, line + 1 + context); n++) {
          const marked =
            n === line + 1 ||
            (preview.selection !== undefined && n >= preview.selection[0] && n <= preview.selection[1]);
          preview.excerpt.push({ line: n, text: lines[n - 1], marked });
        }
      }
    } else if (step.directory) {
      preview.kind = "directory";
      preview.directory = step.directory;
    }
    if (step.view) {
      preview.view = step.view;
    }

    preview.links = findReferences(step.description || "").map(describeReference);
    for (const command of Array.isArray(step.commands) ? step.commands : []) {
      const { target } = describeReference({ kind: "command", ...parseCommand(command) });
      preview.links.push({ text: "(runs when the step is shown)", target });
    }
    previews.push(preview);
  });
  return previews;
}

/** Formats previews as text. */
export function formatPreview(previews: StepPreview[]): string[] {
  const lines: string[] = [];
  for (const step of previews) {
    lines.push("");
    const where = step.file
      ? `${step.file}:${step.selection ? `${step.selection[0]}-${step.selection[1]}` : step.line ?? "?"} (${step.kind})`
      : step.directory
      ? `directory ${step.directory}`
      : "content step";
    lines.push(`#${step.number}  ${step.label || "(untitled)"} — ${where}`);
    if (step.problem) {
      lines.push(`    ! ${step.problem}`);
    }
    if (step.view) {
      lines.push(`    view: ${step.view}`);
    }
    for (const line of step.excerpt || []) {
      lines.push(`  ${line.marked ? ">" : " "} ${String(line.line).padStart(5)} │ ${line.text}`);
    }
    if (step.excerpt) {
      lines.push("");
    }
    for (const line of step.description.split("\n")) {
      lines.push(line ? `    ${line}` : "");
    }
    if (step.links.length > 0) {
      lines.push("    links:");
      for (const link of step.links) {
        lines.push(`      ${link.text} → ${link.target}`);
      }
    }
  }
  return lines;
}
