// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

type Kind = "boolean" | "string" | "number" | "list";

const GLOBAL_OPTIONS: Record<string, Kind> = { json: "boolean", root: "list", help: "boolean" };

export const COMMAND_OPTIONS: Record<string, Record<string, Kind>> = {
  list: {},
  show: { step: "number", context: "number", raw: "boolean" },
  validate: { strict: "boolean" },
  fmt: { check: "boolean" },
  new: {
    description: "string",
    file: "string",
    ref: "string",
    primary: "boolean",
    next: "string",
    when: "string"
  },
  add: {
    at: "string",
    dir: "string",
    content: "boolean",
    title: "string",
    description: "string",
    after: "number",
    before: "number",
    pattern: "boolean",
    icon: "string"
  },
  edit: {
    title: "string",
    description: "string",
    at: "string",
    dir: "string",
    pattern: "boolean",
    "no-pattern": "boolean",
    icon: "string",
    ref: "string",
    primary: "boolean",
    "no-primary": "boolean",
    next: "string",
    when: "string"
  },
  move: {},
  rm: {},
  delete: {},
  fix: { write: "boolean", base: "string" },
  help: {}
};

export class UsageError extends Error {}

export interface ParsedArgs {
  command?: string;
  positional: string[];
  options: Record<string, any> & { root: string[] };
}

export function parseArgs(argv: string[]): ParsedArgs {
  const result: ParsedArgs = { positional: [], options: { root: [] } };
  let flagsDone = false;

  for (let i = 0; i < argv.length; i++) {
    const token = argv[i];
    const match = flagsDone ? null : token.match(/^--([\w-]+)(?:=([\s\S]*))?$/);
    if (token === "--" && !flagsDone) {
      flagsDone = true;
    } else if (match || (token === "-h" && !flagsDone)) {
      const name = match ? match[1] : "help";
      let value = match ? match[2] : undefined;
      const kind =
        GLOBAL_OPTIONS[name] || (result.command ? COMMAND_OPTIONS[result.command]![name] : undefined);
      if (!kind) {
        throw new UsageError(
          `unknown option --${name}${result.command ? ` for \`${result.command}\`` : ""}`
        );
      }
      if (kind === "boolean") {
        if (value !== undefined) {
          throw new UsageError(`--${name} doesn't take a value`);
        }
        result.options[name] = true;
        continue;
      }
      if (value === undefined) {
        value = argv[++i];
        if (value === undefined) {
          throw new UsageError(`--${name} needs a value`);
        }
      }
      if (kind === "number") {
        if (!/^\d+$/.test(value)) {
          throw new UsageError(`--${name} needs a whole number`);
        }
        result.options[name] = Number(value);
      } else if (kind === "list") {
        result.options[name].push(value);
      } else {
        result.options[name] = value;
      }
    } else if (!result.command) {
      if (!COMMAND_OPTIONS[token]) {
        throw new UsageError(`unknown command ${JSON.stringify(token)}`);
      }
      result.command = token;
    } else {
      result.positional.push(token);
    }
  }

  return result;
}
