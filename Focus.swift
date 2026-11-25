// Focus Nota: a tiny menu bar music player for deep work.
// Starts playing on launch, shuffles long mixes, remembers the mix and position.
// Stations are subfolders of the music folder (loose files there form one more station); "Mix" shuffles everything.
// CLI for scripts and AI agents: Nota --cmd <mix | station NAME | pick WORD… | pause | play | next> (prints the app reply), --status, --list, --test.
// "Picked" is a temporary queue from `pick`, not a folder.
import AVFoundation
import Cocoa
import MediaPlayer
import ServiceManagement

// MARK: - Settings

let bundleID = "cz.martinandrt.focusnota"
let defaults = UserDefaults.standard  // the app and its CLI share the bundle, so one domain
// Carry settings over from the old bundle id (macOS 26 kept that one blocked in the menu bar).
if defaults.persistentDomain(forName: bundleID) == nil, let old = defaults.persistentDomain(forName: "cz.martinandrt.focus") {
    defaults.setPersistentDomain(old, forName: bundleID)
}

// Music folder: override with `defaults write cz.martinandrt.focusnota musicFolder "~/Music/Focus"`.
let musicRoot = defaults.string(forKey: "musicFolder").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/Focus music")

let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "flac"]
let commandNotification = Notification.Name("\(bundleID).cmd")
let replyNotification = Notification.Name("\(bundleID).reply")
let argSeparator = "\u{1f}"
let seekStep = 600.0

// Czech UI on a Czech Mac, English elsewhere.
let czech = Locale.preferredLanguages.first?.hasPrefix("cs") ?? false
func tr(_ en: String, _ cs: String) -> String { czech ? cs : en }

let mixStation = "Mix"
let pickStation = tr("Picked", "Výběr")

func clock(_ seconds: Double) -> String {
    let s = Int(max(0, seconds))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Library

enum Library {
    static func audioFiles(in dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles])) ?? []
        // Skip files a downloader is still writing.
        return items.filter {
            audioExtensions.contains($0.pathExtension.lowercased())
                && !$0.lastPathComponent.contains(".part") && !$0.lastPathComponent.contains(".temp.")
        }
    }

    /// Station name -> folder. Loose files in the root form a station named after the root folder.
    static func stations() -> [(name: String, dir: URL)] {
        var out: [(String, URL)] = []
        // A folder may not take the name of a built-in station (Mix, Picked).
        func name(_ dir: URL) -> String {
            let n = dir.lastPathComponent
            return n == mixStation || n == pickStation ? n + tr(" (folder)", " (složka)") : n
        }
        if !audioFiles(in: musicRoot).isEmpty { out.append((name(musicRoot), musicRoot)) }
        let subdirs = (try? FileManager.default.contentsOfDirectory(at: musicRoot, includingPropertiesForKeys: [.isDirectoryKey],
                                                                     options: [.skipsHiddenFiles])) ?? []
        for dir in subdirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !audioFiles(in: dir).isEmpty {
            out.append((name(dir), dir))
        }
        return out
    }

    static func stationNames() -> [String] { [mixStation] + stations().map(\.name) }

    static func allFiles() -> [URL] { stations().flatMap { audioFiles(in: $0.dir) } }

    static func files(of station: String) -> [URL] {
        station == mixStation ? allFiles() : (stations().first { $0.name == station }.map { audioFiles(in: $0.dir) } ?? [])
    }

    static func duration(_ url: URL) -> Double? { (try? AVAudioPlayer(contentsOf: url))?.duration }
}

// MARK: - Player

final class Player: NSObject, NSApplicationDelegate, NSMenuDelegate, AVAudioPlayerDelegate {
    private var statusItem: NSStatusItem!
    private var player: AVAudioPlayer?
    private var station = mixStation
    private var queue: [URL] = []
    private var index = 0
    private var autoplay = true  // false for the first load after a login launch: ready, but silent

    private var isPlaying: Bool { player?.isPlaying == true }
    private var title: String {
        index < queue.count ? queue[index].deletingPathExtension().lastPathComponent : tr("Nothing to play", "Nic k přehrání")
    }

    // MARK: Playback

    /// Play a station. `resume` continues the last mix and position if it belongs to this station.
    func start(_ name: String, resume: Bool) {
        let name = Library.stationNames().contains(name) ? name : mixStation  // folder renamed or removed
        station = name
        if !resume { defaults.set(name, forKey: "station") }  // remember explicit choices only
        var list = Library.files(of: name).shuffled()
        var position = 0.0
        if resume, let last = defaults.string(forKey: "track"), let i = list.firstIndex(where: { $0.path == last }) {
            let saved = defaults.double(forKey: "pos"), length = defaults.double(forKey: "dur")
            if length > 0 && saved >= length - 5 {
                list.append(list.remove(at: i))  // it had practically ended: play it last, not again now
            } else {
                list.swapAt(0, i)
                position = saved
            }
        }
        load(list, at: position)
    }

    /// Queue mixes whose file names contain the given words, in that order.
    @discardableResult
    func pick(_ words: [String]) -> Bool {
        let all = Library.allFiles()
        var list: [URL] = []
        for word in words {
            for file in all.filter({ $0.lastPathComponent.localizedCaseInsensitiveContains(word) }).shuffled()
            where !list.contains(file) { list.append(file) }
        }
        guard !list.isEmpty else { return false }
        station = pickStation
        load(list)
        return true
    }

    private func load(_ list: [URL], at position: Double = 0) {
        queue = list
        index = 0
        play(at: position)
    }

    private func play(at position: Double = 0) {
        player?.stop()
        player = nil
        var position = position  // belongs to the first file only; a file after a dropped one starts at 0
        // Drop files that cannot be opened or started, so a bad file is never retried in this queue.
        while index < queue.count {
            if let p = try? AVAudioPlayer(contentsOf: queue[index]), p.duration > 0 {
                p.delegate = self
                if position > 0 && position < p.duration - 5 { p.currentTime = position }
                if autoplay ? p.play() : p.prepareToPlay() {
                    autoplay = true
                    player = p
                    save()
                    refresh()
                    return
                }
            }
            queue.remove(at: index)
            position = 0
        }
        if queue.isEmpty { stopped() } else { index = 0; play() }
    }

    private func stopped() {
        player?.stop()
        player = nil  // so the next Play reloads the station instead of a dead player
        autoplay = true
        queue = []
        for key in ["playing", "track", "pos", "dur"] { defaults.removeObject(forKey: key) }
        defaults.set(station, forKey: "now")
        refresh()
    }

    func next() {
        guard !queue.isEmpty else { return }
        index += 1
        if index >= queue.count {
            // Reshuffle, but never repeat the mix that just ended.
            let last = queue.last
            queue.shuffle()
            if queue.count > 1, queue[0] == last { queue.swapAt(0, 1) }
            index = 0
        }
        play()
    }

    func togglePlay() {
        guard let p = player else { start(station, resume: true); return }
        if p.isPlaying { p.pause() } else { p.play() }
        save()
        refresh()
    }

    func seek(by seconds: Double) {
        guard let p = player else { return }
        p.currentTime = max(0, min(p.duration - 1, p.currentTime + seconds))
        save()
        refresh()
    }

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully: Bool) { if p === player { next() } }

    func audioPlayerDecodeErrorDidOccur(_ p: AVAudioPlayer, error: Error?) {
        // Broken mid-file: drop it from this queue and play what comes next.
        guard p === player, index < queue.count else { return }
        queue.remove(at: index)
        if queue.isEmpty { stopped() } else { if index >= queue.count { index = 0 }; play() }
    }

    /// State for resuming and for `--status`.
    private func save() {
        guard let p = player, index < queue.count else { return }
        defaults.set(queue[index].path, forKey: "track")
        defaults.set(p.currentTime, forKey: "pos")
        defaults.set(p.duration, forKey: "dur")
        defaults.set(p.isPlaying, forKey: "playing")
        defaults.set(station, forKey: "now")
    }

    // MARK: Commands from the CLI

    /// Runs a CLI command; returns an error message, or nil when it was done.
    private func handle(_ args: [String]) -> String? {
        guard let command = args.first else { return "no command" }
        let rest = Array(args.dropFirst())
        switch command {
        case "mix": start(mixStation, resume: false)
        case "station", "stanice":
            guard let name = rest.first, Library.stationNames().contains(name) else {
                return "no station \(rest.first ?? "") (stations: \(Library.stationNames().joined(separator: ", ")))"
            }
            start(name, resume: false)
        case "pick", "vyber": if !pick(rest) { return "no mix name contains \(rest.joined(separator: " or "))" }
        case "pause", "pauza": if isPlaying { togglePlay() }
        case "play", "hraj":
            if !isPlaying { togglePlay() }
            if !isPlaying { return player == nil ? "nothing to play" : "playback did not start" }
        case "next", "dalsi": next()
        default: return "unknown command \(command)"
        }
        return player == nil && command != "pause" && command != "pauza" ? "nothing to play" : nil
    }

    // MARK: Menu bar

    private func refresh() {
        // Always the note; dimmed while paused.
        statusItem.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Focus Nota")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.alphaValue = isPlaying ? 1.0 : 0.4

        var info: [String: Any] = [MPMediaItemPropertyTitle: title, MPMediaItemPropertyArtist: station]
        if let p = player {
            info[MPMediaItemPropertyPlaybackDuration] = p.duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = p.currentTime
            info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func addItem(_ menu: NSMenu, _ title: String, key: String = "", checked: Bool? = nil,
                         _ action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(runItem(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = []  // plain key (space = play/pause), not Cmd+key
        item.target = self
        item.representedObject = action
        if let checked { item.state = checked ? .on : .off }
        menu.addItem(item)
    }

    private func addLabel(_ menu: NSMenu, _ text: String) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @objc private func runItem(_ sender: NSMenuItem) { (sender.representedObject as? () -> Void)?() }

    // Rebuilt on every open, so the time and the station list are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addLabel(menu, String(title.prefix(60)))
        if let p = player { addLabel(menu, "\(station) · \(clock(p.currentTime)) / \(clock(p.duration))") }

        menu.addItem(.separator())
        addItem(menu, isPlaying ? tr("Pause", "Pauza") : tr("Play", "Hrát"), key: " ") { [unowned self] in togglePlay() }
        addItem(menu, tr("Next mix", "Další mix"), key: "n") { [unowned self] in next() }
        addItem(menu, tr("Forward 10 min", "Posunout o 10 min dál"), key: "]") { [unowned self] in seek(by: seekStep) }
        addItem(menu, tr("Back 10 min", "Vrátit o 10 min"), key: "[") { [unowned self] in seek(by: -seekStep) }

        menu.addItem(.separator())
        for name in Library.stationNames() {
            let label = name == mixStation ? tr("Mix (everything shuffled)", "Mix (všechno náhodně)") : name
            addItem(menu, label, checked: name == station) { [unowned self] in start(name, resume: false) }
        }

        menu.addItem(.separator())
        addItem(menu, tr("Open at login", "Spouštět po zapnutí Macu"), checked: SMAppService.mainApp.status == .enabled) { [unowned self] in
            toggleLoginItem()
        }
        addItem(menu, tr("Open music folder", "Otevřít složku s hudbou")) { NSWorkspace.shared.open(musicRoot) }
        addItem(menu, tr("Quit", "Ukončit"), key: "q") { [unowned self] in save(); NSApp.terminate(nil) }
    }

    // MARK: Lifecycle

    private func toggleLoginItem() {
        let service = SMAppService.mainApp
        let enabled = service.status == .enabled
        if enabled { try? service.unregister() } else { try? service.register() }
        defaults.set(enabled, forKey: "loginOff")
    }

    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The launch event says whether macOS opened us as a login item; read it before it is gone.
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Media keys and Control Center.
        let remote = MPRemoteCommandCenter.shared()
        remote.togglePlayPauseCommand.addTarget { [unowned self] _ in togglePlay(); return .success }
        remote.playCommand.addTarget { [unowned self] _ in if !isPlaying { togglePlay() }; return .success }
        remote.pauseCommand.addTarget { [unowned self] _ in if isPlaying { togglePlay() }; return .success }
        remote.nextTrackCommand.addTarget { [unowned self] _ in next(); return .success }

        // Open at login unless the user turned it off.
        if !defaults.bool(forKey: "loginOff") && SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }

        DistributedNotificationCenter.default().addObserver(forName: commandNotification, object: nil, queue: .main) { [unowned self] n in
            // Message: request id, then the command and its arguments. Reply with the id and the outcome.
            let parts = ((n.object as? String) ?? "").components(separatedBy: argSeparator)
            guard let id = parts.first else { return }
            let error = handle(Array(parts.dropFirst()))
            let reply = error.map { "error: \($0)" } ?? "ok: \(station) · \(title)"
            DistributedNotificationCenter.default().postNotificationName(
                replyNotification, object: id + argSeparator + reply, userInfo: nil, deliverImmediately: true)
        }

        // Output device changed (headphones off, AirPods went to the phone): pause, never carry on out loud.
        var output = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &output, .main) { [unowned self] _, _ in
            if isPlaying { togglePlay() }
        }

        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [unowned self] _ in save() }

        // Opened by macOS at login (or right after boot): sit in the menu bar silently until asked to play.
        autoplay = !(launchedAtLogin || ProcessInfo.processInfo.systemUptime < 300)
        let saved = defaults.string(forKey: "station") ?? mixStation
        start(Library.stationNames().contains(saved) ? saved : mixStation, resume: true)
    }

    func applicationWillTerminate(_ notification: Notification) { save() }
}

// MARK: - CLI

let arguments = CommandLine.arguments
let appRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty

if let i = arguments.firstIndex(of: "--cmd") {
    // Send a command to the running app, launching it first if needed.
    if !appRunning {
        NSWorkspace.shared.open(Bundle.main.bundleURL)
        // Wait until it runs (a first-launch permission prompt can take a while), then let it register.
        for _ in 0..<60 where NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            Thread.sleep(forTimeInterval: 0.5)
        }
        Thread.sleep(forTimeInterval: 1.5)
    }
    // Send with a request id and wait for the app's reply, so a script knows the command took effect.
    let id = UUID().uuidString
    var reply: String?
    let center = DistributedNotificationCenter.default()
    let observer = center.addObserver(forName: replyNotification, object: nil, queue: nil) { n in
        let parts = ((n.object as? String) ?? "").components(separatedBy: argSeparator)
        if parts.first == id, parts.count > 1 { reply = parts[1] }
    }
    center.postNotificationName(commandNotification, object: ([id] + arguments[(i + 1)...]).joined(separator: argSeparator),
                                userInfo: nil, deliverImmediately: true)
    let deadline = Date().addingTimeInterval(10)
    while reply == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    center.removeObserver(observer)
    print(reply ?? "error: no reply from Focus Nota within 10 s")
    exit(reply?.hasPrefix("ok") == true ? 0 : 1)
}

if arguments.contains("--status") {
    let track = defaults.string(forKey: "track").map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "-"
    let state = defaults.object(forKey: "track") == nil ? "nothing to play" : (defaults.bool(forKey: "playing") ? "playing" : "paused")
    print(appRunning ? state : "stopped")
    print("station: \(defaults.string(forKey: "now") ?? "-")")
    print("mix: \(track)  \(clock(defaults.double(forKey: "pos"))) / \(clock(defaults.double(forKey: "dur")))")
    print("open at login: \(SMAppService.mainApp.status == .enabled ? "yes" : "no")")
    exit(0)
}

if arguments.contains("--list") || arguments.contains("--test") {
    // --list prints every mix with its length; --test only checks that every file decodes.
    let listing = arguments.contains("--list")
    var unreadable = 0
    if Library.stations().isEmpty {
        print("no music found in \(musicRoot.path) (missing folder, no audio files, or no permission to read it)")
        exit(1)
    }
    for station in Library.stations() {
        let files = Library.audioFiles(in: station.dir).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var total = 0.0
        if listing { print("== \(station.name)") }
        for file in files {
            guard let length = Library.duration(file) else { unreadable += 1; print("  unreadable: \(file.lastPathComponent)"); continue }
            total += length
            if listing { print("  \(clock(length))  \(file.deletingPathExtension().lastPathComponent)") }
        }
        if !listing { print("\(station.name): \(files.count) files, \(clock(total))") }
    }
    exit(unreadable == 0 ? 0 : 1)
}

if let flag = arguments.dropFirst().first(where: { $0.hasPrefix("-") && !$0.hasPrefix("-psn") && !$0.hasPrefix("-NS") }) {
    print("unknown option \(flag)\nusage: Nota [--cmd mix|station NAME|pick WORD…|pause|play|next] [--status] [--list] [--test]")
    exit(2)
}

let app = NSApplication.shared
let delegate = Player()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
