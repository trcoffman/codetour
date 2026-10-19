# Security Policy

## Reporting a vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

Use GitHub's private vulnerability reporting for this repository instead: go to the [Security tab](https://github.com/trcoffman/codetour/security) and choose **Report a vulnerability**. Include as much of the following as you can, so the problem can be reproduced and fixed quickly:

- The type of issue (for example, command injection through a tour file, or path traversal)
- The affected component (the VS Code extension, the `codetour` CLI or the Neovim plugin) and version
- Steps to reproduce, ideally with a minimal `.tour` file
- The impact, and how an attacker could exploit it

Tour files can contain command links and shell commands that run when a user follows a step, so reports about how tours from untrusted sources are handled are especially welcome.

This is a volunteer-maintained project. Reports are acknowledged as soon as possible, and fixes are released and credited in the changelog once they're ready.

## Supported versions

Only the latest release of CodeTour+ receives security fixes.
