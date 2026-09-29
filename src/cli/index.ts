// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

import * as fs from "fs";
import { run } from "./main";

const result = run(process.argv.slice(2), {
  cwd: process.cwd(),
  readStdin: () => fs.readFileSync(0, "utf8")
});
process.stdout.write(result.stdout);
process.stderr.write(result.stderr);
process.exitCode = result.code;
