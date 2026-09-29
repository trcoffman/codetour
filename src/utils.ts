// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

import * as os from "os";
import * as path from "path";
import { Uri, workspace } from "vscode";
import { CONTENT_URI, FS_SCHEME } from "./constants";
import {
  findMarkerTitle,
  getStepMarker,
  getStepMarkerPrefix,
  getTourNumber,
  isMarkerStep,
  isMarkerTour
} from "./core/labels";
import { api } from "./git";
import { CodeTour, CodeTourStep, store } from "./store";

export { getStepLabel, getTourTitle } from "./core/labels";

export function getRelativePath(root: string, filePath: string) {
  let relativePath = path.relative(root, filePath);

  if (os.platform() === "win32") {
    relativePath = relativePath.replace(/\\/g, "/");
  }

  return relativePath;
}

export async function readUriContents(uri: Uri) {
  const bytes = await workspace.fs.readFile(uri);
  return new TextDecoder().decode(bytes);
}

export function getFileUri(file: string, workspaceRoot?: Uri) {
  if (!workspaceRoot) {
    return Uri.parse(file);
  }

  return Uri.joinPath(workspaceRoot, file);
  //return appendUriPath(workspaceRoot, file);
}

export async function getStepFileUri(
  step: CodeTourStep,
  workspaceRoot?: Uri,
  ref?: string
): Promise<Uri> {
  let uri;
  if (step.contents) {
    uri = Uri.parse(`${FS_SCHEME}://current/${step.file}`);
  } else if (step.uri || step.file) {
    uri = step.uri
      ? Uri.parse(step.uri)
      : getFileUri(step.file!, workspaceRoot);

    if (api && ref && ref !== "HEAD") {
      const repo = api.getRepository(uri);

      if (
        repo &&
        repo.state.HEAD &&
        repo.state.HEAD.name !== ref && // The tour refs the user's current branch
        repo.state.HEAD.commit !== ref && // The tour refs the user's HEAD commit
        repo.state.HEAD.commit !== // The tour refs a branch/tag that points at the user's HEAD commit
          repo.state.refs.find(gitRef => gitRef.name === ref)?.commit
      ) {
        uri = await api.toGitUri(uri, ref);
      }
    }
  } else {
    uri = CONTENT_URI;
  }

  return uri;
}

export function getActiveWorkspacePath() {
  return store.activeTour!.workspaceRoot?.path || "";
}

export function getWorkspaceKey() {
  return workspace.workspaceFile || workspace.workspaceFolders![0].uri;
}

export function getWorkspacePath(tour: CodeTour) {
  return getWorkspaceUri(tour)?.toString() || "";
}

export function getWorkspaceUri(tour: CodeTour): Uri | undefined {
  const tourUri = Uri.parse(tour.id);
  return (
    workspace.getWorkspaceFolder(tourUri)?.uri ||
    (workspace.workspaceFolders && workspace.workspaceFolders[0].uri)
  );
}

export function getActiveTourNumber(): number | undefined {
  return getTourNumber(store.activeTour!.tour);
}

function getActiveStepMarkerPrefix(): string | undefined {
  return getStepMarkerPrefix(store.activeTour!.tour);
}

export function getActiveStepMarker(): string | undefined {
  return getStepMarker(store.activeTour!.tour, store.activeTour!.step);
}

export async function getStepMarkerForLine(uri: Uri, lineNumber: number) {
  const document = await workspace.openTextDocument(uri);
  const line = document.lineAt(lineNumber).text;

  const stepMarkerPrefix = getActiveStepMarkerPrefix();
  const match = line.match(new RegExp(`${stepMarkerPrefix}.(\\d+)`));
  if (match) {
    return Number(match[1]);
  }
}

async function updateMarkerTitleForStep(tour: CodeTour, stepNumber: number) {
  if (!isMarkerStep(tour, stepNumber)) {
    return;
  }

  const uri = await getStepFileUri(
    tour.steps[stepNumber],
    getWorkspaceUri(tour),
    tour.ref
  );

  const document = await workspace.openTextDocument(uri);
  const markerTitle = findMarkerTitle(tour, stepNumber, document.getText());
  if (markerTitle) {
    tour.steps[stepNumber].markerTitle = markerTitle;
  }
}

async function updateMarkerTitlesForTour(tour: CodeTour) {
  if (!isMarkerTour(tour)) {
    return;
  }

  tour.steps.forEach((_, index) => updateMarkerTitleForStep(tour, index));
}

export async function updateMarkerTitles() {
  store.tours.forEach(updateMarkerTitlesForTour);
}
