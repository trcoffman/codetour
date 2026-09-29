// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

// The tour format (see schema.json). This module is shared by the VS Code
// extension and the `codetour` CLI, so it must not depend on VS Code or Node.

export interface CodeTourStepPosition {
  line: number;
  character: number;
}

export interface CodeTourStep {
  title?: string;
  description: string;
  icon?: string;

  // If any of the following are set, then only
  // one of them can be, since these properties
  // indicate the "type" of step.
  file?: string;
  directory?: string;
  contents?: string;
  uri?: string;
  view?: string;

  // A line number and selection is only relevant for file-based
  // steps. And even then, they're optional. If a file-based step
  // doesn't have a line number, then the description is attached
  // to the last line in the file, assuming it's describing the file itself
  line?: number;
  selection?: { start: CodeTourStepPosition; end: CodeTourStepPosition };

  commands?: string[];

  pattern?: string;
  markerTitle?: string;
}

export interface CodeTour {
  id: string;
  title: string;
  description?: string;
  steps: CodeTourStep[];
  ref?: string;
  isPrimary?: boolean;
  nextTour?: string;
  stepMarker?: string;
  when?: string;
}
