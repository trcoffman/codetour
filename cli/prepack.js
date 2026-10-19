// Copies the built CLI, the skill and the docs from the repository root into this package.
const fs = require("fs");
const path = require("path");

const root = path.join(__dirname, "..");

if (!fs.existsSync(path.join(root, "dist", "cli.js"))) {
  console.error("dist/cli.js is missing; run `npm run build` in the repository root first.");
  process.exit(1);
}

fs.mkdirSync(path.join(__dirname, "dist"), { recursive: true });
for (const file of ["cli.js", "cli.js.map"]) {
  fs.copyFileSync(path.join(root, "dist", file), path.join(__dirname, "dist", file));
}
fs.cpSync(path.join(root, "skills"), path.join(__dirname, "skills"), { recursive: true });
for (const file of ["LICENSE.txt", "README.md"]) {
  fs.copyFileSync(path.join(root, file), path.join(__dirname, file));
}
