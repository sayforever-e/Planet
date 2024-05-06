import Foundation
import os


class IPFSState: ObservableObject {
    static let shared = IPFSState()

    static let refreshRate: TimeInterval = 30

    @Published private(set) var isOperating = false
    @Published private(set) var online = false
    @Published private(set) var peers: UInt16 = 0
    @Published private(set) var apiPort: UInt16 = 5981
    @Published private(set) var gatewayPort: UInt16 = 18181
    @Published private(set) var swarmPort: UInt16 = 4001

    init() {
        debugPrint("IPFS State Manager Init")
        Task(priority: .userInitiated) {
            do {
                await IPFSDaemon.shared.setupIPFS()
                try await IPFSDaemon.shared.launch()
            } catch {
                debugPrint("Failed to launch: \(error.localizedDescription), will try again shortly.")
            }
        }
        RunLoop.main.add(Timer(timeInterval: Self.refreshRate, repeats: true) { _ in
            Task.detached(priority: .utility) {
                await self.updateStatus()
            }
        }, forMode: .common)
    }

    // MARK: -

    @MainActor
    func updateOperatingStatus(_ flag: Bool) {
        self.isOperating = flag
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

    func getGateway() -> String {
        return "http://127.0.0.1:\(gatewayPort)"
    }

    // MARK: -

    func updateStatus() async {
        // verify webui online status
        let url = URL(string: "http://127.0.0.1:\(self.apiPort)/webui")!
        let request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 1
        )
        let onlineStatus: Bool
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
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

        // update current peers
        if onlineStatus {
            await PlanetStore.shared.updateServerInfo()
            do {
                let data = try await IPFSDaemon.shared.api(path: "swarm/peers")
                let decoder = JSONDecoder()
                let swarmPeers = try decoder.decode(IPFSPeers.self, from: data)
                await MainActor.run {
                    self.peers = UInt16(swarmPeers.peers?.count ?? 0)
                }
            }
            catch {
                await MainActor.run {
                    self.peers = 0
                }
            }
        } else {
            await MainActor.run {
                self.peers = 0
            }
        }

        await MainActor.run {
            self.online = onlineStatus
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
}
