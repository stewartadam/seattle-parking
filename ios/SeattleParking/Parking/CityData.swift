import Foundation

// Where the parking data comes from: a copy of the whole city's data kept on
// the phone (about 46,000 block sides), refreshed weekly, so answers work
// offline. Questions are only ever answered from this copy: your location
// never leaves the phone. Without a copy, a question waits for the download.

/// [[[lon, lat], ...], ...] -> [[lon, lat, lon, lat, ...], ...]
private func flatten(_ paths: [[[Double]]]) -> [[Double]] {
    paths.map { $0.flatMap { $0.count >= 2 ? [$0[0], $0[1]] : [] } }
}

extension RPZZone {
    init(_ a: GISAttributes) {
        self.init(zone: a.text("RPZ_ZONE"), name: a.text("NAME"),
                  inEffect: a.text("INEFFECT").map(collapseWhitespace))
    }
}

private func collapseWhitespace(_ s: String) -> String {
    s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

// MARK: - Offline: the whole city on the phone

/// The downloaded data, as saved on disk.
struct CitySnapshot: Codable, Sendable {
    struct Block: Codable, Sendable {
        let rules: BlockfaceRules
        let paths: [[Double]]

        private enum CodingKeys: String, CodingKey { case rules = "r", paths = "p" }
    }

    struct Zone: Codable, Sendable {
        let info: RPZZone
        /// The zone's raw INEFFECT text, for schedules.
        let hours: String?
        let rings: [[Double]]
    }

    static let formatVersion = 1
    var version = formatVersion
    let downloadedAt: Date
    let blocks: [Block]
    let zones: [Zone]
}

/// A snapshot with a spatial index, ready to answer questions.
final class OfflineCity: ParkingDataSource, @unchecked Sendable {
    // Immutable after init, so safe to share across threads.
    let snapshot: CitySnapshot
    private let grid: [Int64: [Int32]]
    private let bounds: [(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)]
    private let hours: [String: String]

    /// Grid cells of about 220 m.
    private static let cellLat = 0.002
    private static let cellLon = 0.003

    private static func cell(_ lat: Double, _ lon: Double) -> (Int, Int) {
        (Int((lat / cellLat).rounded(.down)), Int((lon / cellLon).rounded(.down)))
    }

    private static func key(_ i: Int, _ j: Int) -> Int64 { Int64(i) << 32 | Int64(UInt32(bitPattern: Int32(j))) }

    init(_ snapshot: CitySnapshot) {
        self.snapshot = snapshot
        var grid: [Int64: [Int32]] = [:]
        var bounds: [(Double, Double, Double, Double)] = []
        bounds.reserveCapacity(snapshot.blocks.count)
        for (n, block) in snapshot.blocks.enumerated() {
            var b = (Double.infinity, Double.infinity, -Double.infinity, -Double.infinity)
            for path in block.paths {
                for k in stride(from: 0, to: path.count - 1, by: 2) {
                    b = (min(b.0, path[k + 1]), min(b.1, path[k]), max(b.2, path[k + 1]), max(b.3, path[k]))
                }
            }
            bounds.append(b)
            guard b.0.isFinite else { continue }
            let lo = Self.cell(b.0, b.1)
            let hi = Self.cell(b.2, b.3)
            for i in lo.0...hi.0 { for j in lo.1...hi.1 { grid[Self.key(i, j), default: []].append(Int32(n)) } }
        }
        self.grid = grid
        self.bounds = bounds
        var hours: [String: String] = [:]
        for z in snapshot.zones { if let zone = z.info.zone, let h = z.hours { hours[zone] = h } }
        self.hours = hours
    }

    func blockfaces(near origin: Coordinate, radiusMeters: Double) async throws -> [NearbyBlockface] {
        let dLat = radiusMeters / Geo.metersPerDegLat
        let dLon = radiusMeters / (Geo.metersPerDegLonAtEquator * cos(origin.lat * .pi / 180))
        let lo = Self.cell(origin.lat - dLat, origin.lon - dLon)
        let hi = Self.cell(origin.lat + dLat, origin.lon + dLon)
        var candidates = Set<Int32>()
        for i in lo.0...hi.0 { for j in lo.1...hi.1 { candidates.formUnion(grid[Self.key(i, j)] ?? []) } }

        var found: [NearbyBlockface] = []
        for n in candidates {
            let b = bounds[Int(n)]
            // Cheap bounding-box reject before the exact distance.
            if b.0 > origin.lat + dLat || b.2 < origin.lat - dLat || b.1 > origin.lon + dLon || b.3 < origin.lon - dLon { continue }
            let block = snapshot.blocks[Int(n)]
            let (distance, point) = Geo.distance(from: origin, to: block.paths)
            guard let point, distance <= radiusMeters else { continue }
            found.append(NearbyBlockface(rules: block.rules, paths: block.paths, distance: distance, point: point))
        }
        return found.sorted { $0.distance < $1.distance }
    }

    func zone(at origin: Coordinate) async throws -> RPZZone? {
        snapshot.zones.first { Geo.contains(rings: $0.rings, lat: origin.lat, lon: origin.lon) }?.info
    }

    func rpzHours() async -> [String: String] { hours }
}

// MARK: - Download and refresh

extension CitySnapshot {
    /// Downloads every blockface and RPZ zone from the city, 2,000 at a time.
    static func download(_ client: CityGISClient = CityGISClient(),
                         progress: (@Sendable (Double) -> Void)? = nil) async throws -> CitySnapshot {
        let total = try await client.count(CityGIS.parkingCategories)
        let pageSize = 2000
        let offsets = Array(stride(from: 0, to: total, by: pageSize))
        var pages = [Int: [Block]]()
        // A few pages at a time: quick, without hammering the city's server.
        try await withThrowingTaskGroup(of: (Int, [Block]).self) { group in
            var next = 0
            func add() {
                guard next < offsets.count else { return }
                let offset = offsets[next]
                next += 1
                group.addTask {
                    let features = try await client.queryPage(CityGIS.parkingCategories, offset: offset, count: pageSize,
                                                              outFields: BlockfaceRules.fields)
                    let blocks = features.compactMap { f -> Block? in
                        guard let paths = f.geometry?.paths, !paths.isEmpty else { return nil }
                        return Block(rules: BlockfaceRules(f.attributes), paths: flatten(paths))
                    }
                    return (offset, blocks)
                }
            }
            for _ in 0..<4 { add() }
            while let (offset, blocks) = try await group.next() {
                pages[offset] = blocks
                progress?(Double(pages.count) / Double(offsets.count))
                add()
            }
        }
        let zones = try await client.queryPage(CityGIS.rpzZones, offset: 0, count: 2000,
                                               outFields: ["RPZ_ZONE", "NAME", "INEFFECT"])
        return CitySnapshot(
            downloadedAt: Date(),
            blocks: offsets.flatMap { pages[$0] ?? [] },
            zones: zones.map { z in
                Zone(info: RPZZone(z.attributes), hours: z.attributes.text("INEFFECT"),
                     rings: flatten(z.geometry?.rings ?? []))
            }
        )
    }
}

/// Owns the on-phone copy: loads it, downloads it, and refreshes it weekly.
actor CityData {
    static let shared = CityData()

    static let refreshInterval: TimeInterval = 7 * 24 * 3600

    enum State: Sendable, Equatable {
        case none
        case downloading(Double)
        case ready(Date)
        case failed(String, lastUpdate: Date?)
    }

    private var city: OfflineCity?
    private var loadedFromDisk = false
    private var downloadTask: Task<Void, Never>?
    private var lastAttempt: Date?
    private(set) var state: State = .none

    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "city-parking.json")
    }

    /// The phone's copy of the city data, for answering a question. Starts a
    /// background refresh when it's over a week old. With no copy yet, downloads
    /// it first, and throws if that fails.
    func readySource() async throws -> ParkingDataSource {
        loadIfNeeded()
        if let city {
            refreshIfStale()
            return city
        }
        refresh() // or join the download already under way
        await downloadTask?.value
        guard let city else { throw CityGISError.noCityData }
        return city
    }

    func currentState() -> State {
        loadIfNeeded()
        return state
    }

    func refreshIfStale() {
        loadIfNeeded()
        if let city, Date().timeIntervalSince(city.snapshot.downloadedAt) < Self.refreshInterval { return }
        // After a failure (say, no signal), wait an hour before trying again on our own.
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < 3600 { return }
        refresh()
    }

    /// Downloads a fresh copy in the background, unless one is already coming.
    func refresh() {
        guard downloadTask == nil else { return }
        lastAttempt = Date()
        state = .downloading(0)
        downloadTask = Task { await self.runDownload() }
    }

    /// Waits for a download that's under way.
    func waitForDownload() async { await downloadTask?.value }

    private func runDownload() async {
        defer { downloadTask = nil }
        do {
            let fileURL = fileURL
            let city = try await Task.detached(priority: .utility) {
                let snapshot = try await CitySnapshot.download { fraction in
                    Task { await self.setProgress(fraction) }
                }
                // Don't swap in a partial or failed download.
                guard snapshot.blocks.count > 1000 else { throw CityGISError.failed("incomplete download") }
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
                return OfflineCity(snapshot)
            }.value
            excludeFromBackup()
            self.city = city
            let snapshot = city.snapshot
            state = .ready(snapshot.downloadedAt)
        } catch {
            state = .failed(error.localizedDescription, lastUpdate: city?.snapshot.downloadedAt)
        }
    }

    private func setProgress(_ fraction: Double) {
        if case .downloading = state { state = .downloading(fraction) }
    }

    private func loadIfNeeded() {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(CitySnapshot.self, from: data),
              snapshot.version == CitySnapshot.formatVersion else { return }
        city = OfflineCity(snapshot)
        state = .ready(snapshot.downloadedAt)
    }

    private func excludeFromBackup() {
        #if os(iOS)
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        #endif
    }
}
