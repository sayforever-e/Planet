import Foundation


class IPFSState: ObservableObject {
    static let shared = IPFSState()

    static let lastUserLaunchState: String = "PlanetIPFSLastUserLaunchStateKey"

    /// A string to be displayed when IPFS daemon is unable to start.
    @Published var reasonIPFSNotRunning: String? = nil

    @Published var isShowingStatus = false
    @Published var isShowingStatusWindow = false

    @Published private(set) var isOperating = false
    @Published private(set) var online = false
    @Published private(set) var apiPort: UInt16 = 5981
    @Published private(set) var gatewayPort: UInt16 = 18181
    @Published private(set) var swarmPort: UInt16 = 4001
    @Published private(set) var isCalculatingRepoSize: Bool = false
    @Published private(set) var repoSize: Int64?
    @Published private(set) var serverInfo: ServerInfo?
    @Published private(set) var bandwidths: [Int: IPFSBandwidth] = [:]

    init() {
        debugPrint("IPFS State Manager Init")
        Task(priority: .userInitiated) {
            do {
                await IPFSDaemon.shared.setupIPFS()
                try await Task.sleep(nanoseconds: 500_000_000)
                if self.shouldAutoLaunchDaemon() {
                    try await IPFSDaemon.shared.launch()
                }
            } catch {
                debugPrint("Failed to launch: \(error.localizedDescription), will try again shortly.")
            }
        }
    }

    // MARK: -

    static let formatter = {
        let byteCountFormatter = ByteCountFormatter()
        byteCountFormatter.allowedUnits = .useAll
        byteCountFormatter.countStyle = .decimal
        return byteCountFormatter
    }()

    // MARK: -

    @MainActor
    func updateOperatingStatus(_ flag: Bool) {
        self.isOperating = flag
    }

    @MainActor
    func updateOnlineStatus(_ flag: Bool) {
        self.online = flag
        guard flag else { return }
        Task.detached(priority: .utility) {
            await self.updateServerInfo()
        }
    }

    @MainActor
    func updateAPIPort(_ port: UInt16) {
        self.apiPort = port
    }

    @MainActor
    func updateSwarmPort(_ port: UInt16) {
        self.swarmPort = port
    }

    @MainActor
    func updateGatewayPort(_ port: UInt16) {
        self.gatewayPort = port
    }

    @MainActor
    func updateServerInfo(_ info: ServerInfo) {
        self.serverInfo = info
        debugPrint("Updated ServerInfo: \(info)")
    }

    @MainActor
    func updateBandwidths(data: IPFSBandwidth) {
        let now = Int(Date().timeIntervalSince1970)
        bandwidths[now] = data
        if bandwidths.count > 120 {
            bandwidths = bandwidths.suffix(120).reduce(into: [:]) { $0[$1.key] = $1.value }
        }
    }

    func getGateway() -> String {
        return "http://127.0.0.1:\(gatewayPort)"
    }

    // MARK: -

    func updateStatus() async {
        // verify webui online status
        let url = URL(string: "http://127.0.0.1:\(self.apiPort)/api/v0/id")!
        let session = URLSession(configuration: {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 5
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            return config
        }())
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.networkServiceType = .responsiveData
        let onlineStatus: Bool
        do {
            let (_, response) = try await session.data(for: request)
            if let res = response as? HTTPURLResponse, res.statusCode == 200 {
                onlineStatus = true
            }
            else {
                onlineStatus = false
            }
        }
        catch {
            onlineStatus = false
        }
        await MainActor.run {
            self.online = onlineStatus
        }
        // update current peers
        if onlineStatus {
            await self.updateServerInfo()
        } else {
            // Wait for 2 seconds and try again
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await self.updateStatus()
        }
    }

    func updateAppSettings() {
        // refresh published folders
        Task.detached(priority: .utility) { @MainActor in
            PlanetPublishedServiceStore.shared.reloadPublishedFolders()
        }
        // process unpublished folders
        Task.detached(priority: .utility) {
            NotificationCenter.default.post(
                name: .dashboardProcessUnpublishedFolders,
                object: nil
            )
        }
        // update webview rule list.
        Task.detached(priority: .utility) {
            NotificationCenter.default.post(
                name: .updateRuleList,
                object: NSNumber(value: self.apiPort)
            )
        }
        // refresh key manager
        Task.detached(priority: .utility) { @MainActor in
            NotificationCenter.default.post(name: .keyManagerReloadUI, object: nil)
        }
    }

    func updateTrafficStatus() async {
        guard online else { return }
        guard let stats = try? await IPFSDaemon.shared.getStatsBW() else { return }
        await MainActor.run {
            updateBandwidths(data: stats)
        }
    }

    func calculateRepoSize() async throws {
        guard !isCalculatingRepoSize else { return }
        await MainActor.run {
            self.isCalculatingRepoSize = true
        }
        defer {
            Task { @MainActor in
                self.isCalculatingRepoSize = false
            }
        }
        let repoPath = IPFSCommand.IPFSRepositoryPath
        guard FileManager.default.fileExists(atPath: repoPath.path) else { throw PlanetError.DirectoryNotExistsError }
        let data = try await IPFSDaemon.shared.api(path: "repo/stat")
        let decoder = JSONDecoder()
        let repoState: IPFSRepoState = try decoder.decode(IPFSRepoState.self, from: data)
        let path = URL(fileURLWithPath: repoState.repoPath)
        guard path == repoPath else { throw PlanetError.IPFSAPIError }
        await MainActor.run {
            self.repoSize = repoState.repoSize
        }
    }

    // MARK: -

    private func shouldAutoLaunchDaemon() -> Bool {
        if UserDefaults.standard.value(forKey: Self.lastUserLaunchState) != nil, !UserDefaults.standard.bool(forKey: Self.lastUserLaunchState) {
            return false
        }
        return true
    }

    private func updateServerInfo() async {
        var hostName: String = ""
        if let host = Host.current().localizedName {
            hostName = host
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        var ipfsPeerID = ""
        do {
            let data = try await IPFSDaemon.shared.api(path: "id")
            let decoder = JSONDecoder()
            let idInfo = try decoder.decode(IPFSID.self, from: data)
            ipfsPeerID = idInfo.id
        } catch {
            ipfsPeerID = ""
        }
        var ipfsVersion = ""
        do {
            let data = try await IPFSDaemon.shared.api(path: "version")
            let decoder = JSONDecoder()
            let versionInfo = try decoder.decode(IPFSVersion.self, from: data)
            ipfsVersion = versionInfo.version
        } catch {
            ipfsVersion = ""
        }
        var peers = 0
        do {
            let data = try await IPFSDaemon.shared.api(path: "swarm/peers")
            let decoder = JSONDecoder()
            let swarmPeers = try decoder.decode(IPFSPeers.self, from: data)
            peers = swarmPeers.peers?.count ?? 0
        } catch {
            peers = 0
        }
        let info = ServerInfo(hostName: hostName, version: version, ipfsPeerID: ipfsPeerID, ipfsVersion: ipfsVersion, ipfsPeerCount: peers)
        Task { @MainActor in
            self.updateServerInfo(info)
        }
    }
}
