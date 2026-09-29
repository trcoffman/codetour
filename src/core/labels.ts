// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

import { CodeTour } from "./types";

const HEADING_PATTERN = /^#+\s*(.*)/;

export function getStepLabel(
  tour: CodeTour,
  stepNumber: number,
  includeStepNumber: boolean = true,
  defaultToFileName: boolean = true
) {
  const step = tour.steps[stepNumber];

  const prefix = includeStepNumber ? `#${stepNumber + 1} - ` : "";
  let label = "";
  if (step.title) {
    label = step.title;
  } else if (HEADING_PATTERN.test(step.description.trim())) {
    label = step.description.trim().match(HEADING_PATTERN)![1];
  } else if (step.markerTitle) {
    label = step.markerTitle;
  } else if (defaultToFileName) {
    label = step.uri
      ? step.uri!
      : decodeURIComponent(step.directory || step.file!);
  }

  return `${prefix}${label}`;
}

export function getTourTitle(tour: CodeTour) {
  if (tour.title.match(/^#?\d+\s-/)) {
    return tour.title.split("-")[1].trim();
  }

  return tour.title;
}

export function getTourNumber(tour: CodeTour): number | undefined {
  const match = tour.title.match(/^#?(\d+)\s+-/);
  if (match) {
    return Number(match[1]);
  }
}

export function getStepMarkerPrefix(tour: CodeTour): string | undefined {
  if (tour.stepMarker) {
    return tour.stepMarker;
  } else {
    const tourNumber = getTourNumber(tour);
    if (tourNumber) {
      return `CT${tourNumber}`;
    }
  }
}

export function isMarkerTour(tour: CodeTour): boolean {
  return !!getStepMarkerPrefix(tour);
}

export function isMarkerStep(tour: CodeTour, stepNumber: number) {
  const step = tour.steps[stepNumber];
  return !!getStepMarkerPrefix(tour) && !!step.file && !step.line;
}

/** The pattern that locates a marker step (e.g. "CT1.3"), if it is one. */
export function getStepMarker(
  tour: CodeTour,
  stepNumber: number
): string | undefined {
  if (!isMarkerStep(tour, stepNumber)) {
    return;
  }

  return `${getStepMarkerPrefix(tour)}.${stepNumber + 1}`;
}

/** Finds the title of a marker step (`// CT1.3 - Title`) in its file. */
export function findMarkerTitle(
  tour: CodeTour,
  stepNumber: number,
  contents: string
): string | undefined {
  const markerPattern = new RegExp(
    `${getStepMarkerPrefix(tour)}\\.${stepNumber + 1}\\s*[-:]\\s*(.*)`
  );

  const match = contents.match(markerPattern);
  if (match) {
    return match[1];
  }
}
