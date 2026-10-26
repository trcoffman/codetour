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
import { LAST_EDIT_REF } from "./core/types";
import { api, Repository } from "./git";
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

// Finding the latest commit that modified a tour runs `git log`, so the answer
// is kept until HEAD moves.
const lastEditCommits = new Map<string, { head: string; commit?: string }>();

/**
 * The commit a `last-edit` tour is pinned to: the latest one that modified
 * the tour file. Undefined (the working tree is used) when the tour isn't a
 * file in this repository, or the file has uncommitted changes, so that a
 * tour being edited isn't shown against older code.
 */
async function getLastEditCommit(
  tour: CodeTour,
  repo: Repository
): Promise<string | undefined> {
  const tourUri = Uri.parse(tour.id);
  const head = repo.state.HEAD?.commit;
  if (tourUri.scheme !== "file" || !head) {
    return;
  }

  const changed = [
    ...repo.state.indexChanges,
    ...repo.state.workingTreeChanges
  ].some(change => change.uri.fsPath === tourUri.fsPath);
  if (changed) {
    return;
  }

  const cached = lastEditCommits.get(tour.id);
  if (cached?.head === head) {
    return cached.commit;
  }

  const [latest] = await repo.log({ maxEntries: 1, path: tourUri.fsPath });
  lastEditCommits.set(tour.id, { head, commit: latest?.hash });
  return latest?.hash;
}

export async function getStepFileUri(
  step: CodeTourStep,
  workspaceRoot?: Uri,
  tour?: CodeTour
): Promise<Uri> {
  let ref = tour?.ref;
  let uri;
  if (step.contents) {
    uri = Uri.parse(`${FS_SCHEME}://current/${step.file}`);
  } else if (step.uri || step.file) {
    uri = step.uri
      ? Uri.parse(step.uri)
      : getFileUri(step.file!, workspaceRoot);

    if (api && tour && ref && ref !== "HEAD") {
      const repo = api.getRepository(uri);

      if (repo && ref === LAST_EDIT_REF) {
        ref = await getLastEditCommit(tour, repo);
      }

      if (
        ref &&
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
    tour
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
