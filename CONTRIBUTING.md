# Contributing

This project welcomes contributions and suggestions. Most contributions require you to
agree to a Contributor License Agreement (CLA) declaring that you have the right to,
and actually do, grant us the rights to use your contribution. For details, visit
https://cla.microsoft.com.

When you submit a pull request, a CLA-bot will automatically determine whether you need
to provide a CLA and decorate the PR appropriately (e.g., label, comment). Simply follow the
instructions provided by the bot. You will only need to do this once across all repositories using our CLA.

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/).
For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/)
or contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.

## Getting Started

Hey 👋 Thanks for wanting to contribute to `CodeTour`! Getting started is simple:

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
