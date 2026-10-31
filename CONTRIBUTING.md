# Contributing

Thanks for helping improve ColimaDeck.

## Getting set up

```sh
brew install colima docker
git clone https://github.com/Fahimefto/ColimaDeck.git
cd ColimaDeck
swift run
```

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first. It's short and explains where everything goes.

## Guidelines

- **Use the CLIs.** The app gets everything from `colima` and `docker`. Prefer their JSON output over parsing text tables.
- **Don't change the user's setup without asking.** Run `docker` commands with the selected machine's `DOCKER_HOST` and never switch the user's `docker context`. Deleting machines, volumes, or many items at once needs a confirmation dialog.
- **Run actions through `AppStore.track`** so they show progress, appear in Activity, and report failures.
- **Match the existing style.** Use SwiftUI and system colors, fonts and SF Symbols, and keep each screen in its own file under `Views/`.
- **Write plain labels.** Say "Remove unused images", not "Prune dangling artifacts".

## Before opening a pull request

- `swift build` finishes with no errors or warnings
- `./build-app.sh` builds the app, and you've tried your change in it
- If your change affects machines, you've tried it with a machine both running and stopped
- The README is updated if you added or changed a feature

Describe what you changed and how you tested it in the pull request.
