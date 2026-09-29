// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

import { observable } from "mobx";
import { CommentThread, Uri } from "vscode";
import { CodeTour, CodeTourStep } from "../core/types";

export type { CodeTour, CodeTourStep, CodeTourStepPosition } from "../core/types";

export interface ActiveTour {
  tour: CodeTour;
  step: number;

  // When recording, a tour can be active, without
  // having created an actual comment yet.
  thread: CommentThread | null | undefined;

  // In order to resolve relative file
  // paths, we need to know the workspace root
  workspaceRoot?: Uri;

  // In order to resolve inter-tour
  // links, the active tour might need
  // the context of its sibling tours, if
  // they're coming from somewhere other
  // then the active workspace (e.g. a
  // GistPad-managed repo).
  tours?: CodeTour[];
}

type CodeTourProgress = [string, number[]];
export type CodeTourStepTuple = [CodeTour, CodeTourStep, number, number?];

export interface Store {
  tours: CodeTour[];
  activeTour: ActiveTour | null;
  activeEditorSteps?: CodeTourStepTuple[];
  hasTours: boolean;
  isRecording: boolean;
  isEditing: boolean;
  showMarkers: boolean;
  progress: CodeTourProgress[];
}

export const store: Store = observable({
  tours: [],
  activeTour: null,
  isRecording: false,
  isEditing: false,
  get hasTours() {
    return this.tours.length > 0;
  },
  showMarkers: false,
  progress: []
});
