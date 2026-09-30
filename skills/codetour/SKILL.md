---
name: codetour
description: Create, update, review and validate CodeTour tours (*.tour files) — guided, step-by-step walkthroughs of a codebase that play in VS Code and Neovim. Use when the user asks for a code tour, an onboarding walkthrough or a guided explanation saved as a tour, or asks to update, fix or check existing tours (e.g. after code changes or when CI reports tour problems).
---

# CodeTour

A tour is a JSON file (usually in `.tours/`) with a title and a list of steps.
Each step is attached to a line or selection of a file, a directory, or
nothing (a "content" step), and has a markdown description. Editors show the
step's description next to its code, and viewers move from step to step.

Use the `codetour` CLI for all changes: it finds lines from text, writes the
format the editors expect, and reports problems after every change. Only
hand-edit a tour file when the CLI can't express the change, and then run
`codetour fmt` and `codetour validate` on it.

## The CLI

Run `codetour help` for the full reference. If `codetour` isn't on the PATH,
use `bin/codetour` from the CodeTour repository (after `npm install && npm run
build` there). Every command takes `--json`.

`<tour>` is a title, a unique part of a title, a file name (`intro`) or a
path. Steps are numbered from 1. Locations (`--at`) are:

- `FILE:/TEXT/` — the only line containing TEXT (plain text, not a regex).
  **Prefer this**: it's how you know the code, and it fails loudly when TEXT
  is missing or ambiguous (make TEXT longer then).
- `FILE:LINE` — a line number, when text doesn't work.
- `FILE:/START/-/END/` or `FILE:FIRST-LAST` — a selection, highlighted when
  the step is shown. `/START/-/END/` goes from the only line containing START
  to the next line containing END that isn't indented more than START's line
  (e.g. the `}` closing START's block). Keep selections to a few lines (see
  "Choosing stops").

`--pattern` (single lines only) anchors the step to TEXT itself instead of a
line number, so the step keeps finding its line when code above it changes.
Use it for steps on stable, distinctive code (a function signature). A
pattern step stays a pattern step when you move it with `edit --at` (pass
`--no-pattern` to switch it to a line number).

## Creating a tour

1. Understand the flow you're explaining before writing steps: read the code
   and follow the path of a request, a command or the data. Plan 5-12 steps
   in the order a reader should see them.
2. Create the tour and an overview step (a leading `### Heading` becomes the
   step's title):

   ```sh
   codetour new "Request lifecycle" --description "How an HTTP request is handled"
   codetour add request --content --description - <<'EOF'
   ### Overview

   This tour follows a request from the router to the response. It assumes you know [Express basics](https://expressjs.com/en/guide/routing.html).
   EOF
   ```

3. Add a step for each stop, in order:

   ```sh
   codetour add request --at 'src/server.ts:/app.use(router)/' --pattern --title "Routing" --description - <<'EOF'
   Every request goes through `router`. Routes are registered in [#4].
   EOF
   codetour add request --at 'src/handlers/user.ts:/export async function loadUser(/' --pattern --title "Loading the user" --description - <<'EOF'
   `loadUser` looks the user up by the session id and caches it on the request. Notice the early return for guests: they never reach the database. Errors go to the middleware in [#6].
   EOF
   ```

   Read the output of every command: it shows the step it added and any
   problems. Links to steps you haven't added yet are listed as a `note` —
   they resolve once you add those steps.
4. Check the result and read it like a reviewer would:

   ```sh
   codetour validate request     # must report 0 errors
   codetour show request         # each step with the code around its line
   ```

   In `show`, check that the marked (`>`) lines are the code each description
   talks about. Fix a step with `codetour edit request 3 --at 'FILE:/TEXT/'`.

## Choosing stops

- Put each stop on a single line: the line that names what the step is
  about. For a function, class or component, that's the line with its name
  (`export async function loadUser(`), not its whole body. A big highlighted
  block is tiring to read, and the reader sees the code right below the line
  anyway.
- When one line inside a function is the point (the call that does the work,
  the condition that decides, the line with the bug), make that line its own
  stop rather than highlighting the function around it.
- Use a selection only for a short snippet (a few lines) whose extent
  matters, e.g. a few statements that must stay together. Don't select a
  whole function.
- In the description, name the parts of the code the reader should notice
  (the retry loop, the early return for guests) instead of highlighting them.

## Writing descriptions

- Explain *why* and *how things connect*, not just what the line says. Point
  out what to notice and what to skip.
- Start with `### Heading` (or pass `--title`): it's the step's name in the
  editor's list of steps.
- Link to other steps with `[#3]` (or `[text][#3]`), to other tours by title
  with `[Tour title]` or `[Tour title#2]`, and to files with
  `[text](./path/to/file)`. A misspelled tour title in brackets is just text,
  so check `show`'s list of links.
- `>> npm test` on its own line becomes a link that runs the command in a
  terminal. A fenced code block with a language gets an "Insert Code" link.
- Write each paragraph on one line; don't hard-wrap prose (the editors wrap it
  to fit, and hard-wrapped lines look ragged in narrow windows).
- Don't mention line numbers in descriptions; they go stale.
- Keep steps short. Split a long explanation across steps instead.

## Changing tours

```sh
codetour edit <tour> <step> [--title T] [--description TEXT|-] [--at LOCATION] [--pattern | --no-pattern] [--icon I]
codetour edit <tour> [--title T] [--description TEXT] [--primary] [--next "Next tour"] [--when EXPR]
codetour add <tour> ... --after N          # insert instead of appending
codetour move <tour> <step> <position>
codetour rm <tour> <step>...
codetour delete <tour>
```

An empty value removes an optional property (`--title ""`). Renaming a tour
updates the `nextTour` links of other tours. To change part of a
description, print it, edit it, and pipe it back:

```sh
codetour show <tour> --step 3 --raw > /tmp/step.md   # edit the file, then:
codetour edit <tour> 3 --description - < /tmp/step.md
```

Tour series: titles like `1 - Basics`, `2 - Plugins` are linked in order
(the last step offers the next tour), and `1 - ...` is the default tour.
`--primary` marks the tour to start with otherwise.

## Keeping tours up to date

When code changes, steps can end up on the wrong lines while the tour still
looks valid. `codetour validate` catches this for tours in git history: it
warns about steps whose code moved or changed since the tour file was last
committed. To repair them:

```sh
codetour fix              # dry run: how each step would move (exit code 1 if any)
codetour fix --write      # apply what it could work out
codetour validate
```

`fix` follows moved lines and renamed files (stage renames with `git mv` or
`git add` so git knows about them) for the steps that are unchanged since the
tour's last commit; steps you added or re-anchored since then are left
alone, so running it twice is safe. Steps whose own line changed are
reported with the old line's text, and left untouched: find where that code
went, run `codetour edit <tour> <step> --at 'FILE:/TEXT/'`, and re-read the
description, since the code may mean something else now.

A tour needs to be committed once before `fix` has a base to compare with
(with jj, `jj commit` or `jj new`). Tours pinned to a git `ref` never drift.

## Finishing up

- Run `codetour validate` on everything you changed and fix every error.
  Warnings are worth fixing too (`--strict` treats them as errors).
- Tell the user how to take the tour: in VS Code, "CodeTour: Start Tour"; in
  Neovim, `:CodeTour start <tour>`. If you're running inside Neovim (`$NVIM`
  is set), you can open it for them:
  `nvim --server "$NVIM" --remote-send '<C-\><C-n>:CodeTour start <tour><CR>'`.
