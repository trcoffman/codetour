// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

// The `codetour` command-line tool: create, edit, check and preview tours
// without an editor (e.g. from coding agents and CI).

import * as fs from "fs";
import * as path from "path";
import {
  anchorToLocation,
  createStep,
  insertStep,
  moveStep,
  parseLocation,
  plural,
  reanchorStep,
  removeSteps
} from "../core/edit";
import { evaluateWhen, formatTour } from "../core/tourFile";
import { CodeTour, CodeTourStep } from "../core/types";
import { Diagnostic, sourceLines, validateTour, validateWorkspace } from "../core/validate";
import { parseArgs, ParsedArgs, UsageError } from "./args";
import { applyFix, planFix } from "./fix";
import { formatPreview, previewTour } from "./show";
import { BrokenTour, isDirectory, LoadedTour, loadTourFile, readText, TOUR_CONTEXT, Workspace } from "./workspace";

export const USAGE = `Usage: codetour [--root DIR] [--json] <command> [arguments]

Create, edit, check and preview CodeTour tours (*.tour files).

Reading tours
  list                         List the workspace's tours
  show <tour> [--step N [--raw]] [--context N]
                               Show each step: where it points (with the code
                               around it), its description and its links
                               (--raw: only the step's description, as written)
  validate [<tour>...] [--strict]
                               Check tours for problems, including steps whose
                               code moved since the tour was last committed
                               (exit code 1 on errors, or also on warnings with
                               --strict)

Writing tours
  new <title> [--description TEXT] [--file PATH] [--ref REF] [--primary]
      [--next TITLE] [--when EXPR]
                               Create a tour (in .tours/ by default)
  add <tour> (--at LOCATION | --dir DIR | --content) [--title TEXT]
      [--description TEXT] [--after N | --before N] [--pattern] [--icon ICON]
                               Add a step (at the end by default)
  edit <tour> [<step>] [options of \`new\` or \`add\`] [--no-pattern]
                               Change a step, or the tour itself without <step>
                               (an empty value removes an optional property;
                               --at keeps a pattern step anchored by pattern
                               unless --no-pattern is given)
  move <tour> <step> <position>
                               Move a step
  rm <tour> <step>...          Delete steps
  delete <tour>                Delete a tour file
  fmt [<tour>...] [--check]    Rewrite tours in the canonical format
  fix [<tour>...] [--write] [--base REV]
                               Re-anchor steps after the code changed, using git
                               history: steps unchanged since the tour's last
                               commit follow their code (dry run unless --write;
                               exit code 1 if tours need changes)

<tour> is a title, a unique part of a title, a file name (e.g. "intro") or a
path to a .tour file. Steps are numbered from 1. TEXT can be "-" to read it
from stdin (useful for multi-line markdown).

LOCATION is FILE:LINE, FILE:/TEXT/ (the only line containing TEXT),
FILE:FIRST-LAST (a selection of whole lines) or FILE:/START/-/END/ (from the
only line containing START to the next line containing END that isn't
indented more, e.g. the \`}\` closing START's block). TEXT is plain text.
With --pattern, a single line is anchored by its content (TEXT, or the whole
line) instead of its number, so the step follows it when lines move.

Options
  --root DIR    Workspace folder (default: the current directory; repeatable)
  --json        Print machine-readable JSON
`;

export interface Io {
  cwd: string;
  readStdin: () => string;
}

export interface Result {
  code: number;
  stdout: string;
  stderr: string;
}

interface Output {
  data: unknown;
  lines: string[];
  code?: number;
}

/** A diagnostic located in a tour file. */
interface Problem extends Diagnostic {
  file: string;
}

class Cli {
  private stdinUsed = false;

  constructor(private io: Io, private workspace: Workspace, private args: ParsedArgs) {}

  private rel(file: string) {
    const relative = path.relative(this.io.cwd, file);
    return relative.startsWith("..") ? file : relative.split(path.sep).join("/");
  }

  private text(value: string) {
    if (value !== "-") {
      return value;
    }
    if (this.stdinUsed) {
      throw new UsageError("only one option can read from stdin");
    }
    this.stdinUsed = true;
    return this.io.readStdin().replace(/\n$/, "");
  }

  private allTours() {
    return this.workspace.load({ all: true }).tours;
  }

  private findTour(name: string | undefined): LoadedTour {
    if (!name) {
      throw new UsageError("missing <tour>");
    }
    const file = path.resolve(this.io.cwd, name);
    if (fs.existsSync(file) && !isDirectory(file)) {
      const loaded = loadTourFile(file);
      if ("error" in loaded) {
        throw new Error(`${name} isn't a valid tour: ${loaded.error}`);
      }
      return loaded;
    }

    const tours = this.allTours();
    const lower = name.toLowerCase();
    const fileName = name.endsWith(".tour") ? name : `${name}.tour`;
    const matchers: ((t: CodeTour) => boolean)[] = [
      t => t.title === name,
      t => t.title.toLowerCase() === lower,
      t => t.id === path.resolve(this.io.cwd, fileName) || t.id.endsWith(path.sep + fileName)
    ];
    for (const matches of matchers) {
      const found = tours.find(t => matches(t.tour));
      if (found) {
        return found;
      }
    }
    // A unique part of a title (e.g. "getting" for "🏃 Getting Started").
    const partial = tours.filter(t => t.tour.title.toLowerCase().includes(lower));
    if (partial.length === 1) {
      return partial[0];
    }
    throw new Error(
      partial.length > 1
        ? `${JSON.stringify(name)} matches ${partial.length} tours; be more specific`
        : `no tour matches ${JSON.stringify(name)} (see \`codetour list\`)`
    );
  }

  private stepNumber(tour: CodeTour, value: string | number | undefined, what = "<step>") {
    const number = Number(value);
    if (value === undefined || !Number.isInteger(number)) {
      throw new UsageError(`${what} must be a step number`);
    }
    if (!tour.steps[number - 1]) {
      throw new Error(
        `${JSON.stringify(tour.title)} doesn't have a step #${number} (it has ${plural(tour.steps.length, "step")})`
      );
    }
    return number;
  }

  private validate(loaded: LoadedTour, tours = this.allTours()): Problem[] {
    return validateTour(loaded.tour, this.workspace.host(loaded.tour), {
      tours: tours.map(t => t.tour),
      source: loaded.source
    }).map(d => ({ ...d, file: loaded.tour.id }));
  }

  /** Warnings for steps whose code moved or changed since the tour was committed. */
  private drift(loaded: LoadedTour): Problem[] {
    const plan = planFix(loaded.tour, this.workspace.rootOf(loaded.tour));
    const lines = sourceLines(loaded.source);
    return plan.steps.map(fix => ({
      severity: "warning",
      file: loaded.tour.id,
      line: lines.step(fix.step - 1),
      step: fix.step,
      message:
        fix.status === "moved"
          ? `step #${fix.step}: its code moved since ${plan.base!.slice(0, 12)} (${fix.changes.join(", ")}); run \`codetour fix --write\``
          : `step #${fix.step}: ${fix.message}`
    }));
  }

  private formatProblem(problem: Problem) {
    return `${this.rel(problem.file)}:${problem.line}: ${problem.severity}: ${problem.message}`;
  }

  private problemJson(problem: Problem) {
    return {
      severity: problem.severity,
      file: this.rel(problem.file),
      line: problem.line,
      step: problem.step,
      message: problem.message
    };
  }

  private save(tour: CodeTour) {
    fs.mkdirSync(path.dirname(tour.id), { recursive: true });
    fs.writeFileSync(tour.id, formatTour(tour));
  }

  /** Output of commands that change a tour: what changed, and its problems. */
  private changed(tour: CodeTour, summary: string, extra: object = {}): Output {
    const loaded = loadTourFile(tour.id);
    const problems = "error" in loaded ? [] : this.validate(loaded);

    // While a tour is being written, links to steps that don't exist yet are
    // expected: summarize them in one line per step.
    const missing = new Map<number, number[]>();
    const lines = [summary];
    for (const problem of problems) {
      const link = problem.message.match(/^step #(\d+) links to step #(\d+), but the tour has/);
      if (link) {
        const targets = missing.get(problem.step!) || [];
        missing.set(problem.step!, [...targets, Number(link[2])]);
      } else {
        lines.push(`  ${this.formatProblem(problem)}`);
      }
    }
    for (const [step, targets] of missing) {
      lines.push(`  note: step #${step} links to ${targets.map(t => `#${t}`).join(", ")}, which ${targets.length === 1 ? "doesn't" : "don't"} exist yet`);
    }
    return {
      data: { file: this.rel(tour.id), steps: tour.steps.length, ...extra, problems: problems.map(p => this.problemJson(p)) },
      lines
    };
  }

  private describeStep(step: CodeTourStep) {
    if (step.file) {
      const where = step.line
        ? `:${step.line}`
        : step.selection
        ? `:${step.selection.start.line}-${step.selection.end.line}`
        : step.pattern
        ? ` /${step.pattern}/`
        : "";
      return `${step.file}${where}`;
    }
    return step.directory ? `directory ${step.directory}` : "content step";
  }

  /**
   * Reads --at / --dir / --content into step fields. `keepPattern` anchors by
   * pattern without --pattern (when re-anchoring a pattern step).
   */
  private anchorFields(root: string, required: boolean, keepPattern = false): Partial<CodeTourStep> | undefined {
    const { at, dir, content } = this.args.options;
    const pattern = this.args.options.pattern || (keepPattern && !this.args.options["no-pattern"]);
    if (this.args.options.pattern && this.args.options["no-pattern"]) {
      throw new UsageError("use only one of --pattern and --no-pattern");
    }
    const count = [at, dir, content].filter(v => v !== undefined).length;
    if (count > 1) {
      throw new UsageError("use only one of --at, --dir and --content");
    }
    if ((this.args.options.pattern || this.args.options["no-pattern"]) && at === undefined) {
      throw new UsageError("--pattern and --no-pattern need --at");
    }
    if (count === 0) {
      if (required) {
        throw new UsageError("add needs --at LOCATION, --dir DIR or --content");
      }
      return;
    }
    if (at !== undefined) {
      const location = parseLocation(at);
      if (keepPattern && !this.args.options.pattern && !this.args.options["no-pattern"] && location.lastLine !== undefined) {
        throw new UsageError("this step is anchored by a pattern; pass --no-pattern to replace it with a selection");
      }
      const file = path.resolve(root, location.file);
      const contents = isDirectory(file) ? undefined : readText(file);
      if (contents === undefined) {
        throw new Error(`file not found: ${location.file}`);
      }
      const relative = path.relative(root, file).split(path.sep).join("/");
      try {
        return { file: relative, ...anchorToLocation({ ...location, file: relative }, contents, { pattern }) };
      } catch (e) {
        const message = (e as Error).message;
        throw new Error(keepPattern && !this.args.options.pattern ? `${message} (this step is anchored by a pattern; pass --no-pattern to anchor it by line number)` : message);
      }
    }
    if (dir !== undefined) {
      const directory = path.resolve(root, dir);
      if (!isDirectory(directory)) {
        throw new Error(`directory not found: ${dir}`);
      }
      return { directory: path.relative(root, directory).split(path.sep).join("/") };
    }
    return {};
  }

  // Commands --------------------------------------------------------------

  list(): Output {
    const tours = this.allTours();
    const data = tours.map(({ tour }) => ({
      title: tour.title,
      file: this.rel(tour.id),
      steps: tour.steps.length,
      description: tour.description,
      primary: tour.isPrimary === true,
      when: tour.when,
      hidden: !evaluateWhen(tour, TOUR_CONTEXT).visible
    }));
    const lines = data.map(
      t =>
        `${t.title}  (${plural(t.steps, "step")})  ${t.file}${t.primary ? "  [primary]" : ""}${
          t.hidden ? `  [hidden: when ${t.when}]` : ""
        }`
    );
    return { data, lines: lines.length ? lines : ["No tours found"] };
  }

  show(): Output {
    const { tour } = this.findTour(this.args.positional[0]);
    const { step, context, raw } = this.args.options;
    if (step !== undefined) {
      this.stepNumber(tour, step, "--step");
    }
    if (raw) {
      if (step === undefined) {
        throw new UsageError("--raw needs --step");
      }
      const description = tour.steps[step - 1].description || "";
      return { data: { description }, lines: [description] };
    }
    const steps = previewTour(tour, this.workspace.host(tour), { step, context });
    const header = [`${tour.title}  (${this.rel(tour.id)}, ${plural(tour.steps.length, "step")})`];
    for (const [label, value] of [
      ["description", tour.description],
      ["ref", tour.ref],
      ["next tour", tour.nextTour]
    ]) {
      if (value) {
        header.push(`  ${label}: ${value}`);
      }
    }
    if (tour.isPrimary) {
      header.push("  primary tour");
    }
    return {
      data: {
        title: tour.title,
        file: this.rel(tour.id),
        description: tour.description,
        ref: tour.ref,
        primary: tour.isPrimary === true,
        nextTour: tour.nextTour,
        steps
      },
      lines: [...header, ...formatPreview(steps)]
    };
  }

  validateCommand(): Output {
    const all = this.workspace.load({ all: true });
    let loaded: LoadedTour[];
    let broken: BrokenTour[];
    if (this.args.positional.length > 0) {
      loaded = [];
      broken = [];
      for (const name of this.args.positional) {
        const file = path.resolve(this.io.cwd, name);
        if (fs.existsSync(file) && !isDirectory(file)) {
          const result = loadTourFile(file);
          "error" in result ? broken.push(result) : loaded.push(result);
        } else {
          loaded.push(this.findTour(name));
        }
      }
    } else {
      ({ tours: loaded, broken } = all);
    }

    const problems: Problem[] = broken.map(b => ({
      severity: "error",
      file: path.resolve(b.path),
      line: Number((b.error.match(/line (\d+)/) || [])[1]) || 1,
      message: `not a valid tour: ${b.error}`
    }));
    for (const tour of loaded) {
      problems.push(...this.validate(tour, all.tours));
      problems.push(...this.drift(tour));
    }
    if (this.args.positional.length === 0) {
      for (const { tour, diagnostic } of validateWorkspace(loaded.map(t => t.tour))) {
        problems.push({ ...diagnostic, file: tour.id, message: diagnostic.message.replace(tour.id, this.rel(tour.id)) });
      }
    }
    problems.sort((a, b) => (a.file === b.file ? a.line - b.line : a.file < b.file ? -1 : 1));

    const errors = problems.filter(p => p.severity === "error").length;
    const warnings = problems.length - errors;
    const count = loaded.length + broken.length;
    return {
      data: { errors, warnings, tours: count, problems: problems.map(p => this.problemJson(p)) },
      lines: [
        ...problems.map(p => this.formatProblem(p)),
        `${plural(errors, "error")}, ${plural(warnings, "warning")} in ${plural(count, "tour")}`
      ],
      code: errors > 0 || (this.args.options.strict && warnings > 0) ? 1 : 0
    };
  }

  fmt(): Output {
    const tours =
      this.args.positional.length > 0
        ? this.args.positional.map(name => this.findTour(name))
        : this.workspace.load({ all: true }).tours;
    const files: string[] = [];
    const lines: string[] = [];
    for (const { tour, source } of tours) {
      const formatted = formatTour(tour);
      if (formatted !== source) {
        files.push(this.rel(tour.id));
        if (this.args.options.check) {
          lines.push(`would reformat ${this.rel(tour.id)}`);
        } else {
          this.save(tour);
          lines.push(`reformatted ${this.rel(tour.id)}`);
        }
      }
    }
    if (lines.length === 0) {
      lines.push(`${plural(tours.length, "tour")} already formatted`);
    }
    return { data: { files }, lines, code: this.args.options.check && files.length > 0 ? 1 : 0 };
  }

  newCommand(): Output {
    const title = this.args.positional[0];
    if (!title) {
      throw new UsageError("missing <title>");
    }
    const { description, file, ref, primary, next, when } = this.args.options;
    const target = file ? path.resolve(this.io.cwd, file) : this.workspace.newTourPath(title);
    if (fs.existsSync(target)) {
      throw new Error(`${this.rel(target)} already exists`);
    }

    // The properties read best before the steps.
    const tour: any = { title };
    if (description) {
      tour.description = this.text(description);
    }
    if (primary) {
      tour.isPrimary = true;
    }
    if (next) {
      tour.nextTour = next;
    }
    if (when) {
      tour.when = when;
    }
    tour.steps = [];
    if (ref && ref !== "HEAD") {
      tour.ref = ref;
    }
    tour.id = target;

    const others: string[] = [];
    if (primary) {
      for (const other of this.allTours()) {
        if (other.tour.isPrimary) {
          delete other.tour.isPrimary;
          this.save(other.tour);
          others.push(this.rel(other.tour.id));
        }
      }
    }
    this.save(tour);
    return this.changed(tour, `created ${this.rel(target)} (${JSON.stringify(title)})`, { updated: others });
  }

  add(): Output {
    const { tour } = this.findTour(this.args.positional[0]);
    const { title, icon, description, after, before } = this.args.options;
    if (after !== undefined && before !== undefined) {
      throw new UsageError("use only one of --after and --before");
    }
    const fields = this.anchorFields(this.workspace.rootOf(tour), true)!;
    if (title) {
      fields.title = title;
    }
    if (icon) {
      fields.icon = icon;
    }
    fields.description = description !== undefined ? this.text(description) : "";
    if (!fields.title && !fields.file && !fields.directory && !/^\s*#+\s*\S/.test(fields.description)) {
      throw new UsageError("content steps need a --title, or a description that starts with a markdown heading");
    }

    let position = tour.steps.length + 1;
    if (after !== undefined) {
      position = this.stepNumber(tour, after, "--after") + 1;
    } else if (before !== undefined) {
      position = this.stepNumber(tour, before, "--before");
    }
    const step = createStep(fields);
    insertStep(tour, step, position);
    this.save(tour);
    return this.changed(tour, `added step #${position} to ${this.rel(tour.id)}: ${this.describeStep(step)}`, {
      step: position
    });
  }

  edit(): Output {
    const { tour } = this.findTour(this.args.positional[0]);
    const options = this.args.options;
    const changes: string[] = [];
    const setOptional = (target: any, key: string, value: string | undefined, label = key) => {
      if (value === undefined) {
        return;
      }
      if (value === "") {
        delete target[key];
      } else {
        target[key] = value;
      }
      changes.push(label);
    };

    if (this.args.positional[1] !== undefined) {
      const number = this.stepNumber(tour, this.args.positional[1]);
      const step = tour.steps[number - 1];
      for (const key of ["ref", "primary", "no-primary", "next", "when"]) {
        if (options[key] !== undefined) {
          throw new UsageError(`--${key} changes the tour; leave out <step>`);
        }
      }
      const fields = this.anchorFields(this.workspace.rootOf(tour), false, step.pattern !== undefined && !step.line);
      if (fields) {
        reanchorStep(step, fields);
        changes.push(this.describeStep(step));
      }
      setOptional(step, "title", options.title);
      setOptional(step, "icon", options.icon);
      if (options.description !== undefined) {
        step.description = this.text(options.description);
        changes.push("description");
      }
      if (changes.length === 0) {
        throw new UsageError("nothing to change (see `codetour help`)");
      }
      this.save(tour);
      return this.changed(tour, `updated step #${number} of ${this.rel(tour.id)}: ${changes.join(", ")}`, {
        step: number
      });
    }

    for (const key of ["at", "dir", "pattern", "no-pattern", "icon"]) {
      if (options[key] !== undefined) {
        throw new UsageError(`--${key} changes a step; pass <step>`);
      }
    }
    const oldTitle = tour.title;
    if (options.title !== undefined) {
      if (!options.title) {
        throw new UsageError("a tour needs a title");
      }
      tour.title = options.title;
      changes.push("title");
    }
    if (options.description !== undefined) {
      setOptional(tour, "description", this.text(options.description));
    }
    setOptional(tour, "ref", options.ref === "HEAD" ? "" : options.ref);
    setOptional(tour, "nextTour", options.next, "next tour");
    setOptional(tour, "when", options.when);
    if (options.primary && options["no-primary"]) {
      throw new UsageError("use only one of --primary and --no-primary");
    }

    const others: CodeTour[] = [];
    if (options.primary) {
      tour.isPrimary = true;
      changes.push("primary");
      for (const { tour: other } of this.allTours()) {
        if (other.id !== tour.id && other.isPrimary) {
          delete other.isPrimary;
          others.push(other);
        }
      }
    } else if (options["no-primary"]) {
      delete tour.isPrimary;
      changes.push("not primary");
    }
    if (changes.length === 0) {
      throw new UsageError("nothing to change (see `codetour help`)");
    }

    // Keep other tours' `nextTour` links working after a rename.
    if (tour.title !== oldTitle) {
      for (const { tour: other } of this.allTours()) {
        if (other.id !== tour.id && other.nextTour === oldTitle) {
          other.nextTour = tour.title;
          others.push(other);
        }
      }
    }
    this.save(tour);
    others.forEach(other => this.save(other));
    return this.changed(tour, `updated ${this.rel(tour.id)}: ${changes.join(", ")}`, {
      updated: others.map(other => this.rel(other.id))
    });
  }

  move(): Output {
    const { tour } = this.findTour(this.args.positional[0]);
    const from = this.stepNumber(tour, this.args.positional[1]);
    const to = Number(this.args.positional[2]);
    if (this.args.positional[2] === undefined || !Number.isInteger(to)) {
      throw new UsageError("missing <position>");
    }
    moveStep(tour, from, to);
    this.save(tour);
    return this.changed(tour, `moved step #${from} of ${this.rel(tour.id)} to #${to}`, { step: to });
  }

  rm(): Output {
    const { tour } = this.findTour(this.args.positional[0]);
    const numbers = this.args.positional.slice(1).map(value => this.stepNumber(tour, value));
    if (numbers.length === 0) {
      throw new UsageError("missing <step>");
    }
    removeSteps(tour, numbers);
    this.save(tour);
    const list = [...new Set(numbers)].sort((a, b) => a - b).join(", #");
    return this.changed(tour, `removed ${numbers.length === 1 ? "step" : "steps"} #${list} from ${this.rel(tour.id)}`);
  }

  deleteCommand(): Output {
    const { tour } = this.findTour(this.args.positional[0]);
    if (this.args.positional.length > 1) {
      throw new UsageError("delete takes one <tour>; to delete steps, use `codetour rm <tour> <step>...`");
    }
    fs.unlinkSync(tour.id);
    const linking = this.allTours()
      .filter(({ tour: other }) => other.nextTour === tour.title)
      .map(({ tour: other }) => this.rel(other.id));
    return {
      data: { file: this.rel(tour.id), linking },
      lines: [
        `deleted ${this.rel(tour.id)} (${JSON.stringify(tour.title)})`,
        ...linking.map(file => `  warning: ${file} still has \`nextTour\` set to ${JSON.stringify(tour.title)}`)
      ]
    };
  }

  fix(): Output {
    const tours =
      this.args.positional.length > 0
        ? this.args.positional.map(name => this.findTour(name))
        : this.workspace.load({ all: true }).tours;
    const data: unknown[] = [];
    const lines: string[] = [];
    let moved = 0;
    let unresolved = 0;

    for (const { tour } of tours) {
      const file = this.rel(tour.id);
      const plan = planFix(tour, this.workspace.rootOf(tour), { base: this.args.options.base });
      data.push({ file, ...plan });
      if (plan.skipped) {
        lines.push(`${file}: skipped: ${plan.skipped}`);
        continue;
      }
      for (const step of plan.steps) {
        if (step.status === "moved") {
          moved++;
          lines.push(`${file}: step #${step.step}: ${step.changes.join(", ")}`);
        } else {
          unresolved++;
          lines.push(`${file}: step #${step.step}: ${step.message}`);
        }
      }
      if (plan.steps.length === 0) {
        lines.push(`${file}: up to date (compared with ${plan.base!.slice(0, 12)})`);
      } else if (this.args.options.write && applyFix(tour, plan) > 0) {
        this.save(tour);
        const count = plan.steps.filter(step => step.status === "moved").length;
        lines.push(`${file}: re-anchored ${plural(count, "step")}`);
      }
    }
    if (!this.args.options.write && moved > 0) {
      lines.push("(dry run: pass --write to apply)");
    }
    return { data, lines, code: unresolved > 0 || (!this.args.options.write && moved > 0) ? 1 : 0 };
  }

  run(): Output {
    switch (this.args.command) {
      case "list":
        return this.list();
      case "show":
        return this.show();
      case "validate":
        return this.validateCommand();
      case "fmt":
        return this.fmt();
      case "new":
        return this.newCommand();
      case "add":
        return this.add();
      case "edit":
        return this.edit();
      case "move":
        return this.move();
      case "rm":
        return this.rm();
      case "delete":
        return this.deleteCommand();
      case "fix":
        return this.fix();
    }
    throw new UsageError(`unknown command ${JSON.stringify(this.args.command)}`);
  }
}

/** Runs the CLI (without touching the process, for tests). */
export function run(argv: string[], io: Io): Result {
  let args: ParsedArgs;
  try {
    args = parseArgs(argv);
  } catch (e) {
    return { code: 2, stdout: "", stderr: `codetour: ${(e as Error).message}\n\n${USAGE}` };
  }
  if (!args.command || args.command === "help" || args.options.help) {
    return { code: 0, stdout: USAGE, stderr: "" };
  }

  const roots = args.options.root.length > 0 ? args.options.root.map(root => path.resolve(io.cwd, root)) : [io.cwd];
  const cli = new Cli(io, new Workspace(roots), args);
  try {
    const output = cli.run();
    const stdout = args.options.json ? JSON.stringify(output.data, null, 2) : output.lines.join("\n");
    return { code: output.code || 0, stdout: stdout + "\n", stderr: "" };
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    if (e instanceof UsageError) {
      return { code: 2, stdout: "", stderr: `codetour: ${message}\n` };
    }
    return {
      code: 1,
      stdout: args.options.json ? JSON.stringify({ error: message }) + "\n" : "",
      stderr: `codetour: ${message}\n`
    };
  }
}
