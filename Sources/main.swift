// Claude Peek — a top-of-screen pill showing your Claude Code sessions.
// Hover to expand. Hidden from screen sharing via NSWindow.sharingType = .none.

import AppKit
import SwiftUI
import Darwin

// MARK: - Model

enum Source { case app, terminal }

enum Activity: Int, Comparable {
    case waiting = 0, working, unread, idle
    static func < (a: Activity, b: Activity) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .waiting: return "Needs you"
        case .working: return "Working"
        case .unread: return "Unread"
        case .idle: return "Idle"
        }
    }

    var color: Color {
        switch self {
        case .waiting: return Color(red: 1.0, green: 0.78, blue: 0.25)
        case .working: return Color(red: 0.98, green: 0.52, blue: 0.27)
        case .unread: return Color(red: 0.35, green: 0.66, blue: 1.0)
        case .idle: return Color.white.opacity(0.35)
        }
    }
}

struct Session: Identifiable, Equatable {
    let id: String          // Claude Code session id
    let title: String
    let source: Source
    let activity: Activity
    let folder: String
    let updated: Date
    let pid: Int32?
    let note: String?
    let readEdge: Double    // timestamp (ms) that "mark read" acknowledges
    var appSessionId: String? = nil   // the desktop app's own id (local_…), for deep links
}

/// One Slack conversation where someone is waiting on you, written by the scheduled scan
/// (task `slack-waiting-on-me`) to ~/Library/Application Support/ClaudePeek/slack.json.
struct SlackItem: Identifiable, Equatable {
    let id: String          // channel id + thread ts
    let from: String
    let place: String       // "#channel", "DM" or "Group DM"
    let summary: String
    let kind: String        // error | approval | question | request
    let priority: SlackPriority
    let ts: Double          // the message waiting on you, unix seconds
    let permalink: URL
    var seen = false

    var symbol: String {
        switch kind {
        case "error": return "exclamationmark.triangle.fill"
        case "approval": return "checkmark.seal.fill"
        case "question": return "questionmark.bubble.fill"
        default: return "bubble.left.fill"
        }
    }

    var color: Color {
        kind == "error" ? urgentColor : slackColor
    }

    /// Still on your plate: anything you haven't replied to, and "just read" items you haven't opened.
    var pending: Bool { !(priority == .read && seen) }
}

/// How soon a Slack item needs you. The scan decides; older files without it fall back to `kind`.
enum SlackPriority: String, Comparable, CaseIterable {
    case blocked    // someone can't proceed until you approve, decide or fix
    case input      // your answer or review is needed, but nobody is stuck yet
    case read       // they want you to see it; opening it is enough

    init(_ raw: String?, kind: String) {
        if let raw, let p = SlackPriority(rawValue: raw) { self = p; return }
        switch kind {
        case "error", "approval": self = .blocked
        case "question", "request": self = .input
        default: self = .read
        }
    }

    static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    var title: String {
        switch self {
        case .blocked: return "Blocked on you · reply first"
        case .input: return "Needs your input"
        case .read: return "Just read it"
        }
    }

    var action: String {
        switch self {
        case .blocked: return "Reply now"
        case .input: return "Reply"
        case .read: return "Read"
        }
    }

    var color: Color {
        switch self {
        case .blocked: return urgentColor
        case .input: return slackColor
        case .read: return Color(red: 0.6, green: 0.72, blue: 0.88)
        }
    }
}

let slackColor = Color(red: 0.78, green: 0.58, blue: 1.0)

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
let urgentColor = Color(red: 1.0, green: 0.42, blue: 0.4)

/// Fields we use from the desktop app's per-session file.
private struct DesktopRecord {
    let cliId: String
    let localId: String
    let title: String
    let cwd: String
    let archived: Bool
    let focusedAt: Double
    let turnEdgeAt: Double
    let awaitingPerson: Bool
    let scheduledTaskId: String?
}

/// One live Claude Code process, from ~/.claude/sessions/<pid>.json.
private struct LiveProcess {
    let pid: Int32
    let sessionId: String
    let cwd: String
    let name: String?
    let status: String
    let waitingFor: String?
    let entrypoint: String
    let statusUpdatedAt: Double
}

// MARK: - Store

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var slack: [SlackItem] = []
    var slackPending: [SlackItem] { slack.filter(\.pending) }
    var slackBlocked: Int { slack.filter { $0.priority == .blocked }.count }
    @Published private(set) var slackScannedAt: Date?
    @Published private(set) var slackRefreshing = false
    @Published private(set) var slackRefreshFailed = false
    private var slackScanPid: Int32?

    /// "checked 12m ago", or what the refresh button is doing right now.
    var slackChecked: String? {
        if slackRefreshing { return "checking now…" }
        let checked = slackScannedAt.map { "checked \(ago($0)) ago" }
        return slackRefreshFailed ? (checked.map { "refresh failed · " + $0 } ?? "refresh failed") : checked
    }
    var onChange: (() -> Void)?

    /// The scheduled task that writes slack.json. Its own runs are hidden from the session list.
    static let slackTaskId = "slack-waiting-on-me"
    private var slackMtime: Date?
    private var slackParsed: [SlackItem] = []
    /// Messages you sent from the Slack app, from its own log: "<channel>" or "<channel>-<thread ts>"
    /// → when you last sent there (unix seconds).
    private var slackSends: [String: Double] = [:]
    private var slackLogOffset: UInt64 = 0
    private var slackLogFile: Int?

    private let fm = FileManager.default
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var desktopCache: [String: (Date, DesktopRecord)] = [:]
    private var acks: [String: Double] = [:]
    private let launchedAt = Date().timeIntervalSince1970 * 1000
    private var timer: Timer?

    private var acksURL: URL {
        home.appendingPathComponent("Library/Application Support/ClaudePeek/acks.json")
    }

    init() {
        if let data = try? Data(contentsOf: acksURL),
           let saved = try? JSONDecoder().decode([String: Double].self, from: data) {
            acks = saved
        }
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var working: [Session] { sessions.filter { $0.activity == .working || $0.activity == .waiting } }
    var unread: [Session] { sessions.filter { $0.activity == .unread } }
    var idle: [Session] { sessions.filter { $0.activity == .idle } }

    func refresh() {
        let now = Date().timeIntervalSince1970 * 1000
        let desktop = loadDesktop()
        let waitingNames = loadWaitingInput()
        var out: [Session] = []
        var seen = Set<String>()

        for p in loadLive() {
            seen.insert(p.sessionId)
            let d = desktop[p.sessionId]
            if d?.scheduledTaskId == Self.slackTaskId { continue }
            let isApp = p.entrypoint.contains("desktop")
            let title = d?.title ?? p.name ?? folderName(p.cwd)
            let ack = acks[p.sessionId] ?? (launchedAt - 30 * 60 * 1000)

            let activity: Activity
            let waiting = p.waitingFor != nil || p.status.contains("wait") || d?.awaitingPerson == true
                || (d.map { r in waitingNames.contains { $0.contains(r.localId) } } ?? false)
            if waiting {
                activity = .waiting
            } else if p.status == "busy" {
                activity = .working
            } else if let d {
                activity = (d.turnEdgeAt > d.focusedAt + 1000 && d.turnEdgeAt > ack) ? .unread : .idle
            } else {
                activity = p.statusUpdatedAt > ack ? .unread : .idle
            }

            out.append(Session(
                id: p.sessionId, title: title, source: isApp ? .app : .terminal, activity: activity,
                folder: folderName(d?.cwd ?? p.cwd),
                updated: Date(timeIntervalSince1970: max(p.statusUpdatedAt, d?.turnEdgeAt ?? 0) / 1000),
                pid: p.pid, note: p.waitingFor,
                readEdge: max(p.statusUpdatedAt, d?.turnEdgeAt ?? 0), appSessionId: d?.localId))
        }

        // App sessions with no live process that finished after you last looked at them.
        // Scheduled-task runs collapse to their newest run.
        // A run of a scheduled task that is still live absorbs its older unread runs.
        var liveTasks: [String: Int] = [:]
        for (i, s) in out.enumerated() {
            if let task = desktop[s.id]?.scheduledTaskId { liveTasks[task] = i }
        }
        var absorbed: [Int: Int] = [:]
        var groups: [String: (DesktopRecord, Int)] = [:]
        // Archived sessions count too: archiving one that's still working shouldn't hide its result.
        for d in desktop.values where !seen.contains(d.cliId) && d.scheduledTaskId != Self.slackTaskId {
            guard d.turnEdgeAt > d.focusedAt + 1000,
                  d.turnEdgeAt > (acks[d.cliId] ?? 0),
                  now - d.turnEdgeAt < 7 * 24 * 3600 * 1000 else { continue }
            if let task = d.scheduledTaskId, let i = liveTasks[task] {
                absorbed[i, default: 0] += 1
                continue
            }
            let key = d.scheduledTaskId ?? d.cliId
            if let (cur, n) = groups[key] {
                groups[key] = (d.turnEdgeAt > cur.turnEdgeAt ? d : cur, n + 1)
            } else {
                groups[key] = (d, 1)
            }
        }
        for (i, n) in absorbed {
            let s = out[i]
            out[i] = Session(id: s.id, title: s.title, source: s.source, activity: s.activity, folder: s.folder,
                             updated: s.updated, pid: s.pid, note: "+\(n) earlier unread runs", readEdge: s.readEdge,
                             appSessionId: s.appSessionId)
        }
        for (d, n) in groups.values {
            out.append(Session(
                id: d.cliId, title: d.title, source: .app, activity: .unread,
                folder: folderName(d.cwd), updated: Date(timeIntervalSince1970: d.turnEdgeAt / 1000),
                pid: nil, note: [d.archived ? "Archived" : nil, n > 1 ? "\(n) unread runs" : nil].compactMap { $0 }
                    .joined(separator: " · ").nilIfEmpty, readEdge: d.turnEdgeAt, appSessionId: d.localId))
        }

        out.sort { ($0.activity, $1.updated) < ($1.activity, $0.updated) }

        loadSlack()
        loadSlackSends()
        markSlackReplies()
        let slackNow = slackParsed.compactMap { item -> SlackItem? in
            if (acks["slack-replied:" + item.id] ?? 0) > item.ts * 1000 { return nil }
            var i = item
            i.seen = (acks["slack:" + i.id] ?? 0) >= i.ts * 1000
            return i
        }

        if out != sessions || slackNow != slack {
            sessions = out
            slack = slackNow
            onChange?()
        }
    }

    /// Opens the thread in the Slack app and notes that you've looked. "Just read" items are then
    /// done; everything else stays until you reply (see `markSlackReplies`) or the next scan drops it.
    func openSlack(_ item: SlackItem) {
        // The Slack app ignores https permalinks handed to it directly, so use its slack:// link,
        // falling back to the permalink (which opens via the browser) if it can't be built.
        NSWorkspace.shared.open(slackAppLink(item.permalink) ?? item.permalink)
        // Keep the first time you opened it, so a reply sent before a second click still counts.
        if (acks["slack:" + item.id] ?? 0) < item.ts * 1000 {
            acks["slack:" + item.id] = Date().timeIntervalSince1970 * 1000
            saveAcks()
        }
        refresh()
    }

    /// https://<domain>.slack.com/archives/<channel>/p<ts digits>?thread_ts=<ts>
    ///   → slack://channel?team=<id>&id=<channel>&message=<ts>&thread_ts=<ts>
    private func slackAppLink(_ permalink: URL) -> URL? {
        guard let host = permalink.host, host.hasSuffix(".slack.com"),
              let team = slackTeams[String(host.dropLast(".slack.com".count))] else { return nil }
        let parts = permalink.pathComponents
        guard parts.count >= 4, parts[1] == "archives", parts[3].hasPrefix("p") else { return nil }
        let digits = parts[3].dropFirst()
        guard digits.count > 6, digits.allSatisfy(\.isNumber) else { return nil }
        let ts = "\(digits.dropLast(6)).\(digits.suffix(6))"
        var link = URLComponents(string: "slack://channel")!
        link.queryItems = [URLQueryItem(name: "team", value: team), URLQueryItem(name: "id", value: parts[2]),
                           URLQueryItem(name: "message", value: ts)]
        if let thread = URLComponents(url: permalink, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "thread_ts" })?.value {
            link.queryItems?.append(URLQueryItem(name: "thread_ts", value: thread))
        }
        link.queryItems?.append(URLQueryItem(name: "host", value: "slack.com"))
        return link.url
    }

    /// Workspace domain → team id, from the Slack app's own state file.
    private lazy var slackTeams: [String: String] = {
        let url = home.appendingPathComponent("Library/Application Support/Slack/storage/root-state.json")
        guard let data = try? Data(contentsOf: url),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var map: [String: String] = [:]
        for key in ["teams", "workspaces"] {
            for (id, t) in (j[key] as? [String: Any]) ?? [:] {
                if let domain = (t as? [String: Any])?["domain"] as? String { map[domain] = id }
            }
        }
        return map
    }()

    /// Closes items you've answered since the last scan, so they don't wait hours for it.
    /// - A reply in the item's own thread always counts.
    /// - A message in the DM or channel counts only if you opened the item from here first: in a busy
    ///   DM you often write about other things, so that alone doesn't mean you answered.
    private func markSlackReplies() {
        var changed = false
        for item in slackParsed where (acks["slack-replied:" + item.id] ?? 0) <= item.ts * 1000 {
            let parts = item.id.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let (channel, threadTs) = (parts[0], parts[1])
            var reply = slackSends["\(channel)-\(threadTs)"].flatMap { $0 > item.ts ? $0 : nil }
            if reply == nil, let opened = acks["slack:" + item.id].map({ $0 / 1000 }), opened >= item.ts,
               let sent = slackSends[channel], sent > opened {
                reply = sent
            }
            if let reply {
                acks["slack-replied:" + item.id] = reply * 1000
                changed = true
            }
        }
        if changed { saveAcks() }
    }

    /// Follows the Slack app's console log, which records every message you send with
    /// "Clearing a local draft - <channel>[-<thread ts>] (reason: …:sendMessage)".
    /// Only messages sent from the Slack app on this Mac show up here; the scan catches the rest.
    private func loadSlackSends() {
        let dir = home.appendingPathComponent("Library/Application Support/Slack/logs/default")
        let current = dir.appendingPathComponent("webapp-console.log")
        guard let attrs = try? fm.attributesOfItem(atPath: current.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let file = (attrs[.systemFileNumber] as? NSNumber)?.intValue else { return }
        if file != slackLogFile || size < slackLogOffset {
            // First run, or Slack rotated the log (the old one becomes webapp-console1.log).
            if slackLogFile == nil || file != slackLogFile {
                parseSlackLog(dir.appendingPathComponent("webapp-console1.log"), from: 0)
            }
            slackLogFile = file
            slackLogOffset = 0
        }
        guard size > slackLogOffset else { return }
        slackLogOffset = parseSlackLog(current, from: slackLogOffset)
    }

    private static let sendLine = try! NSRegularExpression(
        pattern: #"^\[([0-9/]+, [0-9:]+)\].*Clearing a local draft - ([A-Z0-9]+(?:-[0-9]+\.[0-9]+)?) \(reason: \w+:sendMessage\)"#)
    private static let logDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM/dd/yy, HH:mm:ss:SSS"
        return f
    }()

    /// Reads whole lines from `offset` and returns the offset just past the last one read.
    @discardableResult
    private func parseSlackLog(_ url: URL, from offset: UInt64) -> UInt64 {
        guard let h = try? FileHandle(forReadingFrom: url) else { return offset }
        defer { try? h.close() }
        try? h.seek(toOffset: offset)
        guard let data = try? h.readToEnd(), let end = data.lastIndex(of: UInt8(ascii: "\n")) else { return offset }
        let text = String(decoding: data[..<end], as: UTF8.self)
        for line in text.split(separator: "\n") where line.contains("Clearing a local draft") {
            let l = String(line)
            guard let m = Self.sendLine.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)),
                  let d = Range(m.range(at: 1), in: l).flatMap({ Self.logDate.date(from: String(l[$0])) }),
                  let k = Range(m.range(at: 2), in: l).map({ String(l[$0]) }) else { continue }
            slackSends[k] = max(slackSends[k] ?? 0, d.timeIntervalSince1970)
        }
        return offset + UInt64(end - data.startIndex) + 1
    }

    // MARK: Slack refresh

    private static let slackReadTools = ["slack_search_public_and_private", "slack_read_thread", "slack_read_channel"]
        .map { "mcp__claude_ai_Slack__" + $0 }
    private static let slackWriteTools = ["slack_send_message", "slack_send_message_draft", "slack_schedule_message",
                                          "slack_create_canvas", "slack_update_canvas"].map { "mcp__claude_ai_Slack__" + $0 }

    /// Runs the same scan as the scheduled task right now, through the `claude` CLI and your Slack
    /// connector. It can only search and read Slack: no file, shell or posting tools. It prints the
    /// JSON and this app writes slack.json itself.
    func refreshSlack(done: (() -> Void)? = nil) {
        guard !slackRefreshing else { return }
        let fm = self.fm
        // Homebrew's first: an install that no longer auto-updates can linger in ~/.local/bin, and older
        // CLIs don't load claude.ai connectors such as Slack.
        let cli = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", home.appendingPathComponent(".local/bin/claude").path]
        let task = home.appendingPathComponent(".claude/scheduled-tasks/\(Self.slackTaskId)/SKILL.md")
        let folder = home.appendingPathComponent("Library/Application Support/ClaudePeek")
        let out = folder.appendingPathComponent("slack.json")
        guard let claude = cli.first(where: fm.isExecutableFile(atPath:)),
              var prompt = try? String(contentsOf: task, encoding: .utf8) else {
            slackRefreshFailed = true
            done?()
            return
        }
        // Drop the skill's front matter; the body is the scan instructions.
        if prompt.hasPrefix("---"), let end = prompt.range(of: "\n---", range: prompt.index(prompt.startIndex, offsetBy: 3)..<prompt.endIndex) {
            prompt = String(prompt[end.upperBound...])
        }
        let previous = (try? String(contentsOf: out, encoding: .utf8)) ?? "{}"
        prompt += """


        ## This run
        This is an on-demand refresh started from Claude Peek. You have no file or shell tools: skip reading \
        and writing the file. Its current contents, the "previous list", are below. Now is \(ISO8601DateFormatter().string(from: Date())).

        ```json
        \(previous)
        ```

        Instead of writing the file, reply with ONLY the JSON object {"scannedAt": ..., "items": [...]}: \
        no other text, no code fence, no summary line.
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.currentDirectoryURL = folder
        process.arguments = ["-p", prompt, "--model", "sonnet", "--output-format", "json", "--no-session-persistence",
                             "--tools", "ToolSearch",
                             "--allowedTools"] + Self.slackReadTools + ["--disallowedTools"] + Self.slackWriteTools
        if ProcessInfo.processInfo.environment["PEEK_SCAN_TRACE"] != nil {   // full trace in slack-refresh-error.log
            process.arguments = process.arguments!.map { $0 == "json" ? "stream-json" : $0 } + ["--verbose"]
        }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(home.path)/.local/bin:/usr/bin:/bin"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice   // otherwise the CLI waits for piped input
        do { try fm.createDirectory(at: folder, withIntermediateDirectories: true); try process.run() } catch {
            slackRefreshFailed = true
            done?()
            return
        }
        slackRefreshing = true
        slackRefreshFailed = false
        slackScanPid = process.processIdentifier
        onChange?()
        // A scan normally takes a minute or two; give up after ten.
        DispatchQueue.global().asyncAfter(deadline: .now() + 600) { if process.isRunning { process.terminate() } }

        DispatchQueue.global().async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let ok = Self.writeScan(data, to: out)
            // Keep the last failed reply next to slack.json for troubleshooting.
            let log = out.deletingLastPathComponent().appendingPathComponent("slack-refresh-error.log")
            if ok { try? FileManager.default.removeItem(at: log) } else { try? data.write(to: log) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.slackRefreshing = false
                    self.slackRefreshFailed = !ok
                    self.slackScanPid = nil
                    self.refresh()
                    self.onChange?()
                    done?()
                }
            }
        }
    }

    /// Pulls the JSON object out of the CLI's reply and moves it into place in one step.
    nonisolated private static func writeScan(_ data: Data, to out: URL) -> Bool {
        guard let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              reply["is_error"] as? Bool != true,
              let text = reply["result"] as? String,
              let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              var scan = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
              scan["items"] is [Any] else { return false }
        if scan["scannedAt"] == nil { scan["scannedAt"] = ISO8601DateFormatter().string(from: Date()) }
        let tmp = out.appendingPathExtension("tmp")
        guard let json = try? JSONSerialization.data(withJSONObject: scan, options: [.prettyPrinted]),
              (try? json.write(to: tmp)) != nil else { return false }
        return rename(tmp.path, out.path) == 0
    }

    private func loadSlack() {
        let url = home.appendingPathComponent("Library/Application Support/ClaudePeek/slack.json")
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard mtime != slackMtime else { return }
        slackMtime = mtime
        guard let data = try? Data(contentsOf: url),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            slackParsed = []
            slackScannedAt = nil
            return
        }
        slackScannedAt = (j["scannedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        slackParsed = ((j["items"] as? [[String: Any]]) ?? []).compactMap { o in
            guard let id = o["id"] as? String,
                  let link = (o["permalink"] as? String).flatMap(URL.init(string:)),
                  let ts = (o["ts"] as? String).flatMap(Double.init) ?? (o["ts"] as? NSNumber)?.doubleValue
            else { return nil }
            let kind = o["kind"] as? String ?? "request"
            return SlackItem(id: id, from: o["from"] as? String ?? "", place: o["where"] as? String ?? "",
                             summary: o["summary"] as? String ?? "", kind: kind,
                             priority: SlackPriority(o["priority"] as? String, kind: kind), ts: ts, permalink: link)
        }
        // Most urgent first; within a tier, whoever has waited longest.
        slackParsed.sort { ($0.priority, $0.ts) < ($1.priority, $1.ts) }
    }

    func markRead(_ s: Session) {
        // Scheduled runs share a title; acknowledge every unread run of the group.
        let desktop = desktopCache.values.map(\.1)
        let siblings = desktop.filter { $0.title == s.title && $0.scheduledTaskId != nil }.map(\.cliId)
        for id in [s.id] + siblings { acks[id] = max(s.readEdge, Date().timeIntervalSince1970 * 1000) }
        saveAcks()
        refresh()
    }

    func open(_ s: Session) {
        // The same link the app's Dock menu uses to jump straight to a Code session.
        if s.source == .app, let id = s.appSessionId, id.hasPrefix("local_"),
           let url = URL(string: "claude://code/continue?session=\(id)") {
            NSWorkspace.shared.open(url)
        } else if s.source == .app {
            let id = "com.anthropic.claudefordesktop"
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                app.activate()
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            }
        } else if let pid = s.pid, let app = owningApp(of: pid) {
            app.activate()
        }
        markRead(s)
    }

    private func saveAcks() {
        try? fm.createDirectory(at: acksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Drop acks older than 30 days so the file stays small.
        let cutoff = Date().timeIntervalSince1970 * 1000 - 30 * 24 * 3600 * 1000
        acks = acks.filter { $0.value > cutoff }
        if let data = try? JSONEncoder().encode(acks) { try? data.write(to: acksURL) }
    }

    // MARK: Loading

    private func loadLive() -> [LiveProcess] {
        let dir = home.appendingPathComponent(".claude/sessions")
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (j["pid"] as? NSNumber)?.int32Value,
                  let sid = j["sessionId"] as? String,
                  pid != slackScanPid,   // the refresh button's own scan
                  isAlive(pid) else { return nil }
            return LiveProcess(
                pid: pid, sessionId: sid, cwd: j["cwd"] as? String ?? "",
                name: j["name"] as? String, status: j["status"] as? String ?? "idle",
                waitingFor: j["waitingFor"] as? String, entrypoint: j["entrypoint"] as? String ?? "cli",
                statusUpdatedAt: (j["statusUpdatedAt"] as? NSNumber)?.doubleValue
                    ?? (j["updatedAt"] as? NSNumber)?.doubleValue ?? 0)
        }
    }

    private func loadDesktop() -> [String: DesktopRecord] {
        let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        var result: [String: DesktopRecord] = [:]
        for url in sessionFiles(under: root) {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let record: DesktopRecord
            if let (cachedAt, cached) = desktopCache[url.path], cachedAt == mtime {
                record = cached
            } else {
                guard let data = try? Data(contentsOf: url),
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let cli = j["cliSessionId"] as? String else { continue }
                record = DesktopRecord(
                    cliId: cli, localId: j["sessionId"] as? String ?? "",
                    title: j["title"] as? String ?? "Untitled", cwd: j["cwd"] as? String ?? "",
                    archived: j["isArchived"] as? Bool ?? false,
                    focusedAt: (j["lastFocusedAt"] as? NSNumber)?.doubleValue ?? 0,
                    turnEdgeAt: (j["lastTurnEdgeAt"] as? NSNumber)?.doubleValue
                        ?? (j["lastActivityAt"] as? NSNumber)?.doubleValue ?? 0,
                    awaitingPerson: !(j["interruptedAwaitingPerson"] is NSNull) && j["interruptedAwaitingPerson"] != nil,
                    scheduledTaskId: j["scheduledTaskId"] as? String)
                desktopCache[url.path] = (mtime, record)
            }
            result[record.cliId] = record
        }
        return result
    }

    /// local_*.json files two levels below the desktop app's sessions folder (account/org/file).
    private func sessionFiles(under root: URL) -> [URL] {
        var out: [URL] = []
        for a in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for b in (try? fm.contentsOfDirectory(at: a, includingPropertiesForKeys: nil)) ?? [] {
                for f in (try? fm.contentsOfDirectory(at: b, includingPropertiesForKeys: nil)) ?? []
                where f.lastPathComponent.hasPrefix("local_") && f.pathExtension == "json" {
                    out.append(f)
                }
            }
        }
        return out
    }

    private func loadWaitingInput() -> [String] {
        let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        var names: [String] = []
        for a in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for b in (try? fm.contentsOfDirectory(at: a, includingPropertiesForKeys: nil)) ?? [] {
                names += (try? fm.contentsOfDirectory(atPath: b.appendingPathComponent("waiting-input").path)) ?? []
            }
        }
        return names
    }
}

// MARK: - Process helpers

private func isAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

private func parentPid(of pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let ppid = info.kp_eproc.e_ppid
    return ppid > 1 ? ppid : nil
}

/// Walks up the process tree to the GUI app hosting a terminal session (Terminal, iTerm, VS Code…).
private func owningApp(of pid: pid_t) -> NSRunningApplication? {
    var cur: pid_t? = pid
    while let p = cur {
        if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular { return app }
        cur = parentPid(of: p)
    }
    return nil
}

private func folderName(_ path: String) -> String {
    let name = (path as NSString).lastPathComponent
    return name.hasPrefix("scratch-") ? "No folder" : name
}

private func ago(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 60 { return "now" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

// MARK: - UI

enum IconStyle: String, CaseIterable, Identifiable {
    case spark, buddy, orbit, bars
    var id: String { rawValue }

    var name: String {
        switch self {
        case .spark: return "Spark"
        case .buddy: return "Buddy"
        case .orbit: return "Orbit"
        case .bars: return "Equalizer"
        }
    }
}

/// The overall state the icon expresses.
enum Mood {
    case working, waiting, idle

    var color: Color {
        switch self {
        case .working: return Activity.working.color
        case .waiting: return Activity.waiting.color
        case .idle: return .white.opacity(0.6)
        }
    }
}

extension SessionStore {
    var mood: Mood {
        if sessions.contains(where: { $0.activity == .waiting }) { return .waiting }
        if sessions.contains(where: { $0.activity == .working }) { return .working }
        return .idle
    }
}

enum PanelTab: String { case claude, slack }

@MainActor
final class UIState: ObservableObject {
    @Published var expanded = false
    /// The open tab; remembered across launches. Switching resizes the panel.
    @Published var tab = PanelTab(rawValue: UserDefaults.standard.string(forKey: "tab") ?? "") ?? .claude {
        didSet {
            UserDefaults.standard.set(tab.rawValue, forKey: "tab")
            onTabChange?()
        }
    }
    var onTabChange: (() -> Void)?
    @Published var style = IconStyle(rawValue: UserDefaults.standard.string(forKey: "iconStyle") ?? "") ?? .spark {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: "iconStyle") }
    }

    func cycleStyle() {
        let all = IconStyle.allCases
        style = all[((all.firstIndex(of: style) ?? 0) + 1) % all.count]
    }
}

/// Callbacks from the views back to the window controller.
struct PeekActions {
    var collapse: () -> Void = {}
    var hide: () -> Void = {}
    var quit: () -> Void = {}
    var resetPosition: () -> Void = {}
    var drag: (_ ended: Bool) -> Void = { _ in }
}

enum Metrics {
    static let pillHeight: CGFloat = 26
    static let icon: CGFloat = 16
    static let digit: CGFloat = 7
    static let width: CGFloat = 440
    static let header: CGFloat = 46
    static let sectionHeader: CGFloat = 26
    static let row: CGFloat = 46
    static let maxHeight: CGFloat = 560
    static let maxIdleRows = 6

    /// Icon, then the running count, then a dot and the unread count; grows with the digits.
    static func pill(running: Int, unread: Int, slack: Int = 0, blocked: Int = 0) -> CGSize {
        var w: CGFloat = 9 + icon + 9
        if running > 0 { w += 5 + digit * CGFloat(String(running).count) }
        if unread > 0 { w += 5 + 2 + 5 + 3 + digit * CGFloat(String(unread).count) }
        for n in [blocked, slack] where n > 0 { w += 5 + 2 + 9 + 3 + digit * CGFloat(String(n).count) }
        return CGSize(width: max(w.rounded(.up), 34), height: pillHeight)
    }

    @MainActor static func pill(_ store: SessionStore) -> CGSize {
        pill(running: store.working.count, unread: store.unread.count,
             slack: store.slackPending.count - store.slackBlocked, blocked: store.slackBlocked)
    }

    @MainActor static func expandedHeight(_ store: SessionStore, _ tab: PanelTab) -> CGFloat {
        let sections = tab == .slack
            ? SlackPriority.allCases.map { p in store.slack.filter { $0.priority == p }.count }
            : [store.working.count, store.unread.count, min(store.idle.count, maxIdleRows)]
        let body = sections.filter { $0 > 0 }.reduce(0) { $0 + sectionHeader + CGFloat($1) * row }
        return min(header + max(body, 56) + 12, maxHeight)
    }
}

// MARK: Icons

private func polar(_ c: CGPoint, _ angle: Double, _ d: CGFloat) -> CGPoint {
    CGPoint(x: c.x + cos(angle) * d, y: c.y + sin(angle) * d)
}

struct MoodIcon: View {
    let style: IconStyle
    let mood: Mood
    var size: CGFloat = Metrics.icon

    var body: some View {
        // Animates only while something is happening; idle icons are still (Buddy still blinks).
        let paused = mood == .idle && style != .buddy
        let interval = mood == .idle ? 1.0 / 12 : 1.0 / 30
        TimelineView(.animation(minimumInterval: interval, paused: paused)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, sz in
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
                let r = min(sz.width, sz.height) / 2
                switch style {
                case .spark: drawSpark(&ctx, c, r, t)
                case .buddy: drawBuddy(&ctx, c, r, t)
                case .orbit: drawOrbit(&ctx, c, r, t)
                case .bars: drawBars(&ctx, c, r, t)
                }
            }
        }
        .frame(width: size, height: size)
    }

    /// An eight-ray spark that turns slowly while working and breathes while waiting.
    private func drawSpark(_ ctx: inout GraphicsContext, _ c: CGPoint, _ r: CGFloat, _ t: Double) {
        let spin = mood == .working ? t * 1.9 : 0
        let breathe = mood == .waiting ? 1 + 0.12 * sin(t * 5) : 1
        for i in 0..<8 {
            let a = spin + Double(i) * .pi / 4
            let shimmer = mood == .working ? 0.14 * sin(t * 6 + Double(i)) : 0
            let outer = r * ((i % 2 == 0) ? 0.96 : 0.66 + shimmer) * breathe
            var p = Path()
            p.move(to: polar(c, a, r * 0.2))
            p.addLine(to: polar(c, a, outer))
            ctx.stroke(p, with: .color(mood.color), style: StrokeStyle(lineWidth: r * 0.26, lineCap: .round))
        }
    }

    /// A little face: glances around while working, looks up wide-eyed when it needs you, blinks when idle.
    private func drawBuddy(_ ctx: inout GraphicsContext, _ c: CGPoint, _ r: CGFloat, _ t: Double) {
        let ink = Color(white: 0.08)
        let bob = mood == .waiting ? sin(t * 6) * r * 0.08 : 0
        let face = CGRect(x: c.x - r, y: c.y - r + bob, width: 2 * r, height: 2 * r)
        ctx.fill(Path(ellipseIn: face), with: .color(mood == .idle ? Color(white: 0.78) : mood.color))

        let blink = t.truncatingRemainder(dividingBy: 4.2) < 0.14
        let look = mood == .working ? sin(t * 1.8) * r * 0.16 : 0
        let eyeW = r * (mood == .waiting ? 0.27 : 0.21)
        let eyeH = blink ? r * 0.07 : r * (mood == .waiting ? 0.38 : 0.3)
        for dx in [-0.36, 0.36] {
            let eye = CGRect(x: c.x + dx * r + look - eyeW / 2, y: c.y - r * 0.14 + bob - eyeH / 2, width: eyeW, height: eyeH)
            ctx.fill(Path(roundedRect: eye, cornerRadius: eyeW / 2), with: .color(ink))
        }

        let mouthY = c.y + r * 0.3 + bob
        if mood == .waiting {
            let o = CGRect(x: c.x - r * 0.12, y: mouthY - r * 0.06, width: r * 0.24, height: r * 0.26)
            ctx.stroke(Path(ellipseIn: o), with: .color(ink), lineWidth: r * 0.12)
        } else {
            var smile = Path()
            smile.move(to: CGPoint(x: c.x - r * 0.38 + look * 0.5, y: mouthY))
            smile.addQuadCurve(to: CGPoint(x: c.x + r * 0.38 + look * 0.5, y: mouthY),
                               control: CGPoint(x: c.x + look * 0.5, y: mouthY + r * (mood == .working ? 0.26 : 0.4)))
            ctx.stroke(smile, with: .color(ink), style: StrokeStyle(lineWidth: r * 0.13, lineCap: .round))
        }
    }

    /// A core with a moon that orbits (with a short comet tail) while working.
    private func drawOrbit(_ ctx: inout GraphicsContext, _ c: CGPoint, _ r: CGFloat, _ t: Double) {
        let ringR = r * 0.74
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - ringR, y: c.y - ringR, width: 2 * ringR, height: 2 * ringR)),
                   with: .color(mood.color.opacity(0.35)), lineWidth: r * 0.1)
        let pulse = mood == .waiting ? 1 + 0.25 * sin(t * 6) : 1
        let coreR = r * 0.3 * pulse
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - coreR, y: c.y - coreR, width: 2 * coreR, height: 2 * coreR)),
                 with: .color(mood.color))
        let angle = mood == .working ? t * 4.2 : -.pi / 4
        let tail = mood == .working ? 4 : 1
        for k in 0..<tail {
            let a = angle - Double(k) * 0.32
            let dotR = r * 0.21 * (1 - CGFloat(k) * 0.2)
            let p = polar(c, a, ringR)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - dotR, y: p.y - dotR, width: 2 * dotR, height: 2 * dotR)),
                     with: .color(mood.color.opacity(1 - Double(k) * 0.28)))
        }
    }

    /// Four bars that dance while working, hold and pulse while waiting, and rest when idle.
    private func drawBars(_ ctx: inout GraphicsContext, _ c: CGPoint, _ r: CGFloat, _ t: Double) {
        let n = 4
        let w = r * 0.32
        let gap = (2 * r - CGFloat(n) * w) / CGFloat(n - 1)
        let rest: [CGFloat] = [0.4, 0.7, 0.55, 0.35]
        for i in 0..<n {
            let h: CGFloat
            switch mood {
            case .working: h = 0.3 + 0.7 * abs(sin(t * (3.1 + Double(i) * 0.7) + Double(i) * 1.3))
            case .waiting: h = 0.6
            case .idle: h = rest[i]
            }
            let height = 2 * r * h
            let rect = CGRect(x: c.x - r + CGFloat(i) * (w + gap), y: c.y - height / 2, width: w, height: height)
            let alpha = mood == .waiting ? 0.65 + 0.35 * sin(t * 6 + Double(i)) : 1
            ctx.fill(Path(roundedRect: rect, cornerRadius: w / 2), with: .color(mood.color.opacity(alpha)))
        }
    }
}

struct PulsingDot: View {
    let color: Color
    let pulse: Bool
    @State private var on = false

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .overlay(Circle().stroke(color.opacity(0.6), lineWidth: 2).scaleEffect(on ? 2.1 : 1).opacity(on ? 0 : 0.9))
            .onAppear {
                guard pulse else { return }
                withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { on = true }
            }
    }
}

/// Icon + running count + unread count. No words.
struct PillContent: View {
    let style: IconStyle
    let mood: Mood
    let running: Int
    let unread: Int
    var slack = 0
    var blocked = 0   // Slack items where someone is stuck on you, drawn in red ahead of the rest

    var body: some View {
        HStack(spacing: 5) {
            MoodIcon(style: style, mood: mood)
            if running > 0 {
                Text("\(running)").foregroundStyle(mood.color)
            }
            if unread > 0 {
                HStack(spacing: 3) {
                    Circle().fill(Activity.unread.color).frame(width: 5, height: 5)
                    Text("\(unread)").foregroundStyle(Activity.unread.color)
                }
                .padding(.leading, 2)
            }
            ForEach([(blocked, urgentColor, "exclamationmark.bubble.fill"), (slack, slackColor, "bubble.left.fill")],
                    id: \.2) { n, color, symbol in
                if n > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: symbol).font(.system(size: 8.5, weight: .bold))
                        Text("\(n)")
                    }
                    .foregroundStyle(color)
                    .padding(.leading, 2)
                }
            }
        }
        .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PillView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: UIState

    var body: some View {
        PillContent(style: ui.style, mood: store.mood, running: store.working.count, unread: store.unread.count,
                    slack: store.slackPending.count - store.slackBlocked, blocked: store.slackBlocked)
            .frame(height: Metrics.pillHeight)
    }
}

extension View {
    /// Dragging moves the whole panel. Uses screen coordinates so the moving window doesn't cause jitter.
    func movesWindow(_ actions: PeekActions) -> some View {
        gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { _ in actions.drag(false) }
            .onEnded { _ in actions.drag(true) })
    }

    func peekMenu(_ ui: UIState, _ actions: PeekActions) -> some View {
        contextMenu {
            ForEach(IconStyle.allCases) { s in
                Button { ui.style = s } label: {
                    if ui.style == s { Label(s.name, systemImage: "checkmark") } else { Text(s.name) }
                }
            }
            Divider()
            Button("Reset position", action: actions.resetPosition)
            Button("Hide for 30 minutes", action: actions.hide)
            Button("Quit until next login", action: actions.quit)
        }
    }
}

struct RowView: View {
    let session: Session
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: session.source == .app ? "macwindow" : "terminal")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.system(size: 12.5, weight: session.activity == .idle ? .regular : .semibold))
                        .foregroundStyle(.white.opacity(session.activity == .idle ? 0.6 : 0.95))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                HStack(spacing: 5) {
                    PulsingDot(color: session.activity.color,
                               pulse: session.activity == .working || session.activity == .waiting)
                    Text(session.activity.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(session.activity.color)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: Metrics.row - 4)
            .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(hover ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(session.source == .app ? "Open in Claude and mark read" : "Focus terminal and mark read")
    }

    private var subtitle: String {
        var parts = [session.source == .app ? "App" : "Terminal", session.folder, ago(session.updated)]
        if let note = session.note { parts.append(note) }
        return parts.joined(separator: " · ")
    }
}

struct SlackRow: View {
    let item: SlackItem
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(item.color.opacity(item.pending ? 1 : 0.5))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.summary)
                        .font(.system(size: 12.5, weight: item.pending ? .semibold : .regular))
                        .foregroundStyle(.white.opacity(item.pending ? 0.95 : 0.6))
                        .lineLimit(1)
                    Text([item.from, item.place, ago(Date(timeIntervalSince1970: item.ts))]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                // Opening doesn't clear something that still needs a reply, so it keeps its colour.
                Text(!item.seen ? item.priority.action : item.pending ? "Opened · \(item.priority.action.lowercased())" : "Read")
                    .font(.system(size: 11, weight: item.priority == .blocked ? .bold : .medium))
                    .foregroundStyle(item.pending ? item.priority.color.opacity(item.seen ? 0.7 : 1) : .white.opacity(0.4))
            }
            .padding(.horizontal, 10)
            .frame(height: Metrics.row - 4)
            .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(hover ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Open this thread in Slack")
    }
}

struct ExpandedView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: UIState
    var scrollable = true
    let actions: PeekActions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                MoodIcon(style: ui.style, mood: store.mood)
                    .onTapGesture { ui.cycleStyle() }
                    .help("Click to change icon")
                    .padding(.trailing, 2)
                TabButton(title: "Claude", selected: ui.tab == .claude, counts: [
                    (store.working.count, store.mood.color), (store.unread.count, Activity.unread.color),
                ]) { ui.tab = .claude }
                TabButton(title: "Slack", selected: ui.tab == .slack, counts: [
                    (store.slackBlocked, urgentColor), (store.slackPending.count - store.slackBlocked, slackColor),
                ]) { ui.tab = .slack }
                Spacer()
                if ui.tab == .slack {
                    if store.slackRefreshing {
                        ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 24, height: 24)
                            .help("Checking Slack now…")
                    } else {
                        IconButton(symbol: "arrow.clockwise", help: "Check Slack now") { store.refreshSlack() }
                    }
                }
                IconButton(symbol: "xmark", help: "Close the panel", action: actions.collapse)
            }
            .padding(.horizontal, 14)
            .frame(height: Metrics.header)
            .contentShape(Rectangle())
            .movesWindow(actions)
            .peekMenu(ui, actions)

            if scrollable {
                ScrollView { list }.scrollIndicators(.never)
            } else {
                list
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if ui.tab == .slack {
                if !store.slack.isEmpty {
                    let groups = SlackPriority.allCases.map { p in (p, store.slack.filter { $0.priority == p }) }
                    ForEach(groups.filter { !$0.1.isEmpty }, id: \.0) { p, items in
                        let checked = p == groups.first { !$0.1.isEmpty }?.0
                        sectionTitle(p.title + (checked ? store.slackChecked.map { " · " + $0 } ?? "" : ""),
                                     color: p.color)
                        ForEach(items) { item in
                            SlackRow(item: item) { store.openSlack(item) }
                                .frame(height: Metrics.row)
                        }
                    }
                } else {
                    emptyState(store.slackChecked.map { "Nobody is waiting on you · " + $0 }
                               ?? "No scan yet · tap ↻ or wait for 9am, 1pm, 5pm, 9pm or 1am")
                }
            } else {
                section("Running", store.working)
                section("Unread", store.unread)
                section("Open, idle", Array(store.idle.prefix(Metrics.maxIdleRows)))
                if store.sessions.isEmpty {
                    emptyState("No Claude Code sessions right now.")
                }
            }
        }
        .padding(.horizontal, 6)
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity, minHeight: 50)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [Session]) -> some View {
        if !items.isEmpty {
            sectionTitle(title)
            ForEach(items) { s in
                RowView(session: s) { store.open(s) }
                    .frame(height: Metrics.row)
            }
        }
    }
}

/// A header tab: its name plus small coloured counts (zero counts are hidden).
struct TabButton: View {
    let title: String
    let selected: Bool
    let counts: [(Int, Color)]
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(selected ? 0.95 : 0.55))
                ForEach(Array(counts.enumerated()), id: \.offset) { _, c in
                    if c.0 > 0 {
                        Text("\(c.0)")
                            .font(.system(size: 10.5, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(c.1)
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(.white.opacity(selected ? 0.13 : (hover ? 0.06 : 0))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private func sectionTitle(_ title: String, color: Color? = nil) -> some View {
    Text(title.uppercased())
        .font(.system(size: 10, weight: .semibold))
        .tracking(0.6)
        .foregroundStyle(color.map { $0.opacity(0.85) } ?? .white.opacity(0.4))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: Metrics.sectionHeader, alignment: .bottomLeading)
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(hover ? 0.95 : 0.6))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(hover ? 0.12 : 0.06)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct OverlayView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: UIState
    var scrollable = true
    let actions: PeekActions

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ui.expanded ? 18 : Metrics.pillHeight / 2, style: .continuous)
        ZStack(alignment: .top) {
            shape.fill(Color(white: 0.07).opacity(0.94))
            shape.strokeBorder(.white.opacity(0.09), lineWidth: 1)
            if ui.expanded {
                ExpandedView(store: store, ui: ui, scrollable: scrollable, actions: actions)
            } else {
                PillView(store: store, ui: ui)
                    .contentShape(Rectangle())
                    .movesWindow(actions)
                    .peekMenu(ui, actions)
            }
        }
        .clipShape(shape)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Window

final class OverlayPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 34, height: Metrics.pillHeight),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        // The key line: excluded from screenshots, screen recording and screen sharing.
        sharingType = .none
    }

    override var canBecomeKey: Bool { true }
}

final class HoverHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private let ui = UIState()
    private let panel = OverlayPanel()
    private var collapse: DispatchWorkItem?
    /// Top-centre of the pill in screen coordinates. Saved across launches.
    private var anchor = CGPoint.zero
    private var dragStart: (mouse: CGPoint, anchor: CGPoint)?

    func applicationDidFinishLaunching(_ note: Notification) {
        anchor = savedAnchor() ?? defaultAnchor()
        let actions = PeekActions(
            collapse: { [weak self] in self?.collapsePanel() },
            hide: { [weak self] in self?.hide() },
            quit: { AppDelegate.quitUntilLogin() },
            resetPosition: { [weak self] in self?.resetPosition() },
            drag: { [weak self] ended in self?.drag(ended: ended) })
        let host = HoverHostingView(rootView: OverlayView(store: store, ui: ui, actions: actions))
        host.sizingOptions = []
        host.onHover = { [weak self] inside in self?.hover(inside) }
        panel.contentView = host

        ui.onTabChange = { [weak self] in self?.layout(animated: true) }
        // Counts change the pill's width, so re-layout on every change.
        store.onChange = { [weak self] in
            guard let self else { return }
            self.layout(animated: self.ui.expanded)
        }
        store.start()
        layout(animated: false)
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout(animated: false) }
        }
    }

    private func hover(_ inside: Bool) {
        collapse?.cancel()
        if inside {
            guard !ui.expanded, !holdCollapsed else { return }
            ui.expanded = true
            layout(animated: true)
        } else {
            holdCollapsed = false
            scheduleCollapse()
        }
    }

    /// × shrinks back to the pill, which always stays on screen. The pointer is still over it, so
    /// don't re-expand until it has left once.
    private var holdCollapsed = false
    private func collapsePanel() {
        collapse?.cancel()
        holdCollapsed = true
        ui.expanded = false
        layout(animated: true)
    }

    /// Opening Claude Peek again (Spotlight, Finder, `open`) while it's running brings the pill back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        unhide?.cancel()
        layout(animated: false)
        panel.orderFrontRegardless()
        return false
    }

    /// Collapses shortly after the pointer leaves, but not while dragging, while a menu is open,
    /// or if the pointer has come back.
    private func scheduleCollapse() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.ui.expanded else { return }
            let busy = self.dragStart != nil || RunLoop.main.currentMode == .eventTracking
            if busy { self.scheduleCollapse(); return }
            if self.panel.frame.contains(NSEvent.mouseLocation) { return }
            self.ui.expanded = false
            self.layout(animated: true)
        }
        collapse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func drag(ended: Bool) {
        let mouse = NSEvent.mouseLocation
        let start = dragStart ?? (mouse, anchor)
        dragStart = start
        anchor = CGPoint(x: start.anchor.x + mouse.x - start.mouse.x, y: start.anchor.y + mouse.y - start.mouse.y)
        layout(animated: false)
        if ended {
            dragStart = nil
            anchor = clamped(anchor)
            UserDefaults.standard.set([anchor.x, anchor.y], forKey: "anchor")
            layout(animated: false)
        }
    }

    /// "Hide for 30 minutes": takes the pill off screen; it returns by itself, on reopen, or on restart.
    private var unhide: DispatchWorkItem?
    private func hide() {
        ui.expanded = false
        panel.orderOut(nil)
        unhide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.layout(animated: false)
            self.panel.orderFrontRegardless()
        }
        unhide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30 * 60, execute: work)
    }

    /// Stops the login service for this session. It starts again at the next login, or when you
    /// open Claude Peek from ~/Applications (see `rejoinLoginService`). Outside the service, as with
    /// `./build.sh --run`, it just quits.
    static func quitUntilLogin() {
        if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == "local.claudepeek" {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["bootout", "gui/\(getuid())/local.claudepeek"]
            try? p.run()
            p.waitUntilExit()
        }
        NSApp.terminate(nil)
    }

    /// Opened by hand from the installed copy while its login service is stopped ("Quit until next
    /// login"): hand over to the service, which starts the app and keeps it running.
    static func rejoinLoginService() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let installed = home.appendingPathComponent("Applications/ClaudePeek.app").standardizedFileURL.path
        let agent = home.appendingPathComponent("Library/LaunchAgents/local.claudepeek.plist").path
        guard ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != "local.claudepeek",
              Bundle.main.bundleURL.standardizedFileURL.path == installed,
              FileManager.default.fileExists(atPath: agent) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootstrap", "gui/\(getuid())", agent]
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0   // non-zero: already loaded, so keep running as we are
    }

    private func resetPosition() {
        anchor = defaultAnchor()
        UserDefaults.standard.removeObject(forKey: "anchor")
        layout(animated: true)
    }

    private func defaultAnchor() -> CGPoint {
        // Screen 0 has the menu bar; sit just under it, centred.
        guard let screen = NSScreen.screens.first else { return .zero }
        return CGPoint(x: screen.frame.midX, y: screen.visibleFrame.maxY - 6)
    }

    private func savedAnchor() -> CGPoint? {
        guard let xy = UserDefaults.standard.array(forKey: "anchor") as? [Double], xy.count == 2 else { return nil }
        let p = CGPoint(x: xy[0], y: xy[1])
        return screen(for: p) == nil ? nil : p
    }

    private func screen(for p: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.insetBy(dx: -2, dy: -2).contains(p) }
    }

    /// Keeps the pill fully on whichever screen it was dropped on.
    private func clamped(_ p: CGPoint) -> CGPoint {
        guard let s = screen(for: p) ?? NSScreen.screens.first else { return p }
        let pill = Metrics.pill(store)
        return CGPoint(x: min(max(p.x, s.frame.minX + pill.width / 2), s.frame.maxX - pill.width / 2),
                       y: min(max(p.y, s.frame.minY + pill.height), s.frame.maxY))
    }

    private func layout(animated: Bool) {
        let size = ui.expanded
            ? CGSize(width: Metrics.width, height: Metrics.expandedHeight(store, ui.tab))
            : Metrics.pill(store)
        guard let screen = screen(for: anchor) ?? NSScreen.screens.first else { return }
        let bounds = screen.frame
        // Hang below the anchor; slide sideways or up if the panel would run off the screen.
        let x = min(max(anchor.x - size.width / 2, bounds.minX + 4), bounds.maxX - size.width - 4)
        let y = min(max(anchor.y - size.height, screen.visibleFrame.minY + 4), bounds.maxY - size.height)
        let frame = NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
        guard frame != panel.frame else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }
}

// MARK: - Snapshots

@MainActor private func writePNG<V: View>(_ view: V, to url: URL, scale: CGFloat = 2) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        try? png.write(to: url)
    }
}

/// `ClaudePeek --snapshot <dir>` renders the live pill, the expanded panel, and a sheet of
/// every icon style in every state to PNGs, then exits.
@MainActor func snapshot(to dir: String) {
    let base = URL(fileURLWithPath: dir)
    let store = SessionStore()
    store.refresh()
    let savedTab = UserDefaults.standard.string(forKey: "tab")
    defer { UserDefaults.standard.set(savedTab, forKey: "tab") }
    for (name, tab) in [("pill", nil), ("expanded-claude", PanelTab.claude), ("expanded-slack", .slack)] {
        let ui = UIState()
        ui.expanded = tab != nil
        if let tab { ui.tab = tab }
        let size = tab.map { CGSize(width: Metrics.width, height: Metrics.expandedHeight(store, $0)) } ?? Metrics.pill(store)
        writePNG(OverlayView(store: store, ui: ui, scrollable: false, actions: PeekActions())
                    .frame(width: size.width, height: size.height),
                 to: base.appendingPathComponent(name + ".png"))
    }

    let states: [(String, Mood, Int, Int, Int)] = [
        ("Working", .working, 3, 12, 2), ("Needs you", .waiting, 1, 100, 0), ("Idle", .idle, 0, 4, 5), ("All quiet", .idle, 0, 0, 0),
    ]
    let sheet = VStack(alignment: .leading, spacing: 14) {
        ForEach(IconStyle.allCases) { style in
            HStack(spacing: 18) {
                Text(style.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).frame(width: 74, alignment: .leading)
                MoodIcon(style: style, mood: .working, size: 34)
                ForEach(states, id: \.0) { _, mood, running, unread, slack in
                    let size = Metrics.pill(running: running, unread: unread, slack: slack)
                    PillContent(style: style, mood: mood, running: running, unread: unread, slack: slack)
                        .frame(width: size.width, height: size.height)
                        .background(Capsule().fill(Color(white: 0.07)))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                        .frame(width: 120)
                }
            }
        }
        HStack(spacing: 18) {
            Color.clear.frame(width: 74 + 34, height: 1)
            ForEach(states, id: \.0) { label, _, _, _, _ in
                Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).frame(width: 120)
            }
        }
    }
    .padding(20)
    .background(Color(white: 0.16))
    .environment(\.colorScheme, .dark)
    writePNG(sheet, to: base.appendingPathComponent("icons.png"), scale: 3)
}

MainActor.assumeIsolated {
    if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
        snapshot(to: CommandLine.arguments[i + 1])
        exit(0)
    }
    if CommandLine.arguments.contains("--refresh-slack") {   // what the ↻ button does, without the UI
        let store = SessionStore()
        store.refreshSlack { print(store.slackRefreshFailed ? "failed" : "ok: \(store.slack.count) items"); exit(0) }
        RunLoop.main.run()
    }
    if AppDelegate.rejoinLoginService() { exit(0) }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // no Dock icon, no menu bar
    app.run()
}
