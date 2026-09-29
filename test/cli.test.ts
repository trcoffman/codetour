import * as assert from "assert";
import { spawnSync } from "child_process";
import * as fs from "fs";
import { beforeEach, describe, it } from "node:test";
import * as os from "os";
import * as path from "path";
import { run } from "../src/cli/main";

const SERVER = [
  'const http = require("http");',
  "",
  "function handle(req, res) {",
  '  res.end("hello");',
  "}",
  "",
  "function start(port) {",
  "  const server = http.createServer(handle);",
  "  server.listen(port);",
  "  return server;",
  "}",
  "",
  "module.exports = { start };",
  ""
].join("\n");

let root: string;

function write(file: string, contents: string) {
  fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
  fs.writeFileSync(path.join(root, file), contents);
}

function read(file: string) {
  return fs.readFileSync(path.join(root, file), "utf8");
}

function tour(name = "server") {
  return JSON.parse(read(`.tours/${name}.tour`));
}

function codetour(args: string[], stdin = "") {
  return run(args, { cwd: root, readStdin: () => stdin });
}

function json(args: string[], stdin?: string) {
  const result = codetour(["--json", ...args], stdin);
  return { code: result.code, data: JSON.parse(result.stdout) };
}

function git(...args: string[]) {
  const result = spawnSync(
    "git",
    ["-C", root, "-c", "user.name=Tests", "-c", "user.email=tests@example.com", "-c", "commit.gpgsign=false", ...args],
    { encoding: "utf8" }
  );
  assert.strictEqual(result.status, 0, result.stderr);
  return result.stdout.trim();
}

beforeEach(() => {
  root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "codetour-")));
  write("src/server.js", SERVER);
});

describe("codetour", () => {
  it("prints usage and rejects unknown commands and options", () => {
    assert.match(codetour(["help"]).stdout, /Usage: codetour/);
    let result = codetour(["frobnicate"]);
    assert.strictEqual(result.code, 2);
    assert.match(result.stderr, /unknown command "frobnicate"/);
    result = codetour(["add", "x", "--nope"]);
    assert.strictEqual(result.code, 2);
    assert.match(result.stderr, /unknown option --nope for `add`/);
  });

  it("authors a tour step by step, reporting problems as it goes", () => {
    let result = codetour(["new", "Server", "--description", "How the server starts"]);
    assert.strictEqual(result.code, 0);
    assert.match(result.stdout, /created .tours\/server.tour/);

    result = codetour(["add", "server", "--content", "--title", "Overview", "--description", "-"], "### Overview\n\nStart at [#2].\n");
    assert.match(result.stdout, /note: step #1 links to #2, which doesn't exist yet/);

    result = codetour(["add", "server", "--at", "src/server.js:/function handle/", "--description", "Requests end up here."]);
    assert.match(result.stdout, /added step #2 to .tours\/server.tour: src\/server.js:3\n/);
    assert.doesNotMatch(result.stdout, /error/);

    codetour(["add", "server", "--at", "src/server.js:7-11", "--title", "Startup", "--description", "x"]);
    codetour(["add", "server", "--dir", "src", "--description", "Sources", "--after", "1"]);

    const steps = tour().steps;
    assert.deepStrictEqual(
      steps.map((s: any) => s.title || s.directory || s.line),
      ["Overview", "src", 3, "Startup"]
    );
    assert.strictEqual(steps[0].description, "### Overview\n\nStart at [#2].");
    assert.deepStrictEqual(steps[3].selection, { start: { line: 7, character: 1 }, end: { line: 11, character: 2 } });
    assert.match(read(".tours/server.tour"), /^{\n  "\$schema": "https:\/\/aka.ms\/codetour-schema",\n  "title": "Server",\n  "description"/);
  });

  it("explains locations it can't use", () => {
    codetour(["new", "Server"]);
    let result = codetour(["add", "server", "--at", "src/server.js:/function/", "--description", "x"]);
    assert.strictEqual(result.code, 1);
    assert.match(result.stderr, /"function" appears on 2 lines of src\/server.js \(3, 7\)/);
    result = codetour(["add", "server", "--description", "x"]);
    assert.strictEqual(result.code, 2);
    assert.match(result.stderr, /add needs --at LOCATION, --dir DIR or --content/);
    result = codetour(["add", "server", "--at", "src/nope.js:1"]);
    assert.match(result.stderr, /file not found: src\/nope.js/);
  });

  it("edits, moves and removes steps", () => {
    codetour(["new", "Server"]);
    codetour(["add", "server", "--at", "src/server.js:3", "--title", "Handler", "--description", "a"]);
    codetour(["add", "server", "--at", "src/server.js:7", "--description", "b"]);
    codetour(["add", "server", "--content", "--title", "End", "--description", "c"]);

    assert.strictEqual(codetour(["edit", "server", "2", "--at", "src/server.js:/function start/", "--pattern", "--title", "Start"]).code, 0);
    const step = tour().steps[1];
    assert.strictEqual(step.title, "Start");
    assert.strictEqual(step.pattern, "function start");
    assert.strictEqual(step.line, undefined);

    codetour(["edit", "server", "1", "--title", ""]);
    assert.strictEqual(tour().steps[0].title, undefined);

    codetour(["move", "server", "3", "1"]);
    assert.strictEqual(tour().steps[0].title, "End");
    codetour(["rm", "server", "1", "3"]);
    assert.strictEqual(tour().steps.length, 1);

    const result = codetour(["rm", "server", "5"]);
    assert.strictEqual(result.code, 1);
    assert.match(result.stderr, /"Server" doesn't have a step #5 \(it has 1 step\)/);
  });

  it("keeps pattern steps anchored by pattern when they're moved", () => {
    codetour(["new", "Server"]);
    codetour(["add", "server", "--at", "src/server.js:/function handle/", "--pattern", "--description", "a"]);
    assert.strictEqual(tour().steps[0].pattern, "function handle");
    codetour(["edit", "server", "1", "--at", "src/server.js:/function start/"]);
    assert.deepStrictEqual([tour().steps[0].pattern, tour().steps[0].line], ["function start", undefined]);
    const result = codetour(["edit", "server", "1", "--at", "src/server.js:2"]);
    assert.strictEqual(result.code, 1);
    assert.match(result.stderr, /pass --no-pattern to anchor it by line number/);
    codetour(["edit", "server", "1", "--at", "src/server.js:3", "--no-pattern"]);
    assert.deepStrictEqual([tour().steps[0].pattern, tour().steps[0].line], [undefined, 3]);
  });

  it("selects code between two texts", () => {
    codetour(["new", "Server"]);
    codetour(["add", "server", "--at", "src/server.js:/function start/-/}/", "--description", "x"]);
    assert.deepStrictEqual(tour().steps[0].selection, { start: { line: 7, character: 1 }, end: { line: 11, character: 2 } });
    const result = codetour(["add", "server", "--at", "src/server.js:/module.exports/-/nope/", "--description", "x"]);
    assert.match(result.stderr, /"nope" doesn't appear in src\/server.js after line 13 without being indented more/);
  });

  it("uses a leading heading as a content step's title", () => {
    codetour(["new", "Server"]);
    assert.strictEqual(codetour(["add", "server", "--content", "--description", "-"], "### Links\n\nhello").code, 0);
    assert.strictEqual(codetour(["add", "server", "--content", "--description", "no heading"]).code, 2);
  });

  it("summarizes links to steps that don't exist yet", () => {
    codetour(["new", "Server"]);
    const result = codetour(["add", "server", "--content", "--title", "Overview", "--description", "See [#2], [#3] and [#4]."]);
    assert.match(result.stdout, /note: step #1 links to #2, #3, #4, which don't exist yet/);
    assert.doesNotMatch(result.stdout, /error/);
  });

  it("prints a step's raw description", () => {
    codetour(["new", "Server"]);
    codetour(["add", "server", "--content", "--title", "A", "--description", "line 1\n[#1] **bold**"]);
    assert.strictEqual(codetour(["show", "server", "--step", "1", "--raw"]).stdout, "line 1\n[#1] **bold**\n");
    assert.strictEqual(codetour(["show", "server", "--raw"]).code, 2);
  });

  it("deletes tours", () => {
    codetour(["new", "Server"]);
    codetour(["new", "Intro", "--next", "Server"]);
    const result = codetour(["delete", "server"]);
    assert.strictEqual(result.code, 0);
    assert.ok(!fs.existsSync(path.join(root, ".tours/server.tour")));
    assert.match(result.stdout, /warning: .tours\/intro.tour still has `nextTour` set to "Server"/);
  });

  it("edits tours and keeps links to them working", () => {
    codetour(["new", "Server"]);
    codetour(["new", "Intro", "--next", "Server", "--primary"]);
    codetour(["new", "Other", "--primary"]);
    assert.strictEqual(tour("intro").isPrimary, undefined);
    assert.strictEqual(tour("other").isPrimary, true);

    const { code, data } = json(["edit", "server", "--title", "The server"]);
    assert.strictEqual(code, 0);
    assert.deepStrictEqual(data.updated, [".tours/intro.tour"]);
    assert.strictEqual(tour("intro").nextTour, "The server");
  });

  it("shows steps with the code they point at", () => {
    codetour(["new", "Server"]);
    codetour(["add", "server", "--at", "src/server.js:3", "--title", "Handler", "--description", "Opens [the server](./src/server.js)."]);
    const result = codetour(["show", "server", "--context", "1"]);
    assert.match(result.stdout, /#1  Handler — src\/server.js:3 \(line\)/);
    assert.match(result.stdout, / {2}> {5}3 │ function handle\(req, res\) \{/);
    assert.match(result.stdout, /\.\/src\/server.js → src\/server.js/);

    const { data } = json(["show", "server"]);
    assert.strictEqual(data.steps[0].line, 3);
    assert.strictEqual(data.steps[0].kind, "line");
  });

  it("validates tours with meaningful exit codes", () => {
    codetour(["new", "Server"]);
    let result = codetour(["validate"]);
    assert.strictEqual(result.code, 0);
    assert.match(result.stdout, /\.tours\/server.tour:\d+: warning: the tour doesn't have any steps/);
    assert.strictEqual(codetour(["validate", "--strict"]).code, 1);

    write(".tours/bad.tour", '{\n  "title": "Bad",\n  "steps": [\n    {"file": "nope.js", "line": 1, "description": "x"}\n  ]\n}');
    write(".tours/broken.tour", "{ nope");
    write(".tours/README.md", "# not a tour");
    const { code, data } = json(["validate"]);
    assert.strictEqual(code, 1);
    assert.strictEqual(data.errors, 2);
    assert.deepStrictEqual(data.problems[0], {
      severity: "error",
      file: ".tours/bad.tour",
      line: 4,
      step: 1,
      message: "step #1: file not found: nope.js"
    });
    assert.match(data.problems[1].message, /^not a valid tour: /);
    assert.match(codetour(["validate", "server"]).stdout, /in 1 tour\n$/);
  });

  it("formats tours", () => {
    write(".tours/hand.tour", '{"title":"Hand","steps":[{"description":"x"}]}');
    const result = codetour(["fmt", "--check"]);
    assert.strictEqual(result.code, 1);
    assert.match(result.stdout, /would reformat .tours\/hand.tour/);
    assert.strictEqual(codetour(["fmt"]).code, 0);
    assert.strictEqual(codetour(["fmt", "--check"]).code, 0);
    assert.strictEqual(
      read(".tours/hand.tour"),
      '{\n  "$schema": "https://aka.ms/codetour-schema",\n  "title": "Hand",\n  "steps": [\n    {\n      "description": "x"\n    }\n  ]\n}'
    );
  });

  it("lists tours, including hidden ones", () => {
    codetour(["new", "Server"]);
    codetour(["new", "Web only", "--when", "isWeb"]);
    const result = codetour(["list"]);
    assert.match(result.stdout, /Server {2}\(0 steps\) {2}.tours\/server.tour/);
    assert.match(result.stdout, /Web only {2}\(0 steps\) {2}.tours\/web-only.tour {2}\[hidden: when isWeb\]/);
  });

  it("uses the workspace's custom tour directory", () => {
    write(".vscode/settings.json", '{\n  // comments are allowed\n  "codetour.customTourDirectory": "docs/tours",\n}');
    codetour(["new", "Docs"]);
    assert.ok(fs.existsSync(path.join(root, "docs/tours/docs.tour")));
    assert.match(codetour(["list"]).stdout, /Docs/);
  });

  describe("fix", () => {
    const moveCode = () => {
      write(
        "src/server.js",
        SERVER.replace('require("http");\n', 'require("http");\nconst log = console.log;\n\n').replace(
          "module.exports = { start };",
          "module.exports = { start, handle };"
        )
      );
      git("mv", "src/server.js", "src/app.js");
    };

    beforeEach(() => {
      git("init", "-q", "-b", "main");
      codetour(["new", "Server"]);
      codetour(["add", "server", "--at", "src/server.js:3", "--title", "Handler", "--description", "a"]);
      codetour(["add", "server", "--at", "src/server.js:7-11", "--title", "Startup", "--description", "b"]);
      codetour(["add", "server", "--at", "src/server.js:13", "--title", "Exports", "--description", "c"]);
      codetour(["add", "server", "--at", "src/server.js:/server.listen/", "--pattern", "--title", "Listen", "--description", "d"]);
      git("add", "-A");
      git("commit", "-q", "-m", "tour");
    });

    it("reports tours that are up to date", () => {
      const result = codetour(["fix"]);
      assert.strictEqual(result.code, 0);
      assert.match(result.stdout, /up to date/);
      assert.strictEqual(tour().steps[3].pattern, "server\\.listen");
    });

    it("re-anchors steps after lines moved and files were renamed", () => {
      moveCode();
      let result = codetour(["fix"]);
      assert.strictEqual(result.code, 1);
      assert.match(result.stdout, /step #1: file src\/server.js → src\/app.js, line 3 → 5/);
      assert.match(result.stdout, /step #2: file src\/server.js → src\/app.js, selection start 7 → 9, selection end 11 → 13/);
      assert.match(result.stdout, /step #3: line 13 of src\/app.js \("module.exports = \{ start \};"\) changed since/);
      // Pattern steps follow their line by themselves; only the rename applies.
      assert.match(result.stdout, /step #4: file src\/server.js → src\/app.js\n/);
      assert.strictEqual(tour().steps[0].line, 3);

      result = codetour(["fix", "--write"]);
      assert.strictEqual(result.code, 1);
      assert.match(result.stdout, /re-anchored 3 steps/);
      const steps = tour().steps;
      assert.deepStrictEqual([steps[0].file, steps[0].line], ["src/app.js", 5]);
      assert.deepStrictEqual([steps[1].selection.start.line, steps[1].selection.end.line], [9, 13]);
      // Steps that need to be fixed by hand are left alone (validate reports them).
      assert.deepStrictEqual([steps[2].file, steps[2].line], ["src/server.js", 13]);
      assert.strictEqual(steps[3].file, "src/app.js");
      assert.match(codetour(["validate"]).stdout, /step #3: file not found: src\/server.js/);
    });

    it("doesn't move steps twice, or steps added since the tour was committed", () => {
      moveCode();
      codetour(["fix", "--write"]);
      codetour(["add", "server", "--at", "src/app.js:/function start/", "--description", "new"]);
      // The tour isn't committed again: steps already fixed or added keep their lines.
      const result = codetour(["fix"]);
      assert.match(result.stdout, /step #3: line 13 of src\/app.js \(/);
      assert.doesNotMatch(result.stdout, /step #[1245]:/);
      assert.strictEqual(codetour(["fix", "--base", "HEAD", "--write"]).code, 1);
      const steps = tour().steps;
      assert.deepStrictEqual([steps[0].line, steps[4].line], [5, 9]);
    });

    it("reports pattern steps whose line changed", () => {
      write("src/server.js", SERVER.replace("server.listen(port);", "server.listen(port, host);").replace("listen", "bind"));
      const result = codetour(["fix"]);
      assert.strictEqual(result.code, 1);
      assert.match(result.stdout, /step #4: the pattern no longer matches src\/server.js \(at \w+ it matched line 9: "server.listen\(port\);"\)/);
    });

    it("explains renames git doesn't know about", () => {
      fs.renameSync(path.join(root, "src/server.js"), path.join(root, "src/app.js"));
      assert.match(codetour(["fix"]).stdout, /src\/server.js no longer exists \(if it was renamed, stage the rename/);
    });

    it("skips tours that aren't committed yet", () => {
      codetour(["new", "Fresh"]);
      const result = codetour(["fix", "fresh"]);
      assert.strictEqual(result.code, 0);
      assert.match(result.stdout, /skipped: the tour hasn't been committed yet/);
    });

    it("warns about drift when validating", () => {
      moveCode();
      // The steps' file was renamed (an error), and fix can repair that (a warning).
      const { code, data } = json(["validate"]);
      assert.strictEqual(code, 1);
      const messages = data.problems.map((p: any) => p.message);
      assert.ok(messages.some((m: string) => /^step #1: its code moved since \w+ \(file src\/server.js → src\/app.js, line 3 → 5\); run `codetour fix --write`$/.test(m)), messages.join("\n"));
      assert.ok(messages.includes("step #1: file not found: src/server.js"));

      // Moved lines alone are warnings, which --strict turns into a failure.
      git("mv", "src/app.js", "src/server.js");
      assert.strictEqual(codetour(["validate"]).code, 0);
      assert.strictEqual(codetour(["validate", "--strict"]).code, 1);
    });
  });

  it("runs as a program, reading descriptions from stdin", () => {
    codetour(["new", "Server"]);
    const cli = path.join(__dirname, "..", "src", "cli", "index.js");
    const result = spawnSync(process.execPath, [cli, "add", "server", "--content", "--title", "Piped", "--description", "-"], {
      cwd: root,
      input: "line 1\nline 2\n",
      encoding: "utf8"
    });
    assert.strictEqual(result.status, 0, result.stderr);
    assert.strictEqual(tour().steps[0].description, "line 1\nline 2");
  });
});
