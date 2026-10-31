import Foundation

/// A Colima profile (one Linux VM).
struct Machine: Identifiable, Hashable, Decodable {
    var name: String
    var status: String
    var arch: String
    var cpus: Int
    var memory: Int64
    var disk: Int64
    var runtime: String
    var address: String

    var id: String { name }
    var isRunning: Bool { status.caseInsensitiveCompare("Running") == .orderedSame }
    var usesDocker: Bool { runtime.isEmpty || runtime.hasPrefix("docker") }
    var hasKubernetes: Bool { runtime.contains("k3s") || runtime.contains("kubernetes") }

    static var colimaHome: URL {
        ProcessInfo.processInfo.environment["COLIMA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".colima")
    }

    var directory: URL { Self.colimaHome.appendingPathComponent(name) }

    var dockerSocket: String { directory.appendingPathComponent("docker.sock").path }
    var configFile: URL { directory.appendingPathComponent("colima.yaml") }

    enum CodingKeys: String, CodingKey {
        case name, status, arch, cpus, memory, disk, runtime, address
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "Unknown"
        arch = try c.decodeIfPresent(String.self, forKey: .arch) ?? ""
        cpus = try c.decodeIfPresent(Int.self, forKey: .cpus) ?? 0
        memory = try c.decodeIfPresent(Int64.self, forKey: .memory) ?? 0
        disk = try c.decodeIfPresent(Int64.self, forKey: .disk) ?? 0
        runtime = try c.decodeIfPresent(String.self, forKey: .runtime) ?? ""
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
    }
}

struct Container: Identifiable, Hashable, Decodable {
    var id: String
    var name: String
    var image: String
    var state: String
    var status: String
    var ports: String
    var labels: String
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id = "ID", name = "Names", image = "Image", state = "State"
        case status = "Status", ports = "Ports", labels = "Labels", createdAt = "CreatedAt"
    }

    var isRunning: Bool { state == "running" }
    var isPaused: Bool { state == "paused" }

    var composeProject: String? { label("com.docker.compose.project") }
    var composeService: String? { label("com.docker.compose.service") }

    private func label(_ key: String) -> String? {
        labels.split(separator: ",")
            .first { $0.hasPrefix(key + "=") }
            .map { String($0.dropFirst(key.count + 1)) }
    }

    /// Host ports published on localhost, e.g. "0.0.0.0:8080->80/tcp" → 8080.
    var publishedPorts: [Int] {
        var result: [Int] = []
        for mapping in ports.split(separator: ",") {
            guard let arrow = mapping.range(of: "->") else { continue }
            let host = mapping[..<arrow.lowerBound]
            if let colon = host.lastIndex(of: ":"), let port = Int(host[host.index(after: colon)...]),
               !result.contains(port) {
                result.append(port)
            }
        }
        return result
    }
}

struct ContainerStats: Decodable {
    var id: String
    var cpu: String
    var memUsage: String
    var memPercent: String

    enum CodingKeys: String, CodingKey {
        case id = "ID", cpu = "CPUPerc", memUsage = "MemUsage", memPercent = "MemPerc"
    }

    var cpuValue: Double { Double(cpu.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) ?? 0 }
    var memValue: Double { Double(memPercent.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) ?? 0 }
    var memUsed: String { memUsage.components(separatedBy: " / ").first ?? memUsage }
}

struct DockerImage: Identifiable, Hashable, Decodable {
    var id: String
    var repository: String
    var tag: String
    var size: String
    var createdSince: String

    enum CodingKeys: String, CodingKey {
        case id = "ID", repository = "Repository", tag = "Tag", size = "Size", createdSince = "CreatedSince"
    }

    var reference: String {
        repository == "<none>" ? id : "\(repository):\(tag)"
    }
}

struct DockerVolume: Identifiable, Hashable, Decodable {
    var name: String
    var driver: String
    var mountpoint: String

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name = "Name", driver = "Driver", mountpoint = "Mountpoint"
    }
}

struct ActivityEntry: Identifiable {
    enum State { case running, succeeded, failed }

    let id = UUID()
    let title: String
    let command: String
    let started = Date()
    var output = ""
    var state = State.running
}

/// Decodes newline-delimited JSON, skipping lines that don't parse.
func decodeLines<T: Decodable>(_ type: T.Type, from text: String) -> [T] {
    let decoder = JSONDecoder()
    return text.split(whereSeparator: \.isNewline).compactMap { line in
        try? decoder.decode(T.self, from: Data(line.utf8))
    }
}

extension Int64 {
    var gib: String {
        let value = Double(self) / 1_073_741_824
        return value.rounded() == value ? "\(Int(value)) GiB" : String(format: "%.1f GiB", value)
    }
}
