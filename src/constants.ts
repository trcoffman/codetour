// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

import { Uri } from "vscode";

// Prefix of every command, setting, context key and view registered by this extension.
export const EXTENSION_NAME = "codetourPlus";

// The full extension ID (`publisher.name` from package.json).
export const EXTENSION_ID = "TylerCoffman.codetour-plus";

// The `.tour` format (shared with the `codetour` CLI and the Neovim plugin) refers to
// commands as `codetour.<name>`, which is what the original CodeTour extension registered.
const TOUR_FILE_COMMAND_PREFIX = "codetour.";

/** Maps a command named in a `.tour` file (`codetour.nextTourStep`) to the one this extension registers. */
export function toExtensionCommand(command: string) {
  return command.startsWith(TOUR_FILE_COMMAND_PREFIX)
    ? `${EXTENSION_NAME}.${command.slice(TOUR_FILE_COMMAND_PREFIX.length)}`
    : command;
}

export const FS_SCHEME = "codetour-plus";
export const FS_SCHEME_CONTENT = `${FS_SCHEME}-content`;
export const CONTENT_URI = Uri.parse(`${FS_SCHEME_CONTENT}://current/CodeTour`);

export const ICON_URL =
  "https://cdn.jsdelivr.net/gh/trcoffman/codetour/images/icon.png";
export const SMALL_ICON_URL =
  "https://cdn.jsdelivr.net/gh/trcoffman/codetour/images/icon-small.png";

export const VSCODE_DIRECTORY = ".vscode";
