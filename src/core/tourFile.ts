// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

import * as jexl from "jexl";
import { CodeTour } from "./types";

export const SCHEMA_URL = "https://aka.ms/codetour-schema";

export const VSCODE_DIRECTORY = ".vscode";

/** Well-known files that hold a single tour. */
export const MAIN_TOUR_FILES = [
  ".tour",
  `${VSCODE_DIRECTORY}/main.tour`,
  "main.tour"
];

/** Directories whose files (including subdirectories) are tours. */
export const SUB_TOUR_DIRECTORIES = [
  `${VSCODE_DIRECTORY}/tours`,
  ".github/tours",
  `.tours`
];

export const DEFAULT_TOUR_DIRECTORY = ".tours";

export function getTourDirectories(customTourDirectory?: string | null) {
  return customTourDirectory
    ? [...SUB_TOUR_DIRECTORIES, customTourDirectory]
    : [...SUB_TOUR_DIRECTORIES];
}

/** The file name used for a new tour with this title. */
export function getTourFileName(title: string) {
  const file = title
    .toLocaleLowerCase()
    .replace(/\s/g, "-")
    .replace(/[^\w\d\-_]/g, "");

  return `${file}.tour`;
}

/** Parses a tour file. The tour's `id` is set to `id`. */
export function parseTour(contents: string, id: string): CodeTour {
  const tour = JSON.parse(contents);
  if (typeof tour !== "object" || tour === null || Array.isArray(tour)) {
    throw new Error("a tour must be a JSON object");
  }
  if (typeof tour.title !== "string") {
    throw new Error('a tour must have a "title"');
  }
  if (!Array.isArray(tour.steps)) {
    throw new Error('a tour must have a "steps" array');
  }
  tour.id = id;
  return tour;
}

/**
 * Serializes a tour the way it's saved: the schema first, without the
 * properties that only exist at runtime (`id`, `markerTitle`).
 */
export function formatTour(
  tour: CodeTour,
  { schema = true }: { schema?: boolean } = {}
): string {
  const newTour: any = schema ? { $schema: SCHEMA_URL, ...tour } : { ...tour };

  delete newTour.id;
  if (Array.isArray(newTour.steps)) {
    newTour.steps = newTour.steps.map((step: any) => {
      const { markerTitle, ...rest } = step;
      return rest;
    });
  }

  return JSON.stringify(newTour, null, 2);
}

/** Variables available to `when` clauses. */
export interface TourContext {
  isLinux: boolean;
  isMac: boolean;
  isWindows: boolean;
  isWeb: boolean;
  [name: string]: unknown;
}

/**
 * Evaluates a tour's `when` clause. Tours whose clause can't be evaluated are
 * hidden (and the error is returned).
 */
export function evaluateWhen(
  tour: CodeTour,
  context: TourContext
): { visible: boolean; error?: string } {
  if (!tour.when) {
    return { visible: true };
  }

  try {
    return { visible: !!jexl.evalSync(tour.when, context) };
  } catch (e) {
    return { visible: false, error: e instanceof Error ? e.message : String(e) };
  }
}

export function compareTours(a: CodeTour, b: CodeTour) {
  return a.title.localeCompare(b.title);
}
