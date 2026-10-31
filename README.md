# ColimaDeck

A native macOS app for managing [Colima](https://github.com/abiosoft/colima): your Colima machines, and the Docker containers, images and volumes running inside them, all in one window instead of a stack of terminal commands.

Built with SwiftUI. No Electron, no background daemon. It runs the `colima` and `docker` commands you already have installed.

## Features

### Machines
- A card for each Colima machine (profile) showing its status, CPUs, memory, disk, architecture, runtime and IP address
- Start, stop, restart, force stop and delete, with progress shown on the card
- **New Machine** form: name, CPUs, memory, disk, runtime (Docker, containerd, Incus), Kubernetes (k3s), VM type (Apple Virtualization or QEMU), Rosetta, and a dedicated IP address
- Open a shell inside the machine in Terminal (`colima ssh`)
- Open the machine's `colima.yaml` to edit advanced settings

### Containers
- Grouped by Docker Compose project, with **Start All** and **Stop All** buttons for each project
- Live CPU and memory bars for running containers
- Published ports shown as buttons that open `http://localhost:<port>`
- Start, stop, restart, pause, resume and remove
- A side panel with the container's details and logs, which update as new output arrives
- Open a shell inside the container in Terminal (uses bash if it's there, otherwise sh)
- Filter by name, image or project, or show running containers only

### Images and Volumes
- Tables you can filter by name
- Pull images by name (for example `postgres:17`)
- Remove selected items, or delete everything unused with **Clean Up** (the app asks first)

### Activity
- The full output of every command the app has run, newest first. Failed commands open automatically so you can see why.

### Menu bar
- Start and stop machines, and see how many containers are running, without opening the window. Closing the window leaves the app running in the menu bar.

## Requirements

- macOS 14 (Sonoma) or later
- Colima and the Docker CLI:

  ```sh
  brew install colima docker
  ```

- To build from source: Xcode or the Xcode Command Line Tools, with Swift 5.10 or later (`xcode-select --install`)

## Install

```sh
git clone https://github.com/Fahimefto/ColimaDeck.git
cd ColimaDeck
./build-app.sh --install
```

This builds a release version and copies `ColimaDeck.app` into `/Applications`. Without `--install`, the app is left at `build/ColimaDeck.app`.

The app is signed locally rather than with a developer certificate. If macOS blocks it the first time, right-click the app and choose **Open**.

## Using it

1. Open **Machines**. If you don't have a machine yet, click **New Machine**. The first start downloads a VM image, which can take a few minutes. You can follow its progress in **Activity**.
2. Once a machine is running, **Containers**, **Images** and **Volumes** show what's inside it.
3. If you have more than one machine, use the machine picker in the toolbar to choose which one the Docker screens show.

### A note on `docker context`

ColimaDeck connects to each machine's Docker socket directly (`~/.colima/<name>/docker.sock`), so it **never changes your active Docker context**. That means it works fine alongside OrbStack or Docker Desktop.

Colima itself is different: by default, starting a machine makes it your active context. To stop that, set this in the machine's `colima.yaml` (**⋯ → Edit Settings File** on the machine card):

```yaml
autoActivate: false
```

## Troubleshooting

| Problem | Fix |
| --- | --- |
| "Colima isn't installed" | Run `brew install colima docker`. The app looks in `/opt/homebrew/bin`, `/usr/local/bin` and the usual system folders. |
| A machine won't start | Open **Activity** and expand the failed entry to see Colima's full output. |
| "Docker isn't available" | The machine uses containerd or Incus. The Docker screens need a machine running the Docker runtime. |
| **Open Terminal** does nothing | Allow ColimaDeck to control Terminal in **System Settings → Privacy & Security → Automation**. |
| You use a custom Colima home folder | Launch the app with `COLIMA_HOME` set, for example `COLIMA_HOME=~/vms open /Applications/ColimaDeck.app`. |

## Development

```sh
swift run          # build and run from source
swift build        # build only
./build-app.sh     # build the .app
```

You can open `Package.swift` in Xcode to work on the UI with previews and the debugger.

To understand how the code fits together, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Contributions are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).
