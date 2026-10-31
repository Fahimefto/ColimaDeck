import Foundation

/// Every `colima start` option the app can set, except `--edit`, `--editor` and `--foreground`,
/// which only make sense in a terminal.
struct MachineConfig: Equatable {
    struct Mount: Equatable, Identifiable {
        var id = UUID()
        var path: String
        var writable: Bool

        static func == (lhs: Mount, rhs: Mount) -> Bool {
            lhs.path == rhs.path && lhs.writable == rhs.writable
        }
    }

    static let hostArch: String = {
        #if arch(arm64)
        "aarch64"
        #else
        "x86_64"
        #endif
    }()

    var name = ""

    // Resources
    var cpus = 2
    var memoryGiB = 4.0
    var diskGiB = 100
    var rootDiskGiB = 20
    var arch = MachineConfig.hostArch
    var cpuType = ""
    var diskImage = ""

    // Runtime
    var runtime = "docker"
    var kubernetes = false
    var kubernetesVersion = ""
    var k3sArgs = ["--disable=traefik"]
    var k3sListenPort = 0
    var activate = true

    // Virtual machine
    var vmType = "vz"
    var rosetta = true
    var binfmt = true
    var nestedVirtualization = false
    var hostname = ""

    // Shared folders
    var mounts: [Mount] = []
    var disableMounts = false
    var mountType = "virtiofs"
    var mountInotify = true

    // Network
    var networkAddress = false
    var networkMode = "shared"
    var networkInterface = "en0"
    var networkPreferredRoute = false
    var networkHostAddresses = false
    var gatewayAddress = ""
    var dns: [String] = []
    var dnsHosts: [String] = [] // "name=ip"
    var portForwarder = "ssh"

    // SSH
    var sshAgent = false
    var sshConfig = true
    var sshPort = 0

    // Environment variables inside the VM, "KEY=VALUE"
    var env: [String] = []

    // How Colima treats its settings files
    var useTemplate = true
    var saveConfig = true

    /// Each option as `colima start` arguments, keyed by flag name. An empty array means "not passed".
    var flags: [(key: String, args: [String])] {
        var result: [(String, [String])] = []
        func add(_ key: String, _ args: [String]) { result.append((key, args)) }
        func value(_ key: String, _ value: String) { add(key, value.isEmpty ? [] : ["--\(key)=\(value)"]) }
        func bool(_ key: String, _ value: Bool) { add(key, ["--\(key)=\(value)"]) }
        func number(_ key: String, _ value: Int) { add(key, value == 0 ? [] : ["--\(key)=\(value)"]) }
        func list(_ key: String, _ values: [String]) {
            add(key, values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { "--\(key)=\($0)" })
        }

        number("cpus", cpus)
        value("memory", memoryGiB.rounded() == memoryGiB ? "\(Int(memoryGiB))" : "\(memoryGiB)")
        number("disk", diskGiB)
        number("root-disk", rootDiskGiB)
        value("arch", arch)
        value("cpu-type", cpuType)
        value("disk-image", diskImage)

        value("runtime", runtime)
        bool("kubernetes", kubernetes)
        value("kubernetes-version", kubernetesVersion)
        list("k3s-arg", k3sArgs)
        number("k3s-listen-port", k3sListenPort)
        bool("activate", activate)

        value("vm-type", vmType)
        add("vz-rosetta", vmType == "vz" ? ["--vz-rosetta=\(rosetta)"] : [])
        bool("binfmt", binfmt)
        bool("nested-virtualization", nestedVirtualization)
        value("hostname", hostname)

        if disableMounts {
            add("mount", ["--mount=none"])
        } else {
            list("mount", mounts.map { $0.writable ? "\($0.path):w" : $0.path })
        }
        value("mount-type", mountType)
        bool("mount-inotify", mountInotify)

        bool("network-address", networkAddress)
        value("network-mode", networkMode)
        add("network-interface", networkMode == "bridged" ? ["--network-interface=\(networkInterface)"] : [])
        bool("network-preferred-route", networkPreferredRoute)
        bool("network-host-addresses", networkHostAddresses)
        value("gateway-address", gatewayAddress)
        list("dns", dns)
        list("dns-host", dnsHosts)
        value("port-forwarder", portForwarder)

        bool("ssh-agent", sshAgent)
        bool("ssh-config", sshConfig)
        number("ssh-port", sshPort)

        list("env", env)

        bool("template", useTemplate)
        bool("save-config", saveConfig)
        return result
    }

    /// Arguments for creating a new machine. Colima fills in anything not passed from the template
    /// (or its built-in defaults when the template is off), so only pass what differs from that, plus
    /// the main choices and anything whose built-in default differs from this app's.
    func createArguments(template: MachineConfig?) -> [String] {
        let base = useTemplate ? (template ?? MachineConfig()) : MachineConfig()
        let defaults = Dictionary(base.flags, uniquingKeysWith: { a, _ in a })
        let always: Set = ["cpus", "memory", "disk", "runtime", "vm-type", "arch", "kubernetes", "vz-rosetta", "mount-type"]
        return ["start", name] + flags
            .filter { !$0.args.isEmpty && (always.contains($0.key) || defaults[$0.key] != $0.args) }
            .flatMap(\.args)
    }
}

// MARK: - Writing colima.yaml

extension MachineConfig {
    /// Writes this config into a Colima settings file, changing only the values that differ from
    /// `original` (or every value when `original` is nil). Everything else in the file, including
    /// comments and settings the app doesn't know about, stays as it was.
    func applied(to text: String, changedFrom original: MachineConfig?) -> String {
        var editor = YAMLEditor(text)
        func changed<T: Equatable>(_ keyPath: KeyPath<MachineConfig, T>) -> Bool {
            original.map { $0[keyPath: keyPath] != self[keyPath: keyPath] } ?? true
        }
        func set<T: Equatable>(_ keyPath: KeyPath<MachineConfig, T>, _ path: String, _ value: String) {
            if changed(keyPath) { editor.set(path, value) }
        }
        func setList(_ keyPath: KeyPath<MachineConfig, [String]>, _ path: String) {
            if changed(keyPath) { editor.setList(path, self[keyPath: keyPath].filter { !$0.isEmpty }.map(YAMLEditor.quote)) }
        }
        func setMap(_ keyPath: KeyPath<MachineConfig, [String]>, _ path: String) {
            guard changed(keyPath) else { return }
            let pairs = self[keyPath: keyPath].compactMap { item -> (String, String)? in
                guard let equals = item.firstIndex(of: "=") else { return nil }
                let key = item[..<equals].trimmingCharacters(in: .whitespaces)
                return key.isEmpty ? nil : (key, String(item[item.index(after: equals)...]))
            }
            editor.setMap(path, pairs.map { (YAMLEditor.quote($0.0), YAMLEditor.quote($0.1)) })
        }

        set(\.cpus, "cpu", "\(cpus)")
        set(\.memoryGiB, "memory", memoryGiB.rounded() == memoryGiB ? "\(Int(memoryGiB))" : "\(memoryGiB)")
        set(\.diskGiB, "disk", "\(diskGiB)")
        set(\.rootDiskGiB, "rootDisk", "\(rootDiskGiB)")
        set(\.arch, "arch", arch)
        set(\.cpuType, "cpuType", YAMLEditor.quote(cpuType))
        set(\.diskImage, "diskImage", YAMLEditor.quote(diskImage))

        set(\.runtime, "runtime", runtime)
        set(\.kubernetes, "kubernetes.enabled", "\(kubernetes)")
        // An empty version or gateway means "Colima's default", so leave those out rather than write "".
        if !kubernetesVersion.isEmpty { set(\.kubernetesVersion, "kubernetes.version", YAMLEditor.quote(kubernetesVersion)) }
        setList(\.k3sArgs, "kubernetes.k3sArgs")
        set(\.k3sListenPort, "kubernetes.port", "\(k3sListenPort)")
        set(\.activate, "autoActivate", "\(activate)")

        set(\.vmType, "vmType", vmType)
        set(\.rosetta, "rosetta", "\(rosetta)")
        set(\.binfmt, "binfmt", "\(binfmt)")
        set(\.nestedVirtualization, "nestedVirtualization", "\(nestedVirtualization)")
        set(\.hostname, "hostname", YAMLEditor.quote(hostname))

        if changed(\.mounts) {
            editor.setObjects("mounts", mounts.filter { !$0.path.isEmpty }.map {
                [("location", YAMLEditor.quote($0.path)), ("writable", "\($0.writable)")]
            })
        }
        set(\.mountType, "mountType", mountType)
        set(\.mountInotify, "mountInotify", "\(mountInotify)")

        set(\.networkAddress, "network.address", "\(networkAddress)")
        set(\.networkMode, "network.mode", networkMode)
        set(\.networkInterface, "network.interface", YAMLEditor.quote(networkInterface))
        set(\.networkPreferredRoute, "network.preferredRoute", "\(networkPreferredRoute)")
        set(\.networkHostAddresses, "network.hostAddresses", "\(networkHostAddresses)")
        if !gatewayAddress.isEmpty { set(\.gatewayAddress, "network.gatewayAddress", YAMLEditor.quote(gatewayAddress)) }
        setList(\.dns, "network.dns")
        setMap(\.dnsHosts, "network.dnsHosts")
        set(\.portForwarder, "portForwarder", portForwarder)

        set(\.sshAgent, "forwardAgent", "\(sshAgent)")
        set(\.sshConfig, "sshConfig", "\(sshConfig)")
        set(\.sshPort, "sshPort", "\(sshPort)")

        setMap(\.env, "env")
        return editor.text
    }
}

/// Changes values in a YAML file in place, line by line, so comments and unknown settings survive.
/// Paths are dotted, one or two levels deep, like `network.dns`.
struct YAMLEditor {
    private var lines: [String]

    init(_ text: String) {
        lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
    }

    var text: String {
        var result = lines.joined(separator: "\n")
        if !result.hasSuffix("\n") { result += "\n" }
        return result
    }

    mutating func set(_ path: String, _ value: String) {
        replace(path, firstLine: value, children: [])
    }

    mutating func setList(_ path: String, _ items: [String]) {
        replace(path, firstLine: items.isEmpty ? "[]" : "", children: items.map { "- \($0)" })
    }

    mutating func setMap(_ path: String, _ pairs: [(String, String)]) {
        replace(path, firstLine: pairs.isEmpty ? "{}" : "", children: pairs.map { "\($0.0): \($0.1)" })
    }

    mutating func setObjects(_ path: String, _ objects: [[(String, String)]]) {
        let children = objects.flatMap { fields in
            fields.enumerated().map { index, field in (index == 0 ? "- " : "  ") + "\(field.0): \(field.1)" }
        }
        replace(path, firstLine: objects.isEmpty ? "[]" : "", children: children)
    }

    /// Quotes a string value when YAML would otherwise misread it.
    static func quote(_ value: String) -> String {
        let special = CharacterSet(charactersIn: ":#{}[],&*!|>'\"%@`")
        let needsQuotes = value.isEmpty
            || value.rangeOfCharacter(from: special) != nil
            || value != value.trimmingCharacters(in: .whitespaces)
            || ["true", "false", "null", "yes", "no", "~"].contains(value.lowercased())
            || value.hasPrefix("-") && value.count == 1
            || Double(value) != nil
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Internals

    private static func indent(of line: String) -> Int { line.prefix { $0 == " " }.count }

    private static func isContent(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.hasPrefix("#")
    }

    private static func key(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("-"), let colon = trimmed.range(of: ":"),
              colon.upperBound == trimmed.endIndex || trimmed[colon.upperBound] == " " else { return nil }
        var key = String(trimmed[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
        if key.count >= 2, let first = key.first, first == key.last, first == "\"" || first == "'" {
            key = String(key.dropFirst().dropLast())
        }
        return key
    }

    /// Finds a key's line within `range`, at the shallowest indent present there.
    private func find(_ key: String, in range: Range<Int>) -> Int? {
        let indents = range.filter { Self.isContent(lines[$0]) }.map { Self.indent(of: lines[$0]) }
        guard let level = indents.min() else { return nil }
        return range.first { Self.isContent(lines[$0]) && Self.indent(of: lines[$0]) == level && Self.key(of: lines[$0]) == key }
    }

    /// The lines after a key that belong to it: deeper lines, and list items at the same indent.
    /// Trailing comments are left alone, because Colima's files put a key's comments above it.
    private func blockEnd(after line: Int) -> Int {
        let level = Self.indent(of: lines[line])
        var end = line + 1
        var index = line + 1
        while index < lines.count {
            let current = lines[index]
            if Self.isContent(current) {
                let indent = Self.indent(of: current)
                let isListItem = current.trimmingCharacters(in: .whitespaces).hasPrefix("-")
                guard indent > level || (indent == level && isListItem) else { break }
                end = index + 1
            }
            index += 1
        }
        return end
    }

    private mutating func replace(_ path: String, firstLine value: String, children: [String]) {
        let parts = path.split(separator: ".").map(String.init)
        var range = 0..<lines.count
        var indent = 0

        for (depth, part) in parts.enumerated() {
            let isLast = depth == parts.count - 1
            if let line = find(part, in: range) {
                indent = Self.indent(of: lines[line])
                if isLast {
                    let end = blockEnd(after: line)
                    let prefix = String(repeating: " ", count: indent)
                    let newLines = ["\(prefix)\(part):" + (value.isEmpty ? "" : " \(value)")]
                        + children.map { "\(prefix)  \($0)" }
                    lines.replaceSubrange(line..<end, with: newLines)
                    return
                }
                // Turn an inline empty parent like `network: {}` into a block.
                if Self.key(of: lines[line]) == part, let colon = lines[line].range(of: ":") {
                    let rest = lines[line][colon.upperBound...].trimmingCharacters(in: .whitespaces)
                    if !rest.isEmpty && !rest.hasPrefix("#") {
                        lines[line] = String(lines[line][..<colon.upperBound])
                    }
                }
                range = (line + 1)..<blockEnd(after: line)
                indent += 2
            } else {
                // Add whatever is missing at the end of the parent block.
                var newLines: [String] = []
                var level = indent
                for missing in parts[depth...].dropLast() {
                    newLines.append(String(repeating: " ", count: level) + "\(missing):")
                    level += 2
                }
                let pad = String(repeating: " ", count: level)
                newLines.append("\(pad)\(parts.last!):" + (value.isEmpty ? "" : " \(value)"))
                newLines += children.map { "\(pad)  \($0)" }
                let insertAt = depth == 0 ? lines.count : range.upperBound
                lines.insert(contentsOf: newLines, at: insertAt)
                return
            }
        }
    }
}

// MARK: - Reading colima.yaml

extension MachineConfig {
    /// Builds a config from a machine's `colima.yaml`, falling back to defaults for anything missing.
    init(name: String, yaml text: String) {
        self.init()
        self.name = name
        let yaml = SimpleYAML(text)

        func int(_ key: String) -> Int? { yaml.scalars[key].flatMap { Int($0) ?? Double($0).map(Int.init) } }
        func bool(_ key: String) -> Bool? { yaml.scalars[key].map { $0 == "true" } }
        func string(_ key: String) -> String? { yaml.scalars[key] }

        cpus = int("cpu") ?? cpus
        memoryGiB = string("memory").flatMap(Double.init) ?? memoryGiB
        diskGiB = int("disk") ?? diskGiB
        rootDiskGiB = int("rootDisk") ?? rootDiskGiB
        arch = string("arch").map { $0 == "host" ? Self.hostArch : $0 } ?? arch
        cpuType = string("cpuType") ?? ""
        diskImage = string("diskImage") ?? ""

        runtime = string("runtime") ?? runtime
        kubernetes = bool("kubernetes.enabled") ?? false
        kubernetesVersion = string("kubernetes.version") ?? ""
        k3sArgs = yaml.lists["kubernetes.k3sArgs"] ?? (yaml.emptyKeys.contains("kubernetes.k3sArgs") ? [] : k3sArgs)
        k3sListenPort = int("kubernetes.port") ?? 0
        activate = bool("autoActivate") ?? true

        vmType = string("vmType") ?? vmType
        rosetta = bool("rosetta") ?? false
        binfmt = bool("binfmt") ?? true
        nestedVirtualization = bool("nestedVirtualization") ?? false
        hostname = string("hostname") ?? ""

        mounts = (yaml.objects["mounts"] ?? []).compactMap { item in
            guard let location = item["location"] else { return nil }
            return Mount(path: location, writable: item["writable"] == "true")
        }
        mountType = string("mountType") ?? mountType
        mountInotify = bool("mountInotify") ?? true

        networkAddress = bool("network.address") ?? false
        networkMode = string("network.mode") ?? networkMode
        networkInterface = string("network.interface") ?? networkInterface
        networkPreferredRoute = bool("network.preferredRoute") ?? false
        networkHostAddresses = bool("network.hostAddresses") ?? false
        gatewayAddress = string("network.gatewayAddress") ?? ""
        dns = yaml.lists["network.dns"] ?? []
        dnsHosts = yaml.entries(under: "network.dnsHosts").map { "\($0.key)=\($0.value)" }
        portForwarder = string("portForwarder") ?? portForwarder

        sshAgent = bool("forwardAgent") ?? false
        sshConfig = bool("sshConfig") ?? true
        sshPort = int("sshPort") ?? 0

        env = yaml.entries(under: "env").map { "\($0.key)=\($0.value)" }
    }
}

/// A deliberately small YAML reader for Colima's settings files: nested maps, scalar values,
/// lists of scalars, and lists of flat maps. Comments are skipped.
struct SimpleYAML {
    private(set) var scalars: [String: String] = [:]   // "network.mode": "shared"
    private(set) var lists: [String: [String]] = [:]   // "network.dns": ["1.1.1.1"]
    private(set) var objects: [String: [[String: String]]] = [:] // "mounts": [["location": "~", "writable": "true"]]
    private(set) var emptyKeys: Set<String> = []                 // keys set to [], {} or null
    private var children: [String: [(key: String, value: String)]] = [:] // map entries, by parent path

    init(_ text: String) {
        var stack: [(indent: Int, path: String)] = []
        var objectParent: (indent: Int, path: String)?

        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = rawLine.prefix { $0 == " " }.count

            if trimmed.hasPrefix("- ") || trimmed == "-" {
                while let last = stack.last, last.indent > indent { stack.removeLast() }
                guard let parent = stack.last?.path else { continue }
                let item = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if let (key, value) = Self.keyValue(item) {
                    objects[parent, default: []].append([key: value])
                    objectParent = (indent + 2, parent)
                } else {
                    lists[parent, default: []].append(Self.unquote(item))
                    objectParent = nil
                }
                continue
            }

            guard let (key, value) = Self.keyValue(trimmed) else { continue }

            // A continuation line of a "- key: value" list item.
            if let object = objectParent, indent == object.indent, var items = objects[object.path], !items.isEmpty {
                items[items.count - 1][key] = value
                objects[object.path] = items
                continue
            }
            objectParent = nil

            while let last = stack.last, last.indent >= indent { stack.removeLast() }
            let path = stack.last.map { "\($0.path).\(key)" } ?? key
            if value.isEmpty {
                stack.append((indent, path))
            } else if ["{}", "[]", "null", "~"].contains(value) {
                emptyKeys.insert(path)
            } else {
                scalars[path] = value
                children[stack.last?.path ?? "", default: []].append((key, value))
            }
        }
    }

    /// Direct children of a map, e.g. the variables under `env`.
    /// Keys may contain dots (like `example.test` under `dnsHosts`), so these are kept separately.
    func entries(under path: String) -> [(key: String, value: String)] {
        children[path] ?? []
    }

    private static func keyValue(_ text: String) -> (String, String)? {
        guard let colon = text.range(of: ":"),
              colon.upperBound == text.endIndex || text[colon.upperBound] == " " else { return nil }
        let key = unquote(String(text[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces))
        let value = unquote(String(text[colon.upperBound...]).trimmingCharacters(in: .whitespaces))
        return key.isEmpty ? nil : (key, value)
    }

    private static func unquote(_ text: String) -> String {
        if text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" {
            return String(text.dropFirst().dropLast())
        }
        return text
    }
}
