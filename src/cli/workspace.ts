// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

import * as fs from "fs";
import * as jsonc from "jsonc-parser";
import * as os from "os";
import * as path from "path";
import {
  compareTours,
  DEFAULT_TOUR_DIRECTORY,
  evaluateWhen,
  getTourDirectories,
  getTourFileName,
  MAIN_TOUR_FILES,
  parseTour,
  TourContext
} from "../core/tourFile";
import { CodeTour } from "../core/types";
import { ValidationHost } from "../core/validate";
import { resolveRef, shouldUseRef, showFile } from "./git";

export interface LoadedTour {
  tour: CodeTour;
  source: string;
}

export interface BrokenTour {
  path: string;
  error: string;
}

const PLATFORM = os.platform();

/** Variables for `when` clauses (the CLI isn't an editor, so no isNeovim). */
export const TOUR_CONTEXT: TourContext = {
  isLinux: PLATFORM === "linux",
  isMac: PLATFORM === "darwin",
  isWindows: PLATFORM === "win32",
  isWeb: false
};

export function readText(file: string): string | undefined {
  try {
    return fs.readFileSync(file, "utf8");
  } catch {
    return undefined;
  }
}

export function isDirectory(file: string) {
  try {
    return fs.statSync(file).isDirectory();
  } catch {
    return false;
  }
}

function listFiles(directory: string, files: string[]) {
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(directory, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries.sort((a, b) => (a.name < b.name ? -1 : 1))) {
    const file = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      listFiles(file, files);
    } else if (entry.isFile() || entry.isSymbolicLink()) {
      files.push(file);
    }
  }
}

/** The workspace folders tours are discovered in (like VS Code's). */
export class Workspace {
  constructor(public readonly roots: string[]) {}

  /** `codetour.customTourDirectory` from the folder's .vscode/settings.json. */
  customTourDirectory(root: string): string | undefined {
    const text = readText(path.join(root, ".vscode", "settings.json"));
    const settings = text ? jsonc.parse(text) : undefined;
    const value = settings && settings["codetour.customTourDirectory"];
    return typeof value === "string" && value ? value : undefined;
  }

  /** Every file that may contain a tour (like VS Code, all files in the tour directories). */
  tourFiles(root: string): string[] {
    const files: string[] = [];
    for (const directory of getTourDirectories(this.customTourDirectory(root))) {
      listFiles(path.join(root, directory), files);
    }
    for (const file of MAIN_TOUR_FILES) {
      const full = path.join(root, file);
      try {
        if (fs.statSync(full).isFile()) {
          files.push(full);
        }
      } catch {}
    }
    return files;
  }

  /** Reads every tour of the workspace, sorted by title. */
  load({ all = false }: { all?: boolean } = {}): { tours: LoadedTour[]; broken: BrokenTour[] } {
    const tours: LoadedTour[] = [];
    const broken: BrokenTour[] = [];
    for (const root of this.roots) {
      for (const file of this.tourFiles(root)) {
        const loaded = loadTourFile(file);
        if ("error" in loaded) {
          // Other files in tour directories (e.g. a README) are ignored.
          if (file.endsWith(".tour")) {
            broken.push(loaded);
          }
        } else if (all || evaluateWhen(loaded.tour, TOUR_CONTEXT).visible) {
          tours.push(loaded);
        }
      }
    }
    tours.sort((a, b) => compareTours(a.tour, b.tour));
    return { tours, broken };
  }

  /** The workspace folder a tour belongs to. */
  rootOf(tour: CodeTour): string {
    const inside = this.roots
      .filter(root => tour.id.startsWith(root + path.sep))
      .sort((a, b) => b.length - a.length);
    return inside[0] || this.roots[0];
  }

  /** Where a new tour with this title is saved. */
  newTourPath(title: string, root = this.roots[0]) {
    return path.join(root, this.customTourDirectory(root) || DEFAULT_TOUR_DIRECTORY, getTourFileName(title));
  }

  /** File access for validating a tour (paths relative to its folder). */
  host(tour: CodeTour): ValidationHost {
    const root = this.rootOf(tour);
    const useRef = new Map<string, boolean>();
    return {
      context: TOUR_CONTEXT,
      readFile: (file, ref) => {
        if (ref) {
          if (!useRef.has(ref)) {
            useRef.set(ref, shouldUseRef(root, ref));
          }
          if (useRef.get(ref)) {
            return showFile(root, ref, file);
          }
        }
        const full = path.resolve(root, file);
        return isDirectory(full) ? undefined : readText(full);
      },
      isDirectory: file => isDirectory(path.resolve(root, file)),
      exists: file => fs.existsSync(file),
      refExists: ref => (resolveRef(root, "HEAD") === undefined ? undefined : resolveRef(root, ref) !== undefined)
    };
  }
}

export function loadTourFile(file: string): LoadedTour | BrokenTour {
  const source = readText(file);
  if (source === undefined) {
    return { path: file, error: "the file can't be read" };
  }
  try {
    return { tour: parseTour(source.replace(/^﻿/, ""), path.resolve(file)), source };
  } catch (e) {
    return { path: file, error: e instanceof Error ? e.message : String(e) };
  }
}
