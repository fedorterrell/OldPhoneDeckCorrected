import AppKit

/// Plex and Plexamp players on your network, with no Plex account sign-in.
///
/// - **Players** (Plexamp, and Plex apps with "Advertise as player" on) are found with Plex's GDM
///   discovery (a UDP broadcast on port 32412) plus Plexamp on this Mac (127.0.0.1:32500).
/// - **What's playing** comes from each player's Plex Companion timeline (`/player/timeline/poll`):
///   state, position, track ID, play queue, shuffle/repeat, volume, and the server it streams from.
/// - **Song details, art, browse, search and starting music** come from that Plex Media Server.
///   The server answers without a token only when it trusts this Mac: Plex server Settings › Network ›
///   "List of IP addresses and networks that are allowed without auth". Until then the deck shows the
///   player's state and controls, and explains how to add the Mac.
/// - **Commands** go straight to the player (`/player/playback/*`); for Plexamp on this Mac, the media
///   keys are the fallback.
final class Plex {
    private let queue = DispatchQueue(label: "plex")           // state and HTTP, one at a time
    private let scanQueue = DispatchQueue(label: "plex-gdm")    // discovery, off the main path
    private let http = URLSession(configuration: .ephemeral)

    private struct Config: Codable {
        var clientID = UUID().uuidString
        var playerID: String?
        var serverURL: String?        // last server a player streamed from (for browsing while idle)
        var serverID: String?
    }
    private static let file = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".phonedeck/plex.json")
    private var config: Config

    struct Player { let id: String; var name, product, host: String; var port: Int; var seen: Date }
    private var players: [String: Player] = [:]
    private var servers: [String: (name: String, url: String)] = [:]   // machine identifier → GDM-found server
    private var trusted: [String: Bool] = [:]                           // server URL → answers without auth
    private var timelines: [String: [String: String]] = [:]             // player id → active timeline
    private var routes: [String: String] = [:]                          // player id → route that last worked
    private var meta: [String: [String: Any]] = [:]                     // "server|ratingKey" → song details
    private var cache: (at: Date, value: [String: Any])?
    private var art: [String: Data] = [:]
    private var artOrder: [String] = []
    private var commandID = 0
    private var scannedAt = Date.distantPast

    init() {
        if let data = try? Data(contentsOf: Plex.file), let c = try? JSONDecoder().decode(Config.self, from: data) { config = c }
        else { config = Config(); save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? FileManager.default.createDirectory(at: Plex.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Plex.file, options: .atomic)
    }

    /// True once a player has been seen (Now Playing only asks Plex then).
    var active: Bool { queue.sync { !players.isEmpty } }

    // MARK: discovery

    /// Looks for players and servers now and every minute after. Plexamp on this Mac is checked directly.
    func start() {
        scan()
        let t = DispatchSource.makeTimerSource(queue: scanQueue)
        t.schedule(deadline: .now() + 60, repeating: 60)
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        timer = t
    }
    private var timer: DispatchSourceTimer?

    func rescan() { scanQueue.async { self.scan() } }

    private func scan() {
        var found: [Player] = []
        // Plexamp on this Mac (GDM replies don't always loop back to the sender).
        if let p = identify(host: "127.0.0.1", port: 32500) { found.append(p) }
        for reply in Plex.gdm(host: "255.255.255.255", port: 32412) where reply.headers["Content-Type"]?.contains("player") ?? true {
            let port = Int(reply.headers["Port"] ?? "") ?? 32500
            guard reply.headers["Resource-Identifier"] != nil, !found.contains(where: { $0.host == reply.ip && $0.port == port }) else { continue }
            // Plexamp on this Mac also answers the broadcast: keep its 127.0.0.1 entry (media-key fallback).
            if let p = identify(host: reply.ip, port: port), !found.contains(where: { $0.id == p.id }) { found.append(p) }
        }
        let gdmServers = Plex.gdm(host: "239.0.0.250", port: 32414).compactMap { r -> (String, String, String)? in
            guard let id = r.headers["Resource-Identifier"], r.headers["Content-Type"]?.contains("server") ?? false else { return nil }
            return (id, r.headers["Name"] ?? "Plex", "http://\(r.ip):\(r.headers["Port"] ?? "32400")")
        }
        queue.async {
            let now = Date()
            for p in found { self.players[p.id] = p }
            let foundIDs = Set(found.map { $0.id })
            self.players = self.players.filter { now.timeIntervalSince($0.value.seen) < 300 || foundIDs.contains($0.key) }
            for s in gdmServers { self.servers[s.0] = (s.1, s.2) }
            if self.config.serverURL == nil, let s = gdmServers.first { self.config.serverURL = s.2; self.config.serverID = s.0; self.save() }
            self.scannedAt = now
            self.cache = nil
        }
    }

    /// A player's name and product from its /resources, or nil if it doesn't answer as a Plex player.
    private func identify(host: String, port: Int) -> Player? {
        let r = request("GET", "http://\(host):\(port)/resources", timeout: 1.5)
        guard r.status == 200, let p = XMLAttributes.parse(r.data, element: "Player").first, let id = p["machineIdentifier"] else { return nil }
        return Player(id: id, name: p["title"] ?? "Plex player", product: p["product"] ?? "Plex", host: host, port: port, seen: Date())
    }

    // MARK: now playing

    /// Every player's state and the one the deck shows. Cached 1.5 s.
    func snapshot() -> [String: Any] {
        queue.sync {
            if let c = cache, Date().timeIntervalSince(c.at) < 1.5 { return c.value }
            let v = refresh()
            cache = (Date(), v)
            return v
        }
    }

    private func refresh() -> [String: Any] {
        var sessions: [[String: Any]] = []
        for p in players.values.sorted(by: { $0.name < $1.name }) {
            guard let t = pollTimeline(p) else { continue }
            players[p.id]?.seen = Date()
            sessions.append(session(p, t))
        }
        var out: [String: Any] = ["players": playerList(), "playerID": config.playerID ?? "", "sessions": sessions]
        if players.isEmpty {
            out["status"] = "noplayer"
            out["error"] = scannedAt == .distantPast ? "Looking for Plex players…" : "No Plex player found: open Plexamp on this Mac or on your network"
            return out
        }
        out["status"] = "ok"
        let current = sessions.first { $0["playerID"] as? String == config.playerID && $0["state"] as? String != "stopped" }
            ?? sessions.first { $0["state"] as? String == "playing" }
            ?? sessions.first { $0["state"] as? String == "paused" }
        if let c = current { out["current"] = c }
        return out
    }

    /// The player's music (or video) timeline, or nil if it doesn't answer.
    private func pollTimeline(_ p: Player) -> [String: String]? {
        commandID += 1
        let r = request("GET", "http://\(p.host):\(p.port)/player/timeline/poll?wait=0&commandID=\(commandID)", timeout: 1.5,
                        extra: ["X-Plex-Target-Client-Identifier": p.id])
        guard r.status == 200 else { return nil }
        let all = XMLAttributes.parse(r.data, element: "Timeline")
        let t = all.first { $0["type"] == "music" && $0["state"] != "stopped" } ?? all.first { $0["state"] != "stopped" && $0["state"] != nil }
            ?? all.first { $0["type"] == "music" } ?? [:]
        timelines[p.id] = t
        return t
    }

    private func session(_ p: Player, _ t: [String: String]) -> [String: Any] {
        let state = t["state"] ?? "stopped"
        var s: [String: Any] = [
            "playerID": p.id, "player": p.name, "product": p.product, "state": state, "type": t["type"] ?? "music",
            "duration": Double(t["duration"] ?? "0").map { $0 / 1000 } ?? 0, "position": Double(t["time"] ?? "0").map { $0 / 1000 } ?? 0,
            "shuffle": t["shuffle"] == "1", "repeat": Int(t["repeat"] ?? "0") ?? 0, "volume": Int(t["volume"] ?? "") ?? -1,
            "queue": t["playQueueID"] ?? "", "ratingKey": t["ratingKey"] ?? "", "route": routes[p.id] ?? "",
            "controllable": t["controllable"] ?? "", "title": "", "artist": "", "album": "", "thumb": "", "rating": 0.0,
        ]
        guard state != "stopped", let server = serverURL(t), let rk = t["ratingKey"], !rk.isEmpty else { return s }
        if config.serverURL != server { config.serverURL = server; config.serverID = t["machineIdentifier"]; save() }
        if let m = details(server: server, ratingKey: rk) { s.merge(m) { $1 } }
        else {
            s["title"] = "Playing on \(p.name)"
            s["artist"] = "Trust this Mac in Plex to see the song (Command Center › Plex)"
            s["untrusted"] = true
        }
        return s
    }

    /// The Plex Media Server a timeline streams from, as a base URL.
    private func serverURL(_ t: [String: String]) -> String? {
        guard let host = t["address"], !host.isEmpty else { return nil }
        return "\(t["protocol"] ?? "http")://\(host):\(t["port"] ?? "32400")"
    }

    /// Title, artist, album, art and rating for a track (or episode/movie), cached. Nil if the server wants a token.
    private func details(server: String, ratingKey: String) -> [String: Any]? {
        let key = server + "|" + ratingKey
        if let m = meta[key] { return m }
        let r = request("GET", server + "/library/metadata/" + ratingKey, timeout: 4)
        trusted[server] = r.status == 200
        guard r.status == 200, let m = (Plex.container(r.data)?["Metadata"] as? [[String: Any]])?.first else { return nil }
        let type = m["type"] as? String ?? ""
        let thumb = (type == "track" ? (m["parentThumb"] as? String ?? m["thumb"] as? String)
                     : type == "episode" ? (m["grandparentThumb"] as? String ?? m["thumb"] as? String) : m["thumb"] as? String) ?? ""
        let d: [String: Any] = [
            "type": type, "title": m["title"] as? String ?? "",
            "artist": (type == "track" ? m["originalTitle"] as? String ?? m["grandparentTitle"] as? String
                       : type == "episode" ? m["grandparentTitle"] as? String : m["year"].map { "\($0)" }) ?? "",
            "album": (type == "track" ? m["parentTitle"] as? String : type == "episode" ? m["parentTitle"] as? String : nil) ?? "",
            "thumb": thumb, "rating": m["userRating"] as? Double ?? 0,
        ]
        meta[key] = d
        if meta.count > 200 { meta.removeAll() }
        return d
    }

    /// The current session in the Now Playing widget's format (see `Music.refresh`), or nil.
    func nowPlaying() -> [String: Any]? {
        guard let c = snapshot()["current"] as? [String: Any], let title = c["title"] as? String, !title.isEmpty else { return nil }
        return ["app": "Plex", "playing": c["state"] as? String == "playing", "title": title, "artist": c["artist"] ?? "",
                "album": c["album"] ?? "", "duration": c["duration"] ?? 0, "position": c["position"] ?? 0,
                "id": "plex:\(c["ratingKey"] ?? "")", "thumb": c["thumb"] ?? ""]
    }

    private func playerList() -> [[String: Any]] {
        players.values.sorted { $0.name < $1.name }.map { ["id": $0.id, "name": $0.name, "product": $0.product, "host": $0.host] }
    }

    // MARK: Command Center

    func setupStatus() -> [String: Any] {
        queue.sync {
            var out: [String: Any] = ["players": playerList(), "playerID": config.playerID ?? "", "mac": lanAddress(),
                                      "scanned": scannedAt != .distantPast]
            if let url = config.serverURL {
                if trusted[url] == nil { trusted[url] = request("GET", url + "/library/sections", timeout: 4).status == 200 }
                let name = servers[config.serverID ?? ""]?.name ?? URL(string: url)?.host?.components(separatedBy: ".").first?.replacingOccurrences(of: "-", with: ".") ?? url
                out["server"] = ["name": name, "url": url, "trusted": trusted[url] ?? false]
            }
            return out
        }
    }

    func choose(player: String?) {
        queue.sync { config.playerID = (player ?? "").isEmpty ? nil : player; save(); cache = nil }
    }

    /// Checks the server again (after you add this Mac to its trusted list).
    func recheck() { queue.sync { trusted = [:]; meta = [:]; cache = nil } }

    // MARK: artwork

    func artwork(_ thumb: String, size: Int) -> Data? {
        guard thumb.hasPrefix("/"), !thumb.contains("://") else { return nil }
        let px = max(64, min(800, size)), key = "\(thumb)@\(px)"
        return queue.sync {
            if let d = art[key] { return d }
            guard let server = config.serverURL else { return nil }
            let enc = thumb.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            let r = request("GET", server + "/photo/:/transcode?width=\(px)&height=\(px)&minSize=1&upscale=1&format=jpeg&url=\(enc)", timeout: 6)
            guard r.status == 200, !r.data.isEmpty else { return nil }
            art[key] = r.data; artOrder.append(key)
            if artOrder.count > 60 { art[artOrder.removeFirst()] = nil }
            return r.data
        }
    }

    // MARK: control

    /// cmd: playpause | play | pause | next | previous | seek (value: s) | shuffle (0/1) | repeat (0/1/2)
    /// | volume (0–100) | stop | rate (value 0–10) | player (key: id) | skipTo (key: queue item) | start (key, value 1 = shuffle).
    func control(_ cmd: String, value: Double?, key: String?) -> [String: Any] {
        queue.sync {
            cache = nil
            if cmd == "player" { config.playerID = (key ?? "").isEmpty ? nil : key; save(); return ["ok": true] }
            let cur = refresh()["current"] as? [String: Any]
            let pid = (cur?["playerID"] as? String) ?? config.playerID ?? (players.count == 1 ? players.keys.first : nil) ?? ""
            guard let player = players[pid] else { return ["ok": false, "route": "unsupported", "error": "No Plex player to control"] }
            let type = (cur?["type"] as? String).map { ["episode", "movie", "clip"].contains($0) ? "video" : "music" } ?? "music"
            switch cmd {
            case "rate":
                guard let server = config.serverURL, let rk = (key?.isEmpty == false ? key : cur?["ratingKey"] as? String) else { return ["ok": false] }
                let r = request("PUT", server + "/:/rate?key=\(rk)&identifier=com.plexapp.plugins.library&rating=\(Int(value ?? 0))")
                meta = [:]
                return ["ok": r.status == 200, "route": "server", "error": r.status == 401 ? "Trust this Mac in Plex to rate songs" : ""]
            case "start": return start(key ?? "", shuffle: value == 1, player: player)
            default: break
            }
            let path: String
            switch cmd {
            case "playpause": path = "playPause"
            case "play", "pause", "stop": path = cmd
            case "next": path = "skipNext"
            case "previous": path = "skipPrevious"
            case "seek": path = "seekTo?offset=\(Int((value ?? 0) * 1000))"
            case "shuffle": path = "setParameters?shuffle=\(Int(value ?? 0))"
            case "repeat": path = "setParameters?repeat=\(Int(value ?? 0))"
            case "volume": path = "setParameters?volume=\(Int(value ?? 50))"
            case "skipTo": path = "skipTo?key=\(key ?? "")"
            default: return ["ok": false, "error": "unknown command"]
            }
            let mediaKey = ["playpause": "playpause", "next": "next", "previous": "previous"][cmd]
            let route = send(path, type: type, to: player, mediaKey: mediaKey)
            return ["ok": route != "unsupported", "route": route]
        }
    }

    /// Plex Companion straight to the player; Plexamp on this Mac falls back to the media keys.
    private func send(_ path: String, type: String, to p: Player, mediaKey: String?) -> String {
        commandID += 1
        let sep = path.contains("?") ? "&" : "?"
        let url = "http://\(p.host):\(p.port)/player/playback/\(path)\(sep)type=\(type)&commandID=\(commandID)"
        if request("GET", url, timeout: 3, extra: ["X-Plex-Target-Client-Identifier": p.id]).status == 200 { routes[p.id] = "direct"; return "direct" }
        if p.host == "127.0.0.1", let k = mediaKey {
            DispatchQueue.main.async { MediaKey.press(k) }
            routes[p.id] = "keys"; return "keys"
        }
        routes[p.id] = "unsupported"
        return "unsupported"
    }

    /// Starts an album, artist, track, playlist or station: a play queue on the server, then playMedia on the player.
    private func start(_ key: String, shuffle: Bool, player p: Player) -> [String: Any] {
        guard let server = config.serverURL, let sid = config.serverID ?? serverID(server), !key.isEmpty else {
            return ["ok": false, "error": "No Plex server yet: play something once in Plexamp"]
        }
        let source: String
        if key.hasPrefix("playlist:") { source = "playlistID=\(key.dropFirst(9))" }
        else { source = "uri=" + ("server://\(sid)/com.plexapp.plugins.library\(key)".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "") }
        let r = request("POST", server + "/playQueues?type=audio&\(source)&shuffle=\(shuffle ? 1 : 0)&repeat=0&continuous=0")
        guard r.status == 200, let mc = Plex.container(r.data), let qid = mc["playQueueID"].map({ "\($0)" }) else {
            return ["ok": false, "error": r.status == 401 ? "Trust this Mac in Plex to start music" : "The server didn't make a play queue (\(r.status))"]
        }
        let first = (mc["Metadata"] as? [[String: Any]])?.first?["key"] as? String ?? ""
        guard let u = URL(string: server), let host = u.host else { return ["ok": false] }
        let port = u.port ?? (u.scheme == "https" ? 443 : 32400)
        let path = "playMedia?key=\(first)&offset=0&machineIdentifier=\(sid)&address=\(host)&port=\(port)&protocol=\(u.scheme ?? "http")"
            + "&containerKey=%2FplayQueues%2F\(qid)%3Fown%3D1%26window%3D200"
        let route = send(path, type: "music", to: p, mediaKey: nil)
        return ["ok": route != "unsupported", "route": route]
    }

    private func serverID(_ server: String) -> String? {
        let r = request("GET", server + "/identity", timeout: 3)
        return Plex.container(r.data)?["machineIdentifier"] as? String
    }

    // MARK: browse and search (the server, when it trusts this Mac)

    func browse(_ key: String?) -> [String: Any] {
        queue.sync {
            guard let server = config.serverURL else { return ["status": "noserver"] }
            guard let key, !key.isEmpty else {
                var rows: [[String: Any]] = [["kind": "dir", "title": "Playlists", "key": "/playlists?playlistType=audio"]]
                let r = request("GET", server + "/library/sections")
                if r.status == 401 { return ["status": "untrusted"] }
                for d in (Plex.container(r.data)?["Directory"] as? [[String: Any]] ?? []) where d["type"] as? String == "artist" {
                    let id = d["key"] as? String ?? ""
                    rows.append(["kind": "header", "title": d["title"] as? String ?? "Music"])
                    rows.append(["kind": "dir", "title": "Recently Added", "key": "/library/sections/\(id)/recentlyAdded?type=9"])
                    rows.append(["kind": "dir", "title": "Stations", "key": "/hubs/sections/\(id)?includeStations=1"])
                    rows.append(["kind": "dir", "title": "Artists", "key": "/library/sections/\(id)/all?type=8&sort=titleSort"])
                    rows.append(["kind": "dir", "title": "Albums", "key": "/library/sections/\(id)/all?type=9&sort=addedAt:desc"])
                }
                return ["status": r.status == 200 ? "ok" : "offline", "items": rows]
            }
            guard key.hasPrefix("/"), !key.contains("://") else { return ["items": []] }
            let sep = key.contains("?") ? "&" : "?"
            let r = request("GET", server + key + sep + "X-Plex-Container-Start=0&X-Plex-Container-Size=80")
            if r.status == 401 { return ["status": "untrusted"] }
            guard r.status == 200, let mc = Plex.container(r.data) else { return ["status": "offline", "items": []] }
            return ["status": "ok", "title": mc["title2"] as? String ?? mc["title1"] as? String ?? "", "items": rows(mc, parent: key)]
        }
    }

    func search(_ text: String) -> [String: Any] {
        queue.sync {
            let q = text.trimmingCharacters(in: .whitespaces).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            guard let server = config.serverURL else { return ["status": "noserver"] }
            guard !q.isEmpty else { return ["items": []] }
            let r = request("GET", server + "/hubs/search?query=\(q)&limit=8&includeCollections=0", timeout: 8)
            if r.status == 401 { return ["status": "untrusted"] }
            guard r.status == 200, let mc = Plex.container(r.data) else { return ["status": "offline", "items": []] }
            return ["status": "ok", "items": rows(mc, parent: "/hubs/search")]
        }
    }

    func upNext(_ queueID: String) -> [String: Any] {
        queue.sync {
            guard Int(queueID) != nil, let server = config.serverURL else { return ["items": []] }
            let r = request("GET", server + "/playQueues/\(queueID)?window=30&own=1")
            if r.status == 401 { return ["status": "untrusted", "items": []] }
            guard r.status == 200, let mc = Plex.container(r.data) else { return ["items": []] }
            let selected = mc["playQueueSelectedItemID"].map { "\($0)" } ?? ""
            let all = mc["Metadata"] as? [[String: Any]] ?? []
            let at = all.firstIndex { "\($0["playQueueItemID"] ?? "")" == selected } ?? -1
            return ["status": "ok", "items": all.dropFirst(at + 1).prefix(12).map { m -> [String: Any] in
                var row = Plex.row(m, parent: ""); row["queueItem"] = "\(m["playQueueItemID"] ?? "")"; return row
            }]
        }
    }

    private func rows(_ mc: [String: Any], parent: String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        if let hubs = mc["Hub"] as? [[String: Any]] {
            for h in hubs {
                let items = (h["Metadata"] as? [[String: Any]] ?? []) + (h["Directory"] as? [[String: Any]] ?? [])
                guard !items.isEmpty else { continue }
                out.append(["kind": "header", "title": h["title"] as? String ?? ""])
                out += items.prefix(12).map { Plex.row($0, parent: parent) }
            }
            return out
        }
        out += (mc["Directory"] as? [[String: Any]] ?? []).map { Plex.row($0, parent: parent) }
        out += (mc["Metadata"] as? [[String: Any]] ?? []).map { Plex.row($0, parent: parent) }
        return out
    }

    /// One list row: what to show, where tapping goes (key) and what playing starts (play).
    private static func row(_ m: [String: Any], parent: String) -> [String: Any] {
        let type = m["type"] as? String ?? "dir"
        var key = m["key"] as? String ?? ""
        if !key.isEmpty, !key.hasPrefix("/") { key = (parent.split(separator: "?").first.map(String.init) ?? "") + "/" + key }
        let rk = m["ratingKey"] as? String ?? ""
        let sub: String
        switch type {
        case "album": sub = [m["parentTitle"] as? String, (m["year"] as? Int).map(String.init)].compactMap { $0 }.joined(separator: " · ")
        case "track": sub = [m["originalTitle"] as? String ?? m["grandparentTitle"] as? String, m["parentTitle"] as? String].compactMap { $0 }.joined(separator: " · ")
        case "playlist": sub = "\(m["leafCount"] ?? 0) tracks"
        case "artist": sub = "Artist"
        default: sub = (m["summary"] as? String).map { String($0.prefix(60)) } ?? ""
        }
        var play = ""
        if type == "playlist" { play = "playlist:" + rk }
        else if ["album", "artist", "track"].contains(type), !rk.isEmpty { play = "/library/metadata/" + rk }
        else if key.contains("/station") || type == "station" { play = key }
        return ["kind": type == "track" ? "track" : "dir", "type": type, "title": m["title"] as? String ?? "",
                "subtitle": sub, "key": type == "track" ? "" : key, "play": play,
                "thumb": m["thumb"] as? String ?? m["parentThumb"] as? String ?? m["composite"] as? String ?? ""]
    }

    // MARK: HTTP and GDM

    private func request(_ method: String, _ url: String, timeout: TimeInterval = 6, extra: [String: String] = [:]) -> (status: Int, data: Data) {
        guard let u = URL(string: url) else { return (0, Data()) }
        var r = URLRequest(url: u, timeoutInterval: timeout)
        r.httpMethod = method
        let fields: [String: String] = [
            "Accept": "application/json", "X-Plex-Product": "PhoneDeck", "X-Plex-Version": "2.0",
            "X-Plex-Client-Identifier": config.clientID, "X-Plex-Platform": "macOS",
            "X-Plex-Device-Name": Host.current().localizedName ?? "Mac", "X-Plex-Provides": "controller",
        ]
        for (k, v) in fields.merging(extra, uniquingKeysWith: { $1 }) { r.setValue(v, forHTTPHeaderField: k) }
        let done = DispatchSemaphore(value: 0)
        var out = (status: 0, data: Data())
        http.dataTask(with: r) { data, resp, _ in
            out = ((resp as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data())
            done.signal()
        }.resume()
        done.wait()
        return out
    }

    private static func container(_ d: Data) -> [String: Any]? {
        ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["MediaContainer"] as? [String: Any]
    }

    /// Plex "G'Day Mate" discovery: an M-SEARCH datagram, then 1.5 s of replies (HTTP-style header lines).
    private static func gdm(host: String, port: UInt16) -> [(ip: String, headers: [String: String])] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var ttl: UInt8 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        let msg = Array("M-SEARCH * HTTP/1.1\r\n\r\n".utf8)
        let sent = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, msg, msg.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard sent > 0 else { return [] }
        var out: [(String, [String: String])] = []
        let end = Date().addingTimeInterval(1.5)
        var buf = [UInt8](repeating: 0, count: 4096)
        while Date() < end {
            var from = sockaddr_in(), len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            guard n > 0 else { continue }
            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
            var headers: [String: String] = [:]
            for line in (String(bytes: buf[0..<n], encoding: .utf8) ?? "").components(separatedBy: "\r\n").dropFirst() {
                guard let i = line.firstIndex(of: ":") else { continue }
                headers[String(line[..<i]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces)
            }
            out.append((String(cString: ipBuf), headers))
        }
        return out
    }
}

/// Plex Companion answers in XML (<MediaContainer><Timeline …/></MediaContainer>): the attributes of each named element.
private final class XMLAttributes: NSObject, XMLParserDelegate {
    private var found: [[String: String]] = []
    private let element: String
    private init(_ element: String) { self.element = element }
    static func parse(_ data: Data, element: String) -> [[String: String]] {
        let p = XMLAttributes(element), x = XMLParser(data: data)
        x.delegate = p
        x.parse()
        return p.found
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == element { found.append(attributes) }
    }
}
