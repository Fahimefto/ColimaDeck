# Architecture

ColimaDeck is a thin SwiftUI layer over the `colima` and `docker` command-line tools. It keeps no data of its own. Everything you see comes from running a command and reading its output, so the app can't drift out of sync with what you do in a terminal.

```
Views  ──calls──▶  AppStore  ──runs──▶  Shell  ──▶  colima / docker / osascript
  ▲                   │
  └──── observes ─────┘
```

## Files

```
Sources/ColimaDeck/
├── ColimaDeckApp.swift    App entry: the main window and the menu bar item
├── Shell.swift            Runs a command and collects or streams its output
├── Models.swift           Machine, Container, ContainerStats, DockerImage, DockerVolume, ActivityEntry
├── MachineConfig.swift    Every `colima start` option, as arguments, and reading and writing colima.yaml
├── AppStore.swift         State, refreshing, and every action
└── Views/
    ├── ContentView.swift      Sidebar and navigation
    ├── Components.swift       StatusDot, Meter, Pill, MachinePicker, DockerGate
    ├── MachinesView.swift     Machine cards and their menu
    ├── MachineSettingsSheet.swift  The form for creating a machine, editing one, or editing the template
    ├── MachineDetailView.swift     Status, Kubernetes, commands, SSH, runtime and AI models
    ├── ToolsView.swift        Template, clean-up, output detail and tab completion
    ├── SetupView.swift        Installs Colima and the Docker CLI when they're missing
    ├── ContainersView.swift   Container list, details panel and logs
    ├── ImagesView.swift
    ├── VolumesView.swift
    ├── ActivityView.swift
    └── MenuBarView.swift
```

## Shell

`Shell.run(tool, args, env:, onOutput:)` finds the tool, runs it, and returns a `CommandResult` with the exit status, stdout and stderr.

- **PATH.** Apps opened from Finder don't get your shell's `PATH`, so Homebrew's folders (`/opt/homebrew/bin`, `/usr/local/bin`) are added to the front. Colima needs this too, because it calls `limactl` and `docker` itself.
- **Streaming.** `onOutput` receives output as it arrives, which is how long operations like `colima start` show progress in Activity.
- **Background processes.** `colima start` launches Lima's host agent, which can inherit the output pipes and keep them open after `colima` exits. `Shell` waits at most two seconds for the pipes to close after the command exits, so it never hangs.
- **Environment.** Extra variables are passed per command. An empty value removes a variable, which is how the app clears `DOCKER_CONTEXT`.

## Models

Every CLI is called with JSON output (`colima list --json`, `docker ... --format '{{json .}}'`), which prints one JSON object per line. `decodeLines(_:from:)` decodes each line and skips any it can't read, so a new CLI version adding fields or printing a warning doesn't break the app.

`Machine` works out where a machine's files live (`$COLIMA_HOME` or `~/.colima`, then the machine name). That gives it the Docker socket and the `colima.yaml` path.

## MachineConfig

`MachineConfig` holds every option `colima start` accepts, except `--edit`, `--editor` and `--foreground`, which only make sense in a terminal. The same settings form uses it in three ways.

### Creating a machine

`createArguments(template:)` turns the form into a `colima start <name>` command. Options are always passed in the `--option=value` form, so values that start with a dash (like k3s arguments) aren't mistaken for options. The command includes the main choices, plus anything that differs from where Colima would otherwise get the value: the template, or Colima's built-in defaults when the template is off. That keeps the command short and still exact. The form shows the command before you run it.

### Editing a machine

The form starts from the machine's `colima.yaml`, read by `SimpleYAML`. Saving writes the changes back into that file with `applied(to:changedFrom:)`. Colima reads the file each time a machine starts, so **Save and Restart** restarts the machine (or starts it, if it's stopped) to apply them.

Writing the file directly, rather than passing options to `colima start`, means:

- Changes can be saved without restarting, and applied later.
- Lists can be emptied. There's no `colima start` option for "no DNS servers".

Architecture, VM type, runtime, disk image and system disk size can't change after a machine is created, so the form locks them.

### Editing the template

Colima's template (`~/.colima/_templates/default.yaml`) is the starting point for new machines. It doesn't exist until someone creates it. The app doesn't create it with `colima template`, because that writes a starter file with `vmType: qemu`, which would quietly make new machines use QEMU instead of Colima's normal default, `vz`. Instead, **Create Template** starts from the first machine's settings (or the app's defaults if there are no machines) and writes every value, so the template doesn't depend on Colima's starter file.

### Reading and writing YAML

`SimpleYAML` reads what Colima's settings files use: nested maps, scalar values, lists, and lists of maps. Map keys may contain dots, like `example.test` under `dnsHosts`.

`YAMLEditor` changes values in place, line by line. Only the values you changed are rewritten. Everything else stays exactly as it was, including comments and settings the app doesn't know about (like Docker daemon settings). Saving with nothing changed leaves the file byte-for-byte identical. Missing keys are added at the end of their section, and text values are quoted when YAML would otherwise misread them (for example `true`, `1`, or anything containing `:`).

## Setup

On launch, `refreshMachines` notes whether `colima` and `docker` can be found. If either is missing, `SetupView` offers to install them with `brew install`. If Homebrew isn't installed, it opens Terminal with Homebrew's official installer, because that asks for the user's password.

## AppStore

`AppStore` is a `@MainActor @Observable` class shared by the window and the menu bar.

### Refreshing

`startPolling()` runs two loops:

| Every | Refreshes |
| --- | --- |
| 3 seconds | Machines (`colima list`), then containers (`docker ps -a`) |
| 4 seconds | Container stats (`docker stats --no-stream`), only when something is running |

Images and volumes refresh when you open their screen and after any action. The store only replaces a list when it has actually changed, to avoid redrawing for nothing.

### Which Docker engine

`selectedMachineName` picks the machine the Docker screens use. Every `docker` command runs with `DOCKER_HOST=unix://<machine>/docker.sock` and with `DOCKER_CONTEXT` unset, so the app never changes or depends on your active context. `dockerMachine` returns the selected machine only if it's running the Docker runtime. `DockerGate` uses that to decide whether to show a screen's content or explain why it can't.

### Actions

Every action goes through `track(...)`, which takes one or more commands to run in order, stopping at the first failure, and:

1. Adds the **Detail in Activity** setting's `--verbose` or `--very-verbose` to `colima` commands, except `colima model`, which passes its arguments on to the model runner
2. Adds an entry to Activity and streams the command's output into it
3. Marks the item busy in `busy` (keyed by machine name or container ID), which shows a label like "Starting…" and disables its buttons
4. When the commands finish (or one fails), marks the entry done or failed and shows an alert if it failed
5. Refreshes machines, containers, images and volumes

To add an action, add an `AppStore` method that calls `track` with the command, then add a button that calls the method.

Logs are the exception. `logs(for:)` runs `docker logs` through `sh -c '... 2>&1'` so stdout and stderr stay in the order they were written, and returns the text directly. The details panel calls it every two seconds while **Follow** is on.

### Terminal

**Open Terminal** uses AppleScript to run `colima ssh -p <name>` or `docker exec -it <id> ...` in a new Terminal window. AI model **Chat** and **Serve**, and **Open nerdctl in Terminal**, work the same way, because they're interactive or run until stopped. That's why the app asks for permission to control Terminal the first time.

## Packaging

`build-app.sh` builds a release binary for Apple Silicon and for Intel with SwiftPM, merges them with `lipo`, wraps the result in a `.app` bundle with a generated `Info.plist`, and signs it locally (`codesign --sign -`). With `--dmg` it also packages the app in a disk image with an Applications shortcut. The app icon is drawn in code by `scripts/make-icon.swift`, which writes `Resources/AppIcon.icns` (bundled into the app) and `Resources/AppIcon.png` (shown in the README). There's no Xcode project; `Package.swift` is the only build file. The version number is set at the top of `build-app.sh`.
