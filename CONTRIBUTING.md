# Contributing

Contributions and suggestions are welcome. CodeTour+ is a maintained fork of [Microsoft's CodeTour](https://github.com/microsoft/codetour), and is released under the same MIT license. By submitting a pull request, you agree that your contribution is licensed under it.

## Getting Started

Hey 👋 Thanks for wanting to contribute to `CodeTour+`! Getting started is simple:

1. Clone the repository
1. CD into the cloned directory
1. Run `npm install`
1. Make your changes and press `F5` to debug them

If you want to test/install the extension outside of a debugging session, perform the following:

1. Run `npm run package` to create a vsix
1. Run `code --install-extension <vsix-path>` to install the extension

Tests:

1. `npm test` runs the tests of the shared core (`src/core`) and the `codetour` CLI (`src/cli`)
1. `make test` runs the Neovim plugin's tests (`lua/`, `tests/`), which needs `nvim` on your PATH

If you run into any issues or have any questions, please don't hesitate to file an issue on this repo, and we'll try to get you unblocked ASAP 👍
