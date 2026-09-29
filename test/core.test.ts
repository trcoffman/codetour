import * as assert from "assert";
import { describe, it } from "node:test";
import { resolveStepLine, splitLines } from "../src/core/anchor";
import { findLine, mapLine, parseHunks } from "../src/core/drift";
import {
  anchorToLocation,
  createStep,
  getLinePattern,
  insertStep,
  moveStep,
  parseLocation,
  removeSteps
} from "../src/core/edit";
import { findMarkerTitle, getStepLabel, getStepMarker, getTourTitle } from "../src/core/labels";
import { findReferences, parseCommand } from "../src/core/markdown";
import { compareTours, evaluateWhen, formatTour, getTourFileName, parseTour } from "../src/core/tourFile";
import { CodeTour } from "../src/core/types";
import { validateTour, validateWorkspace, ValidationHost } from "../src/core/validate";

const tour = (fields: Partial<CodeTour>): CodeTour => ({ id: "/ws/.tours/t.tour", title: "T", steps: [], ...fields });
const context = { isLinux: true, isMac: false, isWindows: false, isWeb: false };

describe("tour files", () => {
  it("formats tours like the extension saves them", () => {
    const parsed = parseTour('{"title":"T","steps":[{"file":"a.js","description":"d","line":2}],"description":"x"}', "/t.tour");
    parsed.steps[0].markerTitle = "runtime only";
    assert.strictEqual(
      formatTour(parsed),
      [
        "{",
        '  "$schema": "https://aka.ms/codetour-schema",',
        '  "title": "T",',
        '  "steps": [',
        "    {",
        '      "file": "a.js",',
        '      "description": "d",',
        '      "line": 2',
        "    }",
        "  ],",
        '  "description": "x"',
        "}"
      ].join("\n")
    );
    // The schema keeps its position if the file already has one.
    assert.match(formatTour(parseTour('{"title":"T","$schema":"s","steps":[]}', "x")), /^{\n  "\$schema": "s",\n  "title"/);
  });

  it("rejects files that aren't tours", () => {
    assert.throws(() => parseTour("[]", "x"), /JSON object/);
    assert.throws(() => parseTour('{"steps": []}', "x"), /"title"/);
    assert.throws(() => parseTour('{"title": "T"}', "x"), /"steps"/);
    assert.throws(() => parseTour("{", "x"), SyntaxError);
  });

  it("names new tour files like the recorder", () => {
    assert.strictEqual(getTourFileName("My First Tour!"), "my-first-tour.tour");
    assert.strictEqual(getTourFileName("🏃 Getting Started"), "-getting-started.tour");
  });

  it("evaluates `when` clauses, hiding tours whose clause fails", () => {
    assert.deepStrictEqual(evaluateWhen(tour({ when: "isLinux && !isWeb" }), context), { visible: true });
    assert.deepStrictEqual(evaluateWhen(tour({ when: "isMac" }), context), { visible: false });
    const broken = evaluateWhen(tour({ when: "isLinux &&" }), context);
    assert.strictEqual(broken.visible, false);
    assert.ok(broken.error);
  });

  it("sorts tours by title", () => {
    const titles = ["beta", "Alpha", "🏃 Start"].map(title => tour({ title })).sort(compareTours).map(t => t.title);
    assert.deepStrictEqual(titles, ["🏃 Start", "Alpha", "beta"]);
  });
});

describe("labels", () => {
  it("labels steps and tours", () => {
    const t = tour({
      title: "1 - Intro",
      steps: [{ title: "Explicit", description: "" }, { description: "## Heading\nbody" }, { file: "a.js", description: "" }]
    });
    assert.strictEqual(getStepLabel(t, 0), "#1 - Explicit");
    assert.strictEqual(getStepLabel(t, 1, false), "Heading");
    assert.strictEqual(getStepLabel(t, 2), "#3 - a.js");
    assert.strictEqual(getTourTitle(t), "Intro");
  });

  it("finds step markers", () => {
    const t = tour({ title: "2 - Two", steps: [{ file: "a.js", description: "" }] });
    assert.strictEqual(getStepMarker(t, 0), "CT2.1");
    assert.strictEqual(findMarkerTitle(t, 0, "// CT2.1 - Setup\n"), "Setup");
  });
});

describe("markdown", () => {
  it("finds links to steps, tours, commands and files outside of code", () => {
    const references = findReferences(
      [
        "See [#2], [Intro#3] and [text][Tree View].",
        "[Run](command:codetour.navigateToStep?4) [Go](command:codetour.startTourByTitle?%5B%22A%22%5D)",
        "![img](./a.png) [file](./src/a.js)",
        "`[#9]` and",
        "```js",
        "[#8]",
        "```"
      ].join("\n")
    );
    assert.deepStrictEqual(references, [
      { kind: "command", name: "codetour.navigateToStep", args: [4] },
      { kind: "command", name: "codetour.startTourByTitle", args: ["A"] },
      { kind: "file", path: "./a.png", image: true },
      { kind: "file", path: "./src/a.js", image: false },
      { kind: "step", step: 2 },
      { kind: "tour", title: "Intro", step: 3 },
      { kind: "tour", title: "Tree View", step: undefined }
    ]);
  });

  it("parses step commands", () => {
    assert.deepStrictEqual(parseCommand("a.b"), { name: "a.b", args: [] });
    assert.deepStrictEqual(parseCommand('a.b?["x", 1]'), { name: "a.b", args: ["x", 1] });
    assert.deepStrictEqual(parseCommand("a.b?2"), { name: "a.b", args: [2] });
  });
});

describe("anchors", () => {
  const contents = "one\n// CT1.2 - Two\nfunction run() {\n  return 1;\n}\n";

  it("locates steps like the player", () => {
    const t = tour({
      title: "1 - T",
      steps: [
        { file: "a.js", line: 3, description: "" },
        { file: "a.js", description: "" },
        { file: "a.js", pattern: "^\\s*return", description: "" },
        { file: "a.js", selection: { start: { line: 3, character: 1 }, end: { line: 5, character: 2 } }, description: "" },
        { file: "a.js", pattern: "nope", description: "" },
        { description: "" }
      ]
    });
    assert.deepStrictEqual(resolveStepLine(t, 0, contents), { line: 2, kind: "line" });
    assert.deepStrictEqual(resolveStepLine(t, 1, contents), { line: 1, kind: "marker" });
    assert.deepStrictEqual(resolveStepLine(t, 2, contents), { line: 3, kind: "pattern" });
    assert.deepStrictEqual(resolveStepLine(t, 3, contents), { line: 4, kind: "selection" });
    assert.match(resolveStepLine(t, 4, contents).problem!, /doesn't match any line/);
    assert.deepStrictEqual(resolveStepLine(t, 5, contents), { kind: "none" });
    assert.deepStrictEqual(splitLines("a\r\nb\n"), ["a", "b"]);
  });
});

describe("editing", () => {
  const contents = "const a = 1;\nfunction run() {\n  return a;\n}\nconst a = 1;\nlet s = '😀';\n";

  it("parses locations", () => {
    assert.deepStrictEqual(parseLocation("a.js:3"), { file: "a.js", line: 3 });
    assert.deepStrictEqual(parseLocation("a.js:2-4"), { file: "a.js", line: 2, lastLine: 4 });
    assert.deepStrictEqual(parseLocation("a.js:/run()/"), { file: "a.js", text: "run()" });
    assert.deepStrictEqual(parseLocation("a.js:/run()/-/}/"), { file: "a.js", text: "run()", endText: "}" });
    assert.deepStrictEqual(parseLocation("a.js"), { file: "a.js" });
    assert.throws(() => parseLocation("a.js:x"), /invalid location/);
  });

  it("anchors steps to lines, text and selections", () => {
    assert.deepStrictEqual(anchorToLocation({ file: "a.js", line: 2 }, contents), { line: 2 });
    assert.deepStrictEqual(anchorToLocation({ file: "a.js", text: "function" }, contents), { line: 2 });
    assert.deepStrictEqual(anchorToLocation({ file: "a.js", line: 2, lastLine: 6 }, contents), {
      // UTF-16 columns: "let s = '😀';" is 13 code units long.
      selection: { start: { line: 2, character: 1 }, end: { line: 6, character: 14 } }
    });
    assert.deepStrictEqual(anchorToLocation({ file: "a.js", line: 2 }, contents, { pattern: true }), {
      pattern: "^[^\\S\\n]*function run\\(\\) \\{"
    });
    assert.deepStrictEqual(anchorToLocation({ file: "a.js", text: "run()" }, contents, { pattern: true }), {
      pattern: "run\\(\\)"
    });
    // The selection ends at the `}` closing the block, not at inner ones.
    assert.deepStrictEqual(
      anchorToLocation({ file: "b.js", text: "function f", endText: "}" }, "function f() {\n  if (x) {\n  }\n}\n"),
      { selection: { start: { line: 1, character: 1 }, end: { line: 4, character: 2 } } }
    );
  });

  it("explains locations it can't use", () => {
    assert.throws(() => anchorToLocation({ file: "a.js", line: 9 }, contents), /line 9 is outside of a.js \(6 lines\)/);
    assert.throws(() => anchorToLocation({ file: "a.js", text: "const" }, contents), /appears on 2 lines of a.js \(1, 5\)/);
    assert.throws(() => anchorToLocation({ file: "a.js", text: "nope" }, contents), /doesn't appear/);
    assert.throws(() => anchorToLocation({ file: "a.js", line: 1 }, contents, { pattern: true }), /not unique/);
    assert.throws(() => anchorToLocation({ file: "a.js", line: 1, lastLine: 2 }, contents, { pattern: true }), /single line/);
  });

  it("creates line patterns like the recorder", () => {
    assert.strictEqual(getLinePattern(contents, 1), "^[^\\S\\n]*function run\\(\\) \\{");
    assert.strictEqual(getLinePattern(contents, 0), undefined);
  });

  it("creates steps with keys in the recorder's order", () => {
    assert.deepStrictEqual(Object.keys(createStep({ line: 1, file: "a", description: "d" })), ["file", "description", "line"]);
    assert.deepStrictEqual(Object.keys(createStep({ selection: {} as any, file: "a" })), ["file", "selection", "description"]);
    assert.deepStrictEqual(Object.keys(createStep({ directory: "src" })), ["directory", "description"]);
    assert.deepStrictEqual(Object.keys(createStep({ description: "x", title: "T" })), ["title", "description"]);
  });

  it("inserts, moves and removes steps", () => {
    const t = tour({ steps: ["1", "2", "3"].map(description => ({ description })) });
    const order = () => t.steps.map(s => s.description).join("");
    insertStep(t, { description: "4" });
    insertStep(t, { description: "0" }, 1);
    assert.strictEqual(order(), "01234");
    moveStep(t, 1, 5);
    assert.strictEqual(order(), "12340");
    removeSteps(t, [5, 1, 1]);
    assert.strictEqual(order(), "234");
    assert.throws(() => moveStep(t, 9, 1), /doesn't have a step #9 \(it has 3 steps\)/);
    assert.throws(() => insertStep(t, { description: "" }, 9), /invalid position/);
  });
});

describe("drift", () => {
  it("maps lines through diff hunks", () => {
    const hunks = parseHunks("@@ -0,0 +1,2 @@\n+a\n+b\n@@ -3 +5 @@\n-x\n+y\n@@ -8,2 +10,0 @@\n-p\n-q\n");
    assert.deepStrictEqual(hunks[1], { oldStart: 3, oldCount: 1, newStart: 5, newCount: 1 });
    assert.deepStrictEqual(mapLine(hunks, 1), { line: 3, shift: 2 });
    assert.deepStrictEqual(mapLine(hunks, 3), { shift: 2 });
    assert.deepStrictEqual(mapLine(hunks, 12), { line: 12, shift: 0 });
    assert.strictEqual(findLine(["a", "  x", "x", "b"], "x", 1), 3);
    assert.strictEqual(findLine(["a", "  y  "], "y", 1), 2);
    assert.strictEqual(findLine(["a"], "", 1), undefined);
  });
});

describe("validation", () => {
  const files: Record<string, string> = {
    "src/a.js": "one\n\nfunction run() {\n  return 1;\n}\ndup\ndup\n",
    "src/b.js": "// CT1.1 - First\n"
  };
  const host: ValidationHost = {
    context,
    readFile: file => files[file],
    isDirectory: file => file === "src",
    exists: () => false,
    refExists: ref => ref === "v1"
  };
  const other = tour({ id: "/o.tour", title: "Other", steps: [{ description: "o" }] });
  const messages = (t: CodeTour, source?: string) =>
    validateTour(t, host, { tours: [other], source }).map(d => `${d.severity}: ${d.message}`);

  it("accepts a valid tour", () => {
    assert.deepStrictEqual(
      messages(
        tour({
          steps: [
            { title: "Intro", description: "Start at [#2], then [Other] or [the code](./src/a.js)." },
            { file: "src/a.js", line: 3, description: "run" },
            { file: "src/a.js", selection: { start: { line: 3, character: 1 }, end: { line: 5, character: 2 } }, description: "x" },
            { file: "src/a.js", pattern: "^\\s*return 1;", description: "returns" },
            { directory: "src", description: "sources" }
          ]
        })
      ),
      []
    );
  });

  it("reports steps pointing at missing files, lines and patterns", () => {
    assert.deepStrictEqual(
      messages(
        tour({
          title: "1 - Numbered",
          steps: [
            { file: "src/missing.js", line: 1, description: "x" },
            { file: "src/a.js", line: 99, description: "x" },
            { file: "src/a.js", line: 2, description: "x" },
            { file: "src/a.js", pattern: "^nothing$", description: "x" },
            { file: "src/a.js", pattern: "(", description: "x" },
            { file: "src/a.js", pattern: "^dup$", description: "x" },
            { file: "src/b.js", description: "x" },
            { directory: "nope", description: "x" },
            { file: "src/a.js", selection: { start: { line: 3, character: 1 }, end: { line: 1, character: 1 } }, description: "x" },
            { file: "src/a.js", selection: { start: { line: 1, character: 1 }, end: { line: 1, character: 9 } }, description: "x" }
          ]
        })
      ),
      [
        "error: step #1: file not found: src/missing.js",
        "error: step #2: line 99 is past the end of src/a.js (7 lines)",
        "warning: step #3: line 2 of src/a.js is blank",
        'error: step #4: the pattern "^nothing$" doesn\'t match any line in src/a.js',
        'error: step #5: the pattern "(" isn\'t a valid regular expression: Invalid regular expression: /(/m: Unterminated group in src/a.js',
        "warning: step #6: the pattern matches 2 lines of src/a.js; the first one (line 6) is used",
        'error: step #7: the step marker "CT1.7" doesn\'t match any line in src/b.js',
        "error: step #8: directory not found: nope",
        "error: step #9: the selection ends before it starts",
        "error: step #10: the selection goes past the end of line 1 of src/a.js"
      ]
    );
  });

  it("reports broken links, properties and steps sharing a line", () => {
    assert.deepStrictEqual(
      messages(
        tour({
          nextTour: "Missing",
          ref: "v2",
          when: "isLinux &&",
          steps: [
            { description: "See [#9], [Other#5], [x](command:codetour.startTourByTitle?[\"Nope\"]) and [y](./gone.js)" },
            { file: "src/a.js", line: 3, description: "" },
            { file: "src/a.js", line: 3, description: "again", commands: ["codetour.navigateToStep?7"] }
          ]
        })
      ),
      [
        'error: the `when` clause "isLinux &&" can\'t be evaluated: Unexpected end of expression: isLinux &&',
        'error: `nextTour` refers to a tour that doesn\'t exist: "Missing"',
        'error: the git ref "v2" doesn\'t exist',
        'error: step #1 links to a tour that doesn\'t exist: "Nope"',
        "warning: step #1 links to a file that doesn't exist: ./gone.js",
        "error: step #1 links to step #9, but the tour has 3 steps",
        'error: step #1 links to step #5 of "Other", which has 1 step',
        "warning: step #2 doesn't have a description",
        "warning: step #3 is on the same line as step #2 (line 3 of src/a.js)",
        "error: step #3 links to step #7, but the tour has 3 steps"
      ]
    );
  });

  it("reports the line of each problem in the tour file", () => {
    const source = '{\n  "title": "T",\n  "nextTour": "Missing",\n  "steps": [\n    {"description": "ok"},\n    {"file": "nope.js", "line": 1, "description": "x"}\n  ]\n}';
    const diagnostics = validateTour(parseTour(source, "x"), host, { source });
    assert.deepStrictEqual(
      diagnostics.map(d => [d.line, d.step]),
      [
        [3, undefined],
        [6, 2]
      ]
    );
  });

  it("reports duplicate titles and several primary tours", () => {
    const problems = validateWorkspace([
      tour({ id: "/a", title: "A", isPrimary: true }),
      tour({ id: "/b", title: "A", isPrimary: true })
    ]).map(p => p.diagnostic.message);
    assert.deepStrictEqual(problems, ["another tour (/a) has the same title", "2 tours are marked as primary", "2 tours are marked as primary"]);
  });
});
