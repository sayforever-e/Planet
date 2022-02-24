//
//  PlanetManager.swift
//  Planet
//
//  Created by Kai on 2/15/22.
//

import Foundation
import Cocoa
import Stencil
import PathKit


class PlanetManager: NSObject {
    static let shared: PlanetManager = PlanetManager()
    
    private var publishTimer: Timer?
    private var feedTimer: Timer?

    private var unitTesting: Bool = {
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }()
    
    private var commandQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        return q
    }()

    private var commandDaemonQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .background
        return q
    }()
    
    private var apiPort: String = "" {
        didSet {
            guard apiPort != "" else { return }
            debugPrint("api port updated.")
            commandQueue.addOperation {
                do {
                    // update api and gateway ports.
                    let result = try runCommand(command: .ipfsUpdateAPIPort(target: self._ipfsPath(), config: self._configPath(), port: self.apiPort))
                    debugPrint("update api port command result: \(result)")
                    
                    // restart daemon
                    self.relaunchDaemonIfNeeded()
                } catch {
                    debugPrint("failed to setup daemon: \(error)")
                }
            }
        }
    }
    
    private var gatewayPort: String = "" {
        didSet {
            guard gatewayPort != "" else { return }
            debugPrint("gateway port updated.")
            self.commandQueue.addOperation {
                do {
                    // update api and gateway ports.
                    let result = try runCommand(command: .ipfsUpdateGatewayPort(target: self._ipfsPath(), config: self._configPath(), port: self.gatewayPort))
                    debugPrint("update gateway port command result: \(result)")
                    
                    // restart daemon
                    self.relaunchDaemonIfNeeded()
                } catch {
                    debugPrint("failed to setup daemon: \(error)")
                }
            }
        }
    }

    func setup() {
        debugPrint("Planet Manager Setup")
//        #if DEBUG
//        PlanetDataController.shared.resetDatabase()
//        #endif
        
        loadTemplates()
        
        verifyIPFSStatus { ready in
            guard ready else {
                debugPrint("IPFS setup not ready, do something.")
                return
            }
            self.updateAPIAndGatewayPorts()
        }
        
        publishTimer = Timer.scheduledTimer(timeInterval: 600, target: self, selector: #selector(publishLocalPlanets), userInfo: nil, repeats: true)
        feedTimer = Timer.scheduledTimer(timeInterval: 300, target: self, selector: #selector(updateFollowingPlanets), userInfo: nil, repeats: true)
    }
    
    func cleanup() {
        debugPrint("Planet Manager Cleanup")
        terminateDaemon(forceSkip: true)
        publishTimer?.invalidate()
        feedTimer?.invalidate()
    }
    
    func relaunchDaemon() {
        relaunchDaemonIfNeeded()
    }
    
    // MARK: - General -
    func loadTemplates() {
        let templatePath = _templatesPath()
        if let tonPath = Bundle.main.url(forResource: "TemplateTON", withExtension: "html") {
            let targetPath = templatePath.appendingPathComponent("ton.html")
            do {
                if FileManager.default.fileExists(atPath: targetPath.path) {
                    try? FileManager.default.removeItem(at: targetPath)
                }
                try FileManager.default.copyItem(at: tonPath, to: targetPath)
            } catch {
                debugPrint("failed to copy template file: \(error)")
            }
            DispatchQueue.main.async {
                PlanetStore.shared.templatePaths.append(targetPath)
            }
        }
    }

    func checkDaemonStatus(on: @escaping (Bool) -> Void) {
        guard apiPort != "" else {
            return on(false)
        }
        verifyPortAvailability(port: apiPort, suffix: "/webui/") { status in
            DispatchQueue.main.async {
                PlanetStore.shared.daemonIsOnline = status
            }
            on(status)
        }
    }
    
    func checkPeersStatus(on: @escaping (Int) -> Void) {
        let request = serverURL(path: "swarm/peers")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if error == nil, let data = data {
                let decoder = JSONDecoder()
                do {
                    let peers = try decoder.decode(PlanetPeers.self, from: data)
                    DispatchQueue.main.async {
                        PlanetStore.shared.peersCount = peers.peers?.count ?? 0
                    }
                } catch {
                    debugPrint("failed to decode planet peers: \(error)")
                }
            }
        }.resume()
    }
    
    func checkPublishingStatus(planetID id: UUID) async -> Bool {
        return await PlanetStore.shared.publishingPlanets.contains(id)
    }
    
    func checkUpdatingStatus(planetID id: UUID) async -> Bool {
        return await PlanetStore.shared.updatingPlanets.contains(id)
    }
    
    func generateKeys() async -> (keyName: String?, keyID: String?) {
        let uuid = UUID()
        let checkKeyExistsRequest = serverURL(path: "key/list")
        do {
            let (data, _) = try await URLSession.shared.data(for: checkKeyExistsRequest)
            do {
                let decoder = JSONDecoder()
                let availableKeys = try decoder.decode(PlanetKeys.self, from: data)
                var keyID: String = ""
                var keyName: String = ""
                var keyExists: Bool = false
                if let keys = availableKeys.keys {
                    for k in keys {
                        if k.name == uuid.uuidString {
                            keyID = k.id ?? ""
                            keyName = k.name ?? ""
                            keyExists = true
                            break
                        }
                    }
                }
                if keyExists {
                    return (keyName, keyID)
                } else {
                    let generateKeyRequest = serverURL(path: "key/gen", args: ["arg": uuid.uuidString])
                    do {
                        let (data, _) = try await URLSession.shared.data(for: generateKeyRequest)
                        let genKey = try decoder.decode(PlanetKey.self, from: data)
                        if let theKeyName = genKey.name, let theKeyID = genKey.id {
                            return (theKeyName, theKeyID)
                        } else {
                            debugPrint("failed to generate key, empty result.")
                        }
                    } catch {
                        debugPrint("failed to generate key: \(error)")
                    }
                }
            } catch {
                debugPrint("failed to check key: \(error)")
            }
        } catch {
            debugPrint("failed to create planet.")
        }
        return (nil, nil)
    }
    
    func ipfsENVPath() -> URL {
        let envPath = _ipfsENVPath()
        if !FileManager.default.fileExists(atPath: envPath.path) {
            try? FileManager.default.createDirectory(at: envPath, withIntermediateDirectories: true, attributes: nil)
        }
        return envPath
    }
    
    func deleteKey(withName name: String) async {
        let checkKeyExistsRequest = serverURL(path: "key/rm", args: ["arg": name])
        do {
            let (_, _) = try await URLSession.shared.data(for: checkKeyExistsRequest)
        } catch {
            debugPrint("failed to remove key with name: \(name), error: \(error)")
        }
    }
    
    func resizedAvatarImage(image: NSImage) -> NSImage {
        let targetImage: NSImage
        let targetImageSize = CGSize(width: 144, height: 144)
        if min(image.size.width, image.size.height) > targetImageSize.width / 2.0 {
            targetImage = image.imageResize(targetImageSize) ?? image
        } else {
            targetImage = image
        }
        return targetImage
    }
    
    func updateAvatar(forPlanet planet: Planet, image: NSImage, isEditing: Bool = false) {
        guard let id = planet.id else { return }
        let imageURL = _avatarPath(forPlanetID: id, isEditing: isEditing)
        let targetImage = resizedAvatarImage(image: image)
        targetImage.imageSave(imageURL)
    }
    
    func removeAvatar(forPlanet planet: Planet) {
        guard let id = planet.id else { return }
        let imageURL = _avatarPath(forPlanetID: id, isEditing: false)
        let imageEditURL = _avatarPath(forPlanetID: id, isEditing: true)
        try? FileManager.default.removeItem(at: imageURL)
        try? FileManager.default.removeItem(at: imageEditURL)
    }
    
    func avatar(forPlanet planet: Planet) -> NSImage? {
        if let id = planet.id {
            let imageURL = _avatarPath(forPlanetID: id, isEditing: false)
            if FileManager.default.fileExists(atPath: imageURL.path) {
                return NSImage(contentsOf: imageURL)
            }
        }
        return nil
    }
    
    // MARK: - Planet & Planet Article -
    func setupDirectory(forPlanet planet: Planet) {
        if !planet.isMyPlanet() {
            Task.init(priority: .background) {
                await updateForPlanet(planet: planet)
            }
        } else {
            debugPrint("about setup directory for planet: \(planet) ...")
            let planetPath = _planetsPath().appendingPathComponent(planet.id!.uuidString)
            if !FileManager.default.fileExists(atPath: planetPath.path) {
                debugPrint("setup directory for planet: \(planet), path: \(planetPath)")
                do {
                    try FileManager.default.createDirectory(at: planetPath, withIntermediateDirectories: true, attributes: nil)
                } catch {
                    debugPrint("failed to create planet path at \(planetPath), error: \(error)")
                    return
                }
            }
        }
    }
    
    func destroyDirectory(fromPlanet planetUUID: UUID) {
        debugPrint("about to destroy directory from planet: \(planetUUID) ...")
        let planetPath = _planetsPath().appendingPathComponent(planetUUID.uuidString)
        do {
            try FileManager.default.removeItem(at: planetPath)
        } catch {
            debugPrint("failed to destroy planet path at: \(planetPath), error: \(error)")
        }
    }
    
    func destroyArticleDirectory(planetUUID: UUID, articleUUID: UUID) {
        debugPrint("about to destroy directory from article: \(articleUUID) ...")
        let articlePath = _planetsPath().appendingPathComponent(planetUUID.uuidString).appendingPathComponent(articleUUID.uuidString)
        do {
            try FileManager.default.removeItem(at: articlePath)
        } catch {
            debugPrint("failed to destroy article path at: \(articlePath), error: \(error)")
        }
    }
    
    func articleURL(article: PlanetArticle) async -> URL? {
        guard let articleID = article.id, let planetID = article.planetID else { return nil }
        guard let planet = PlanetDataController.shared.getPlanet(id: article.planetID!), let ipns = planet.ipns else { return nil }
        if planet.isMyPlanet() {
            return _planetsPath().appendingPathComponent(planetID.uuidString).appendingPathComponent(articleID.uuidString).appendingPathComponent("index.html")
        } else {
            let prefixString = "http://127.0.0.1" + ":" + gatewayPort + "/" + "ipns" + "/" + ipns
            let urlString: String = prefixString + "/" + articleID.uuidString + "/" + "index.html"
            if let url = URL(string: urlString) {
                let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
                do {
                    let (data, _) = try await URLSession.shared.data(for: request)
                    // cache index.html file if needed.
                    return url
                } catch {
                    debugPrint("failed to validate article url: \(url), error: \(error)")
                    return nil
                }
            }
            return nil
        }
    }
    
    func renderArticleToDirectory(fromArticle article: PlanetArticle, templateIndex: Int = 0, force: Bool = false) async {
        debugPrint("about to render article: \(article)")
        let planetPath = _planetsPath().appendingPathComponent(article.planetID!.uuidString)
        let articlePath = planetPath.appendingPathComponent(article.id!.uuidString)
        if !FileManager.default.fileExists(atPath: articlePath.path) {
            do {
                try FileManager.default.createDirectory(at: articlePath, withIntermediateDirectories: true, attributes: nil)
            } catch {
                debugPrint("failed to create article path: \(articlePath), error: \(error)")
                return
            }
        }
        let templatePath = await PlanetStore.shared.templatePaths[templateIndex]
        // render html
        let loader = FileSystemLoader(paths: [Path(templatePath.deletingLastPathComponent().path)])
        let environment = Environment(loader: loader)
        let context = ["article": article]
        let templateName = templatePath.lastPathComponent
        let articleIndexPagePath = articlePath.appendingPathComponent("index.html")
        do {
            let output: String = try environment.renderTemplate(name: templateName, context: context)
            try output.data(using: .utf8)?.write(to: articleIndexPagePath)
        } catch {
            debugPrint("failed to render article: \(error), at path: \(articleIndexPagePath)")
            return
        }
        // save article.json
        let articleJSONPath = articlePath.appendingPathComponent("article.json")
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(article)
            try data.write(to: articleJSONPath)
        } catch {
            debugPrint("failed to save article summary json: \(error), at: \(articleJSONPath)")
            return
        }
        debugPrint("article \(article) rendered at: \(articlePath).")
    }
    
    func publishForPlanet(planet: Planet) async {
        let now = Date()
        guard let id = planet.id, let keyName = planet.keyName, keyName != "" else { return }
        let planetPath = _planetsPath().appendingPathComponent(id.uuidString)
        guard FileManager.default.fileExists(atPath: planetPath.path) else { return }
        let publishingStatus = await checkPublishingStatus(planetID: id)
        guard publishingStatus == false else {
            debugPrint("planet \(planet) is still publishing, abort.")
            return
        }
        DispatchQueue.main.async {
            PlanetStore.shared.publishingPlanets.insert(id)
        }
        defer {
            DispatchQueue.main.async {
                PlanetStore.shared.publishingPlanets.remove(id)
                let published: Date = Date()
                PlanetStore.shared.lastPublishedDates[id] = published
                DispatchQueue.global(qos: .background).async {
                    UserDefaults.standard.set(published, forKey: "PlanetLastPublished" + "-" + id.uuidString)
                }
            }
        }
        debugPrint("publishing for planet: \(planet), with key name: \(keyName) ...")
        
        // update feed.json
        let feedPath = planetPath.appendingPathComponent("feed.json")
        if FileManager.default.fileExists(atPath: feedPath.path) {
            do {
                try FileManager.default.removeItem(at: feedPath)
            } catch {
                debugPrint("failed to remove previous feed item at \(feedPath), error: \(error)")
            }
        }
        let articles = PlanetDataController.shared.getArticles(byPlanetID: id)
        let feedArticles: [PlanetFeedArticle] = articles.map() { t in
            let feedArticle: PlanetFeedArticle = PlanetFeedArticle(id: t.id!, created: t.created!, title: t.title ?? "")
            return feedArticle
        }
        let feed = PlanetFeed(id: id, ipns: planet.ipns!, created: planet.created!, updated: now, name: planet.name ?? "", about: planet.about ?? "", articles: feedArticles)
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(feed)
            try data.write(to: feedPath)
        } catch {
            debugPrint("failed to encode feed: \(feed), at path: \(feedPath), error: \(error)")
            return
        }
        
        // add planet directory
        var planetCID: String?
        do {
            let result = try runCommand(command: .ipfsAddDirectory(target: _ipfsPath(), config: _configPath(), directory: planetPath))
            if let result = result["result"] as? [String], let cid: String = result.first {
                planetCID = cid
            }
        } catch {
            debugPrint("failed to add planet directory at: \(planetPath), error: \(error)")
        }
        if planetCID == nil {
            debugPrint("failed to add planet directory: empty cid.")
            return
        }

        // publish
        do {
            let decoder = JSONDecoder()
            let (data, _) = try await URLSession.shared.data(for: serverURL(path: "name/publish", args: [
                "arg": planetCID!,
                "allow-offline": "1",
                "key": keyName,
                "quieter": "1"
            ], timeout: 600))
            let published = try decoder.decode(PlanetPublished.self, from: data)
            if let planetIPNS = published.name {
                debugPrint("planet: \(planet) is published: \(planetIPNS)")
            } else {
                debugPrint("planet: \(planet) not published: \(published).")
            }
        } catch {
            debugPrint("failed to publish planet: \(planet), at path: \(planetPath), error: \(error)")
        }
    }
    
    func updateForPlanet(planet: Planet) async {
        guard let id = planet.id, let name = planet.name, let ipns = planet.ipns, ipns.count == "k51qzi5uqu5dioq5on1s4oc3wg2t13w03xxsq32b1qovi61b6oi8pcyep2gsyf".count else { return }
        
        // make sure you do not follow your own planet on the same Mac.
        guard !PlanetDataController.shared.getLocalIPNSs().contains(ipns) else {
            debugPrint("cannot follow your own planet on the same machine, abort.")
            PlanetDataController.shared.removePlanet(planet: planet)
            return
        }
        
        let updatingStatus = await checkUpdatingStatus(planetID: id)
        guard updatingStatus == false else {
            debugPrint("planet \(planet) is still been updating, abort.")
            return
        }
        DispatchQueue.main.async {
            PlanetStore.shared.updatingPlanets.insert(id)
        }
        defer {
            DispatchQueue.main.async {
                PlanetStore.shared.updatingPlanets.remove(id)
                let updated: Date = Date()
                PlanetStore.shared.lastUpdatedDates[id] = updated
                DispatchQueue.global(qos: .background).async {
                    UserDefaults.standard.set(updated, forKey: "PlanetLastUpdated" + "-" + id.uuidString)
                }
            }
        }
        
        // pin planet in background.
        debugPrint("pin in the background ...")
        let pinRequest = serverURL(path: "pin/add", args: ["arg": "/ipns/" + ipns], timeout: 120)
        URLSession.shared.dataTask(with: pinRequest) { data, response, error in
            debugPrint("pinned: \(response).")
        }.resume()

        debugPrint("updating for planet: \(planet) ...")
        let prefix = "http://127.0.0.1" + ":" + gatewayPort + "/" + "ipns" + "/" + ipns + "/"
        let ipnsString = prefix + "feed.json"
        let request = URLRequest(url: URL(string: ipnsString)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let decoder = JSONDecoder()
            let feed: PlanetFeed = try decoder.decode(PlanetFeed.self, from: data)
            guard feed.name != "" else { return }
            
            debugPrint("got following planet feed: \(feed)")
            
            // remove current planet as placeholder, create new planet with feed.id
            if name == "" {
                PlanetDataController.shared.removePlanet(planet: planet)
                PlanetDataController.shared.createPlanet(withID: feed.id, name: feed.name, about: feed.about, keyName: nil, keyID: nil, ipns: feed.ipns)
            }
            
            // update planet articles if needed.
            for a in feed.articles {
                if let _ = PlanetDataController.shared.getArticle(id: a.id) {
                } else {
                    await PlanetDataController.shared.createArticle(withID: a.id, forPlanet: feed.id, title: a.title, content: "")
                }
            }
            
            // update planet avatar if needed.
            let avatarString = prefix + "/" + "avatar.png"
            let avatarRequest = URLRequest(url: URL(string: avatarString)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            let (avatarData, _) = try await URLSession.shared.data(for: avatarRequest)
            let planetPath = _planetsPath().appendingPathComponent(id.uuidString)
            if !FileManager.default.fileExists(atPath: planetPath.path) {
                try FileManager.default.createDirectory(at: planetPath, withIntermediateDirectories: true, attributes: nil)
            }
            let avatarPath = planetPath.appendingPathComponent("avatar.png")
            if FileManager.default.fileExists(atPath: avatarPath.path) {
                try FileManager.default.removeItem(at: avatarPath)
            }
            NSImage(data: avatarData)?.imageSave(avatarPath)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .updateAvatar, object: nil)
            }
        } catch {
            debugPrint("failed to get feed: \(error)")
        }
        
        debugPrint("done updating.")
    }
    
    @objc
    func publishLocalPlanets() {
        checkDaemonStatus { status in
            guard status else { return }
            let planets = PlanetDataController.shared.getLocalPlanets()
            debugPrint("publishing local planets: \(planets) ...")
            for p in planets {
                Task.init(priority: .background) {
                    await self.publishForPlanet(planet: p)
                }
            }
        }
    }
    
    @objc
    func updateFollowingPlanets() {
        checkDaemonStatus { status in
            guard status else { return }
            let planets = PlanetDataController.shared.getFollowingPlanets()
            debugPrint("updating following planets: \(planets) ...")
            for p in planets {
                Task.init(priority: .background) {
                    await self.updateForPlanet(planet: p)
                }
            }
        }
    }

    // MARK: - Private -
    
    // MARK: TODO: convert to async method.
    private func verifyIPFSStatus(on: @escaping (Bool) -> Void) {
        debugPrint("checking command status...")
        let targetPath = _ipfsPath()
        let configPath = _configPath()
        if FileManager.default.fileExists(atPath: targetPath.path) && FileManager.default.fileExists(atPath: configPath.path) {
            do {
                let lists = try FileManager.default.contentsOfDirectory(atPath: configPath.path)
                if lists.count >= 6 {
                    let result = try runCommand(command: .ipfsGetID(target: targetPath, config: configPath))
                    debugPrint("init command result: \(result)")
                    debugPrint("command status: ready.")
                    on(true)
                } else {
                    on(false)
                }
            } catch {
                on(false)
            }
        } else {
            do {
                let binaryDataName: String = "IPFS-GO"
                if let data = NSDataAsset(name: NSDataAsset.Name(binaryDataName)) {
                    try data.data.write(to: targetPath, options: .atomic)
                    // verify permission
                    try FileManager.default.setAttributes([.posixPermissions: 755], ofItemAtPath: targetPath.path)
                    commandQueue.addOperation {
                        do {
                            var result = try runCommand(command: .ipfsInit(target: targetPath, config: configPath))
                            debugPrint("init command result: \(result)")
                            result = try runCommand(command: .ipfsGetID(target: targetPath, config: configPath))
                            debugPrint("id command result: \(result)")
                            debugPrint("command status: ready.")
                            on(true)
                        } catch {
                            debugPrint("failed to init ipfs binary: \(error)")
                            on(false)
                        }
                    }
                } else {
                    debugPrint("failed to setup ipfs binary, data asset not ready.")
                    on(false)
                }
            } catch {
                debugPrint("failed to init ipfs binary: \(error)")
                on(false)
            }
        }
    }

    private func verifyPortAvailability(port: String) -> Bool {
        var available: Bool = false
        let semaphore = DispatchSemaphore(value: 0)
        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let response = response {
                let statusCode = (response as! HTTPURLResponse).statusCode
                debugPrint("\(port) status code : \(statusCode)")
                if !(200..<500).contains(statusCode) {
                    available = true
                }
            } else {
                available = true
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return available
    }
    
    private func verifyPortAvailability(port: String, suffix: String = "/", complete: @escaping (Bool) -> Void) {
        let url = URL(string: "http://127.0.0.1:" + port + suffix)!
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 5)
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let _ = error {
                complete(false)
            } else {
                if (response as! HTTPURLResponse).statusCode == 200 {
                    complete(true)
                } else {
                    complete(false)
                }
            }
        }.resume()
    }
    
    private func serverURL(path: String, args: [String: String] = [:], timeout: TimeInterval = 5) -> URLRequest {
        var urlPath: String = "http://127.0.0.1" + ":" + apiPort + "/" + "api" + "/" + "v0"
        urlPath += "/" + path
        var url: URL = URL(string: urlPath)!
        if args != [:] {
            url = url.appendingQueryParameters(args)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        return request
    }
    
    private func terminateDaemon(forceSkip: Bool = false) {
        let request = serverURL(path: "shutdown")
        URLSession.shared.dataTask(with: request) { data, response, error in
        }.resume()
    }
    
    private func launchDaemon() {
        checkDaemonStatus { status in
            guard status == false else {
                return
            }
            
            self.commandDaemonQueue.addOperation {
                do {
                    let _ = try runCommand(command: .ipfsLaunchDaemon(target: self._ipfsPath(), config: self._configPath()))
                } catch {
                    debugPrint("failed to launch daemon: \(error). will try to start daemon again after 3 seconds.")
                    let _ = try? runCommand(command: .ipfsTerminateDaemon(target: self._ipfsPath(), config: self._configPath()))
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.checkDaemonStatus { s in
                    DispatchQueue.main.async {
                        PlanetStore.shared.daemonIsOnline = s
                    }
                    if !s {
                        DispatchQueue.global().async {
                            self.launchDaemon()
                        }
                    } else {
                        if PlanetStore.shared.peersCount > 0 {
                            DispatchQueue.global(qos: .background).async {
                                self.publishLocalPlanets()
                                self.updateFollowingPlanets()
                            }
                        }
                    }
                }
            }
        }
    }

    private func relaunchDaemonIfNeeded() {
        debugPrint("relaunching daemon ...")
        checkDaemonStatus { status in
            if status {
                // check api and gateway config, restart if needed.
                self.getAPIAndGatewayInformationFromConfig { api, gateway in
                    if let a = api, let g = gateway {
                        if let theAPIPort = a.components(separatedBy: "/").last, let theGatewayPort = g.components(separatedBy: "/").last {
                            if theAPIPort == self.apiPort, theGatewayPort == self.gatewayPort {
                                debugPrint("no need to relaunch daemon.")
                                return
                            }
                        }
                    }
                    
                    self.terminateDaemon()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.launchDaemon()
                    }
                }
            } else {
                self.launchDaemon()
            }
            
            DispatchQueue.main.async {
                PlanetStore.shared.daemonIsOnline = status
            }
        }
    }

    private func updateAPIAndGatewayPorts() {
        debugPrint("updating api and gateway ports ...")
        commandQueue.addOperation {
            for p in 5981...5991 {
                if self.verifyPortAvailability(port: String(p)) {
                    self.apiPort = String(p)
                    break
                }
            }
            
            for p in 18181...18191 {
                if self.verifyPortAvailability(port: String(p)) {
                    self.gatewayPort = String(p)
                    break
                }
            }
        }
    }

    private func getAPIAndGatewayInformationFromConfig(on: @escaping (String?, String?) -> Void) {
        let request = serverURL(path: "config/show")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if error == nil, let data = data {
                let decoder = JSONDecoder()
                do {
                    let config: PlanetConfig = try decoder.decode(PlanetConfig.self, from: data)
                    if let api = config.addresses?.api, let gateway = config.addresses?.gateway {
                        return on(api, gateway)
                    }
                } catch {
                    debugPrint("failed to decode config json: \(error)")
                }
            }
            on(nil, nil)
        }.resume()
    }
    
    private func isOnAppleSilicon() -> Bool {
        var systeminfo = utsname()
        uname(&systeminfo)
        let machine = withUnsafeBytes(of: &systeminfo.machine) {bufPtr->String in
            let data = Data(bufPtr)
            if let lastIndex = data.lastIndex(where: {$0 != 0}) {
                return String(data: data[0...lastIndex], encoding: .isoLatin1)!
            } else {
                return String(data: data, encoding: .isoLatin1)!
            }
        }
        if machine == "arm64" {
            return true
        }
        return false
    }

    private func _applicationSupportPath() -> URL? {
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    private func _basePath() -> URL {
#if DEBUG
        let bundleID = Bundle.main.bundleIdentifier! + ".v03"
#else
        let bundleID = Bundle.main.bundleIdentifier! + ".v03"
#endif
        let path: URL
        if let p = _applicationSupportPath() {
            path = p.appendingPathComponent(bundleID, isDirectory: true)
        } else {
            path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Planet")
        }
        if !FileManager.default.fileExists(atPath: path.path) {
            try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: nil)
        }
        return path
    }
    
    func _avatarPath(forPlanetID id: UUID, isEditing: Bool = false) -> URL {
        let path = _planetsPath().appendingPathComponent(id.uuidString)
        if !FileManager.default.fileExists(atPath: path.path) {
            try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: nil)
        }
        return path.appendingPathComponent("avatar.png")
    }

    private func _ipfsPath() -> URL {
        let ipfsPath = _basePath().appendingPathComponent("ipfs", isDirectory: false)
        return ipfsPath
    }
    
    private func _ipfsENVPath() -> URL {
        let envPath = _basePath().appendingPathComponent(".ipfs", isDirectory: true)
        return envPath
    }
    
    private func _configPath() -> URL {
        let configPath = _basePath().appendingPathComponent("config", isDirectory: true)
        if !FileManager.default.fileExists(atPath: configPath.path) {
            try? FileManager.default.createDirectory(at: configPath, withIntermediateDirectories: true, attributes: nil)
        }
        return configPath
    }
    
    private func _planetsPath() -> URL {
        let contentPath = _basePath().appendingPathComponent("planets", isDirectory: true)
        if !FileManager.default.fileExists(atPath: contentPath.path) {
            try? FileManager.default.createDirectory(at: contentPath, withIntermediateDirectories: true, attributes: nil)
        }
        return contentPath
    }

    private func _templatesPath() -> URL {
        let contentPath = _basePath().appendingPathComponent("templates", isDirectory: true)
        if !FileManager.default.fileExists(atPath: contentPath.path) {
            try? FileManager.default.createDirectory(at: contentPath, withIntermediateDirectories: true, attributes: nil)
        }
        return contentPath
    }
}
