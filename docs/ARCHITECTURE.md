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
├── AppStore.swift         State, refreshing, and every action
└── Views/
    ├── ContentView.swift      Sidebar and navigation
    ├── Components.swift       StatusDot, Meter, Pill, MachinePicker, DockerGate
    ├── MachinesView.swift     Machine cards and the New Machine form
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

Every action goes through `track(...)`, which:

1. Adds an entry to Activity and streams the command's output into it
2. Marks the item busy in `busy` (keyed by machine name or container ID), which shows a label like "Starting…" and disables its buttons
3. When the command finishes, marks the entry done or failed and shows an alert if it failed
4. Refreshes machines, containers, images and volumes

To add an action, add an `AppStore` method that calls `track` with the command, then add a button that calls the method.

Logs are the exception. `logs(for:)` runs `docker logs` through `sh -c '... 2>&1'` so stdout and stderr stay in the order they were written, and returns the text directly. The details panel calls it every two seconds while **Follow** is on.

### Terminal

**Open Terminal** uses AppleScript to run `colima ssh -p <name>` or `docker exec -it <id> ...` in a new Terminal window. That's why the app asks for permission to control Terminal the first time.

## Packaging

`build-app.sh` builds a release binary with SwiftPM, wraps it in a `.app` bundle with a generated `Info.plist`, and signs it locally (`codesign --sign -`). There's no Xcode project; `Package.swift` is the only build file.
