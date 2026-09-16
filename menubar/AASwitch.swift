// AA Switch（API / Account Switch）菜单栏小工具：点开右上角的 AA 图标，看到 Codex 和 Claude Code 各自的当前模式，点一下切换。
// 所有切换逻辑都在两个脚本里：~/.codex/codex-mode（Codex）和 ~/.claude/claude-mode（Claude Code），
// 本程序只负责安装脚本、调用和展示。
import AppKit
import CryptoKit
import Foundation

let bundleID = Bundle.main.bundleIdentifier ?? "local.aaswitch"
let appName = (Bundle.main.infoDictionary?["CFBundleName"] as? String) ?? "AA Switch"
let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"

// 一个被管理的产品：脚本在哪、数据目录在哪、菜单里怎么称呼两种模式
struct Product {
    let name: String            // 菜单里的分组标题
    let resource: String        // 包内脚本资源名（不含 .sh）
    let versionKey: String      // 脚本里的版本常量名
    let home: String            // 数据目录（脚本装在这里）
    let homeEnv: String         // 传给脚本的数据目录环境变量名
    let nonInteractiveEnv: String
    let accountWord: String     // 脚本里账号模式的词
    let accountTitle: String    // 菜单里账号模式的叫法
    let configureEnvPrefix: String  // 非交互配置的环境变量前缀
    let urlPlaceholder: String
    let urlHint: String
    var script: String { home + "/" + resource }
    var backups: String { home + "/" + resource + "-backups" }
}

// 菜单里的模式行：一个分段控件，每格等宽，选中的那格用强调色高亮，点另一格就切换。
// 菜单窗口永远不是 key window，系统控件在里面只会画成灰色的未激活样式，所以自己画
final class SegmentRow: NSView {
    static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    static func textWidth(_ s: String) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: font]).width) }
    private let labels: [String]
    private var selected: Int?
    private let enabled: Bool
    private let onSelect: (Int) -> Void
    private var rects: [NSRect] = []
    init(labels: [String], selected: Int?, enabled: Bool, segmentWidth: CGFloat, onSelect: @escaping (Int) -> Void) {
        self.labels = labels
        self.selected = selected
        self.enabled = enabled
        self.onSelect = onSelect
        super.init(frame: .zero)
        let height: CGFloat = 24
        var x: CGFloat = 14   // 和普通菜单项的文字左对齐
        for _ in labels { rects.append(NSRect(x: x, y: 4, width: segmentWidth, height: height)); x += segmentWidth }
        frame = NSRect(x: 0, y: 0, width: x + 14, height: height + 8)
        alphaValue = enabled ? 1 : 0.4
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let first = rects.first, let last = rects.last else { return }
        let radius: CGFloat = 6
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: first.union(last), xRadius: radius, yRadius: radius).fill()
        for (i, r) in rects.enumerated() {
            if i == selected {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 1.5, dy: 1.5), xRadius: radius - 1, yRadius: radius - 1).fill()
            } else if i > 0 && i - 1 != selected {
                NSColor.separatorColor.setFill()
                NSRect(x: r.minX - 0.5, y: r.minY + 6, width: 1, height: r.height - 12).fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: i == selected ? NSColor.white : NSColor.labelColor]
            let size = (labels[i] as NSString).size(withAttributes: attrs)
            (labels[i] as NSString).draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs)
        }
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard enabled else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard let i = rects.firstIndex(where: { $0.contains(p) }), i != selected else { return }
        selected = i
        needsDisplay = true
        onSelect(i)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let codex = Product(
        name: "Codex", resource: "codex-mode", versionKey: "CODEX_MODE_VERSION",
        home: NSString(string: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "~/.codex").expandingTildeInPath,
        homeEnv: "CODEX_HOME", nonInteractiveEnv: "CODEX_MODE_NONINTERACTIVE",
        accountWord: "chatgpt", accountTitle: "ChatGPT 账号", configureEnvPrefix: "CODEX_MODE",
        urlPlaceholder: "https://api.example.com/v1", urlHint: "填写你的 API 服务地址（OpenAI 风格，通常以 /v1 结尾）和 key。")
    private let claude = Product(
        name: "Claude Code", resource: "claude-mode", versionKey: "CLAUDE_MODE_VERSION",
        home: NSString(string: ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? "~/.claude").expandingTildeInPath,
        homeEnv: "CLAUDE_CONFIG_DIR", nonInteractiveEnv: "CLAUDE_MODE_NONINTERACTIVE",
        accountWord: "account", accountTitle: "Claude 账号", configureEnvPrefix: "CLAUDE_MODE",
        urlPlaceholder: "https://api.example.com", urlHint: "填写网关根地址（不带 /v1，Claude Code 会自己加）和 key。")
    private var logPath: String { codex.home + "/codex-mode-menubar.log" }

    // 每个产品的运行状态
    private var statusLines: [String: [String]] = [:]   // 按产品名
    private var scriptVersion: [String: String] = [:]
    private var mode: [String: String] = [:]            // codex: api | chatgpt | none | unknown | missing；claude: api | account | absent | unknown | missing
    private var desktopMode = "unknown"                 // Claude 桌面应用：gateway | account | absent | unknown
    private var latestVersion = ""                      // 官网 latest.json 里的版本号（空 = 没查到）
    private var latestURL = ""                          // 下载页 / dmg 地址（应用内更新失败时打开）
    private var latestTgzURL = "", latestTgzSHA = ""    // 应用内更新用的 AASwitch.app.tar.gz 及其 sha256
    private var busy = false
    private var busyText = ""
    private var busyProduct = ""                        // 正在切换的产品名
    private var staleSessions: [String: [Int32]] = [:]  // 切换前就在运行、切换后仍活着的终端 / IDE 会话进程号（按产品名）
    private var menuOpen = false
    private var needsRender = false
    private var products: [Product] { [codex, claude] }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != NSRunningApplication.current }
        if !others.isEmpty { NSApp.terminate(nil); return }
        installEditMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.image = menubarImage()
        statusItem.button?.title = ""
        log("\(appName) \(appVersion) 启动，脚本：\(codex.script)、\(claude.script)")
        for p in products { ensureScriptInstalled(p) }
        refresh()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        checkUpdate()
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.checkUpdate() }
    }

    // MARK: 检查更新：读官网的 latest.json（地址在 Info.plist 的 AAUpdateURL，构建时由 UPDATE_URL 决定；没设就不查）
    // completion 只有手动“检查更新”会传：参数是失败原因，nil 表示查到了
    private func checkUpdate(completion: ((String?) -> Void)? = nil) {
        guard let urlString = Bundle.main.infoDictionary?["AAUpdateURL"] as? String, !urlString.isEmpty,
              let url = URL(string: urlString) else { completion?("这个版本没有配置更新地址。"); return }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self else { return }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = obj["version"] as? String else {
                DispatchQueue.main.async { completion?(error?.localizedDescription ?? "官网返回的版本信息读不懂。") }
                return
            }
            DispatchQueue.main.async {
                self.latestVersion = version
                self.latestURL = (obj["url"] as? String) ?? ""
                self.latestTgzURL = (obj["tgz_url"] as? String) ?? ""
                self.latestTgzSHA = ((obj["tgz_sha256"] as? String) ?? "").lowercased()
                self.render()
                completion?(nil)
            }
        }.resume()
    }
    // 菜单里的“检查更新”：立即查一次并弹窗说结果
    @objc private func checkUpdateManually() {
        guard !busy else { return }
        log("用户点击：检查更新")
        checkUpdate { [weak self] failure in
            guard let self = self else { return }
            let alert = NSAlert()
            alert.addButton(withTitle: "好")
            if let failure = failure {
                alert.messageText = "检查更新失败"
                alert.informativeText = failure
                alert.alertStyle = .warning
            } else if self.updateAvailable {
                alert.messageText = "发现新版本 \(self.latestVersion)"
                alert.informativeText = "当前是 \(appVersion)。更新会自动下载、校验并替换应用，然后重新打开，几秒钟完成。"
                alert.buttons[0].title = "现在更新"
                alert.addButton(withTitle: "稍后")
            } else {
                alert.messageText = "已是最新版本"
                alert.informativeText = "\(appName) \(appVersion)"
            }
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            if failure == nil && self.updateAvailable && response == .alertFirstButtonReturn { self.openUpdate() }
        }
    }
    private var updateAvailable: Bool {
        guard !latestVersion.isEmpty else { return false }
        let parts = { (s: String) in s.split(separator: ".").map { Int($0) ?? 0 } }
        return parts(appVersion).lexicographicallyPrecedes(parts(latestVersion))
    }
    private func openDownloadPage() {
        if let url = URL(string: latestURL.isEmpty ? "https://github.com/yhq1998/AA-switch/releases/latest" : latestURL) { NSWorkspace.shared.open(url) }
    }
    // 应用内更新：下载官网的 AASwitch.app.tar.gz，校验 sha256、签名和 Team ID，换掉自己再重新打开；
    // 任何一步不对就不动现有安装，改为打开下载页
    @objc private func openUpdate() {
        guard !busy else { return }
        guard !latestTgzURL.isEmpty, !latestTgzSHA.isEmpty, let url = URL(string: latestTgzURL) else { openDownloadPage(); return }
        log("用户点击：更新到 \(latestVersion)")
        busy = true
        busyProduct = ""
        busyText = "正在下载 \(appName) \(latestVersion)…"
        render()
        URLSession.shared.downloadTask(with: url) { [weak self] tmp, _, error in
            guard let self = self else { return }
            var failure = error?.localizedDescription
            var launcher: URL?
            if failure == nil, let tmp = tmp {
                do { launcher = try self.stageUpdate(tmp) } catch { failure = error.localizedDescription }
            }
            DispatchQueue.main.async {
                self.busy = false
                if let failure = failure {
                    self.log("更新失败：\(failure)")
                    self.render()
                    let alert = NSAlert()
                    alert.messageText = "更新失败"
                    alert.informativeText = failure + "\n\n现有安装没有改动。"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "好")
                    alert.addButton(withTitle: "打开下载页")
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertSecondButtonReturn { self.openDownloadPage() }
                    return
                }
                guard let launcher = launcher else { return }
                self.log("更新包校验通过，退出并由 \(launcher.path) 完成替换")
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = [launcher.path]
                try? p.run()
                NSApp.terminate(nil)
            }
        }.resume()
    }
    private struct UpdateError: LocalizedError { let errorDescription: String? }
    private func shell(_ cmd: String, _ args: [String]) -> (Int32, String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: cmd); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, text)
    }
    // 校验并解包到临时目录，返回负责替换和重开的脚本；抛错则什么都没改
    private func stageUpdate(_ tmp: URL) throws -> URL {
        let data = try Data(contentsOf: tmp)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard sha == latestTgzSHA else { throw UpdateError(errorDescription: "下载的文件校验值不对（可能下载不完整或被篡改）。") }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("aaswitch-update-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let (tarCode, tarOut) = shell("/usr/bin/tar", ["-xzf", tmp.path, "-C", work.path])
        guard tarCode == 0 else { throw UpdateError(errorDescription: "解包失败：" + tarOut) }
        guard let newApp = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError(errorDescription: "更新包里没有找到应用。")
        }
        let (verifyCode, verifyOut) = shell("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
        guard verifyCode == 0 else { throw UpdateError(errorDescription: "新版本的签名校验不通过：" + verifyOut) }
        func team(_ path: String) -> String {
            let (_, out) = shell("/usr/bin/codesign", ["-dv", "--verbose=2", path])
            return out.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }.map { String($0.dropFirst("TeamIdentifier=".count)) } ?? ""
        }
        let mine = team(Bundle.main.bundlePath), theirs = team(newApp.path)
        if !mine.isEmpty && mine != "not set" && theirs != mine {
            throw UpdateError(errorDescription: "新版本的签名者（\(theirs)）和当前安装（\(mine)）不一致，拒绝安装。")
        }
        let newVersion = (Bundle(url: newApp)?.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        let parts = { (s: String) in s.split(separator: ".").map { Int($0) ?? 0 } }
        guard parts(appVersion).lexicographicallyPrecedes(parts(newVersion)) else { throw UpdateError(errorDescription: "更新包的版本（\(newVersion)）不比当前（\(appVersion)）新。") }
        let target = Bundle.main.bundlePath
        guard FileManager.default.isWritableFile(atPath: (target as NSString).deletingLastPathComponent) else {
            throw UpdateError(errorDescription: "没有权限替换 \(target)，请手动下载安装。")
        }
        // 等本进程退出后再替换，然后重新打开；脚本自己在后台跑，不依赖本进程
        let script = work.appendingPathComponent("install.sh")
        try """
        #!/bin/bash
        for _ in $(seq 1 150); do kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null || break; sleep 0.2; done
        rm -rf \(quote(target)) && mv \(quote(newApp.path)) \(quote(target)) || exit 1
        xattr -dr com.apple.quarantine \(quote(target)) 2>/dev/null
        open -a \(quote(target))
        rm -rf \(quote(work.path))
        """.write(to: script, atomically: true, encoding: .utf8)
        return script
    }

    // 菜单栏程序没有主菜单，⌘C / ⌘V / ⌘A 这类快捷键要靠“编辑”菜单转发；装一个不可见的即可
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = NSMenu(); main.addItem(appItem)
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(); editItem.submenu = edit; main.addItem(editItem)
        NSApp.mainMenu = main
    }
    private func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(message)\n"
        try? FileManager.default.createDirectory(atPath: codex.home, withIntermediateDirectories: true)
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: Data(line.utf8), attributes: [.posixPermissions: 0o600])
        }
    }

    // MARK: 自带脚本：缺失或版本更旧时安装到数据目录；Codex 还用包内 defaults.conf 补默认配置
    private func version(of data: Data?, key: String) -> [Int] {
        guard let data = data, let text = String(data: data, encoding: .utf8) else { return [0] }
        for line in text.split(separator: "\n", maxSplits: 200, omittingEmptySubsequences: true) where line.hasPrefix(key + "=") {
            let raw = line.dropFirst(key.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            return raw.split(separator: ".").map { Int($0) ?? 0 }
        }
        return [0]
    }
    private func ensureScriptInstalled(_ p: Product) {
        let fm = FileManager.default
        guard let bundled = Bundle.main.path(forResource: p.resource, ofType: "sh"),
              let data = fm.contents(atPath: bundled) else { return }
        try? fm.createDirectory(atPath: p.home, withIntermediateDirectories: true)
        let installed = fm.contents(atPath: p.script)
        let newer = version(of: data, key: p.versionKey), current = version(of: installed, key: p.versionKey)
        if installed == nil || current.lexicographicallyPrecedes(newer) {
            if let old = installed {
                try? fm.createDirectory(atPath: p.backups, withIntermediateDirectories: true)
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
                fm.createFile(atPath: p.backups + "/" + p.resource + ".old-" + stamp, contents: old)
            }
            fm.createFile(atPath: p.script, contents: data, attributes: [.posixPermissions: 0o755])
            log("已安装 \(p.resource) v" + newer.map(String.init).joined(separator: ".") + "（原来：" + current.map(String.init).joined(separator: ".") + "）")
        }
        if p.resource == "codex-mode" {
            let conf = p.home + "/codex-mode.conf"
            if !fm.fileExists(atPath: conf),
               let defaults = Bundle.main.path(forResource: "defaults", ofType: "conf"),
               let seed = fm.contents(atPath: defaults), !seed.isEmpty {
                fm.createFile(atPath: conf, contents: seed, attributes: [.posixPermissions: 0o600])
                log("已写入默认配置 codex-mode.conf")
            }
        }
        scriptVersion[p.name] = version(of: fm.contents(atPath: p.script), key: p.versionKey).map(String.init).joined(separator: ".")
    }

    // MARK: 菜单打开时先用快速的 mode 命令刷新，再异步刷新完整状态
    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        log("打开菜单，Codex \(mode[codex.name] ?? "?")，Claude \(mode[claude.name] ?? "?")，菜单项：" + menu.items.map { $0.isSeparatorItem ? "|" : ($0.isEnabled ? "[\($0.title)]" : $0.title) }.joined(separator: " / "))
        if !busy { readModes(); render() }
        refreshStatusAsync()
    }
    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        if needsRender { render() }
    }

    // MARK: 调用脚本
    private struct Result { let code: Int32; let out: String; let err: String }
    private final class DataBox { var data = Data() }
    private func run(_ p: Product, _ args: [String], extraEnv: [String: String] = [:], input: String? = nil) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [p.script] + args
        var env = ProcessInfo.processInfo.environment
        env[p.homeEnv] = p.home
        env[p.nonInteractiveEnv] = "1"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        for (k, v) in extraEnv { env[k] = v }
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let stdin = Pipe()
        process.standardInput = stdin
        let started = Date()
        do { try process.run() } catch {
            log("无法启动脚本 \(p.resource) \(args)：\(error.localizedDescription)")
            return Result(code: -1, out: "", err: "无法启动脚本：\(error.localizedDescription)")
        }
        if let input = input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        stdin.fileHandleForWriting.closeFile()
        let box = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { box.data = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()
        let errText = String(decoding: box.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let outText = String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        log("\(p.resource) \(args.joined(separator: " ")) → 退出码 \(process.terminationStatus)，耗时 \(String(format: "%.1f", Date().timeIntervalSince(started)))s"
            + (errText.isEmpty ? "" : "\n  " + errText.replacingOccurrences(of: "\n", with: "\n  "))
            + (process.terminationStatus != 0 && !outText.isEmpty ? "\n  [stdout] " + outText.replacingOccurrences(of: "\n", with: "\n  ") : ""))
        return Result(code: process.terminationStatus,
                      out: String(decoding: outData, as: UTF8.self),
                      err: errText)
    }

    private func readMode(_ p: Product) -> String {
        guard FileManager.default.isExecutableFile(atPath: p.script) else { return "missing" }
        let result = run(p, ["mode"])
        let word = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.code == 0 && ["api", p.accountWord, "none", "absent"].contains(word) ? word : "unknown"
    }
    private func readModes() {
        for p in products { mode[p.name] = readMode(p) }
        guard !["missing", "absent"].contains(mode[claude.name] ?? "") else { desktopMode = "unknown"; return }
        let result = run(claude, ["desktop-mode"])
        let word = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        desktopMode = result.code == 0 && ["gateway", "account", "absent"].contains(word) ? word : "unknown"
    }
    private var hasDesktop: Bool { ["gateway", "account"].contains(desktopMode) }
    // 分段控件每格的宽度：两个产品所有标签里最宽的那个加左右留白，让两行完全对齐
    private var segmentWidth: CGFloat {
        (products.flatMap { [$0.accountTitle, "API"] }.map(SegmentRow.textWidth).max() ?? 40) + 28
    }
    @objc private func refresh() {
        guard !busy else { return }
        readModes()
        render()
        refreshStatusAsync()
    }
    private func refreshStatusAsync() {
        guard !busy else { return }
        let targets = products.filter { !["missing", "absent"].contains(mode[$0.name] ?? "") }
        let stale = staleSessions
        DispatchQueue.global().async {
            var lines: [String: [String]] = [:]
            for p in targets { lines[p.name] = self.run(p, ["status"]).out.split(separator: "\n").map(String.init) }
            var stillStale: [String: [Int32]] = [:]
            for p in targets where !(stale[p.name] ?? []).isEmpty {
                let alive = Set(self.terminalSessions(p))
                stillStale[p.name] = (stale[p.name] ?? []).filter(alive.contains)
            }
            DispatchQueue.main.async {
                guard !self.busy else { return }
                for (k, v) in lines { self.statusLines[k] = v }
                for (k, v) in stillStale { self.staleSessions[k] = v }
                self.render()
                self.maybeShowOnboarding()
            }
        }
    }

    // MARK: 首次打开的引导：把检测到的状态摆出来，让用户选每个产品从哪种模式开始（默认账号），点“应用”才真正切换
    private var onboardingShown = false
    private func loginWord(_ p: Product) -> String {   // Codex 的“登录：…”那行（ChatGPT 账号 / API key / 未登录）
        statusInfo(p).first { $0.key == "登录" }?.value ?? ""
    }
    // Codex 的两个轴不一致：配置指向网关但用 ChatGPT 登录，或反过来
    private func isMixed(_ p: Product) -> Bool {
        guard p.resource == "codex-mode", statusLines[p.name] != nil else { return false }
        let m = mode[p.name] ?? "", login = loginWord(p)
        return (m == "api" && !login.isEmpty && !login.hasPrefix("API key")) || (m == "chatgpt" && login.hasPrefix("API key"))
    }
    private func detectedText(_ p: Product) -> String {
        let m = mode[p.name] ?? "unknown"
        if p.resource == "codex-mode" {
            let login = loginWord(p)
            switch m {
            case "none": return "尚未用 AA Switch 切换过，按 Codex 自己的设置运行" + (login.isEmpty ? "" : "，登录方式：\(login)")
            case "api": return "请求发往 API 网关" + (login.isEmpty ? "" : "，登录方式：\(login)")
            case "chatgpt": return "ChatGPT 账号模式" + (login.isEmpty ? "" : "，登录方式：\(login)")
            default: return "状态未知"
            }
        }
        switch m {
        case "api": return "API 模式" + (hasDesktop ? (desktopMode == "gateway" ? "（桌面应用也走网关）" : "（桌面应用仍是账号）") : "")
        case "account": return "账号模式" + (hasDesktop && desktopMode == "gateway" ? "（但桌面应用在网关模式）" : "")
        default: return "状态未知"
        }
    }
    private func maybeShowOnboarding() {
        guard !onboardingShown, !UserDefaults.standard.bool(forKey: "onboardingDone"), !busy else { return }
        let targets = products.filter { !["missing", "absent", "unknown"].contains(mode[$0.name] ?? "unknown") && statusLines[$0.name] != nil }
        guard !targets.isEmpty else { return }
        onboardingShown = true
        log("首次打开，显示初始设置")
        let alert = NSAlert()
        alert.messageText = "欢迎使用 \(appName)"
        alert.informativeText = "下面是检测到的当前状态。请选择每个产品从哪种模式开始，点“应用”后才会真正切换；之后随时可以在菜单里切换。"
        let rowH: CGFloat = 66, width: CGFloat = 470
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: rowH * CGFloat(targets.count)))
        var choice: [String: NSSegmentedControl] = [:]   // 产品名 → 分段控件（第 1 段 = API，第 0 段 = 账号）
        for (i, p) in targets.enumerated() {
            let y = rowH * CGFloat(targets.count - 1 - i)
            let box = NSView(frame: NSRect(x: 0, y: y, width: width, height: rowH))   // 每个产品一个容器，单选钮按容器分组
            let title = NSTextField(labelWithString: p.name)
            title.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
            title.frame = NSRect(x: 0, y: rowH - 22, width: width, height: 18)
            let detected = NSTextField(labelWithString: "检测到：" + detectedText(p))
            detected.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            detected.textColor = .secondaryLabelColor
            detected.frame = NSRect(x: 0, y: rowH - 40, width: width, height: 16)
            let seg = NSSegmentedControl(labels: [p.accountTitle, "API"], trackingMode: .selectOne, target: nil, action: nil)
            seg.selectedSegment = 0   // 默认账号
            seg.segmentDistribution = .fillEqually
            seg.sizeToFit()
            seg.frame = NSRect(x: 0, y: rowH - 64, width: segmentWidth * 2, height: seg.frame.height)
            let note = NSTextField(labelWithString: p.resource == "codex-mode" ? "切换会退出并重新打开 ChatGPT" : (hasDesktop ? "切换会重启 Claude 桌面应用" : ""))
            note.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            note.textColor = .tertiaryLabelColor
            note.frame = NSRect(x: seg.frame.maxX + 12, y: rowH - 60, width: width - seg.frame.maxX - 12, height: 16)
            for v in [title, detected, seg, note] as [NSView] { box.addSubview(v) }
            view.addSubview(box)
            choice[p.name] = seg
        }
        alert.accessoryView = view
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "稍后再说")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        UserDefaults.standard.set(true, forKey: "onboardingDone")
        guard response == .alertFirstButtonReturn else { log("初始设置：稍后再说"); return }
        // 只对“选的和现状不一致”的产品执行切换；混合状态也算不一致，重新切一次把两个轴对齐
        var plan: [(Product, [[String]])] = []
        for p in targets {
            let wantApi = choice[p.name]?.selectedSegment == 1
            let m = mode[p.name] ?? ""
            if p.resource == "codex-mode" {
                let clean = wantApi ? (m == "api" && !isMixed(p)) : ((m == "chatgpt" || m == "none") && !isMixed(p))
                if !clean { plan.append((p, [[wantApi ? "api" : "chatgpt"]])) }
            } else {
                var steps: [[String]] = []
                if wantApi {
                    if m != "api" { steps.append(["api"]) }
                    if hasDesktop && desktopMode != "gateway" { steps.append(["desktop", "gateway"]) }
                } else {
                    if m != "account" { steps.append(["account"]) }
                    if hasDesktop && desktopMode == "gateway" { steps.append(["desktop", "account"]) }
                }
                if !steps.isEmpty { plan.append((p, steps)) }
            }
        }
        log("初始设置：" + (plan.isEmpty ? "无需改动" : plan.map { "\($0.0.name) " + $0.1.map { $0.joined(separator: " ") }.joined(separator: "，") }.joined(separator: "；")))
        runPlan(plan)
    }
    // 依次对多个产品执行切换（每个产品内部的步骤也按顺序），前一个做完再做下一个
    private func runPlan(_ plan: [(Product, [[String]])]) {
        guard let first = plan.first else { return }
        doSwitch(first.0, steps: first.1) { [weak self] in self?.runPlan(Array(plan.dropFirst())) }
    }

    // MARK: 切换
    @objc private func codexToApi() { doSwitch(codex, steps: [["api"]]) }
    @objc private func claudeToApi() { doSwitch(claude, steps: [["api"]] + (desktopMode == "gateway" ? [["desktop", "gateway"]] : [])) }
    // 一次切换可能是几条脚本命令（比如先切终端再切桌面应用），按顺序执行，哪条失败就停在哪条
    private func doSwitch(_ p: Product, steps: [[String]], then: (() -> Void)? = nil) {
        guard !busy, !steps.isEmpty else { then?(); return }
        log("用户点击：\(p.name) 执行 " + steps.map { $0.joined(separator: " ") }.joined(separator: "，"))
        let restartsApp = p.resource == "codex-mode" || steps.contains { $0.first == "desktop" }
        busy = true
        busyProduct = p.name
        busyText = restartsApp ? "正在切换 \(p.name)，应用会退出并重新打开…" : "正在切换 \(p.name)…"
        render()
        DispatchQueue.global().async {
            let before = self.terminalSessions(p)   // 切换前已打开的会话切换后仍用旧配置，之后在菜单里提醒
            var failed: ([String], Result)? = nil
            var doneAny = false
            for args in steps {
                let result = self.run(p, args)
                if result.code != 0 { failed = (args, result); break }
                doneAny = true
            }
            DispatchQueue.main.async {
                self.busy = false
                self.busyProduct = ""
                self.staleSessions[p.name] = doneAny ? before : []
                self.refresh()
                if let (args, result) = failed {
                    let text = (result.err + "\n" + result.out).trimmingCharacters(in: .whitespacesAndNewlines)
                    self.showError(title: "\(p.name) 切换失败（\(args.joined(separator: " "))，退出码 \(result.code)）", text: text, retry: (p, args.joined(separator: " ")))
                } else {
                    then?()
                }
            }
        }
    }
    private func showError(title: String, text: String, retry: (Product, String)) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text.isEmpty ? "脚本没有输出。请点“导出诊断信息”，把桌面上生成的文件发给管理员。" : text
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "在终端中运行")
        alert.addButton(withTitle: "导出诊断信息")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertSecondButtonReturn: openTerminal(retry.0, command: retry.1)
        case .alertThirdButtonReturn: exportDiagnostics()
        default: break
        }
    }

    // MARK: 导出诊断信息：把版本、系统、芯片、脚本状态和最近的日志写成一个文本文件放到桌面，方便发给别人排查
    @objc private func exportDiagnostics() {
        log("用户点击：导出诊断信息")
        func sh(_ cmd: String, _ args: [String]) -> String {
            let p = Process(); p.executableURL = URL(fileURLWithPath: cmd); p.arguments = args
            let out = Pipe(); p.standardOutput = out; p.standardError = out
            do { try p.run() } catch { return "（无法运行 \(cmd)：\(error.localizedDescription)）" }
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            return text.trimmingCharacters(in: .whitespacesAndNewlines) + (p.terminationStatus == 0 ? "" : "\n（退出码 \(p.terminationStatus)）")
        }
        let fm = FileManager.default
        var r: [String] = []
        r.append("\(appName) 诊断信息  \(ISO8601DateFormatter().string(from: Date()))")
        r.append("")
        r.append("== 应用")
        r.append("版本：\(appVersion)（build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")）")
        r.append("位置：\(Bundle.main.bundlePath)")
        r.append("签名：" + sh("/usr/bin/codesign", ["-dv", "--verbose=2", Bundle.main.bundlePath]).split(separator: "\n").filter { $0.hasPrefix("Authority=") || $0.hasPrefix("TeamIdentifier=") }.joined(separator: "；"))
        r.append("")
        r.append("== 系统")
        r.append("macOS：\(ProcessInfo.processInfo.operatingSystemVersionString)")
        r.append("芯片：" + sh("/usr/bin/uname", ["-m"]) + "，Rosetta 下运行：" + (sh("/usr/sbin/sysctl", ["-n", "sysctl.proc_translated"]) == "1" ? "是" : "否"))
        r.append("用户：\(NSUserName())，HOME：\(NSHomeDirectory())")
        r.append("PATH：\(ProcessInfo.processInfo.environment["PATH"] ?? "")")
        r.append("bash：" + (sh("/bin/bash", ["--version"]).split(separator: "\n").first.map(String.init) ?? ""))
        r.append("")
        for p in products {
            r.append("== \(p.name)（\(p.resource)）")
            r.append("数据目录：\(p.home)")
            r.append("脚本：\(p.script)  存在：\(fm.fileExists(atPath: p.script))  可执行：\(fm.isExecutableFile(atPath: p.script))  版本：\(scriptVersion[p.name] ?? "?")")
            r.append("模式：\(mode[p.name] ?? "?")" + (p.resource == "claude-mode" ? "，桌面应用：\(desktopMode)" : ""))
            let st = run(p, ["status"])
            r.append("status（退出码 \(st.code)）：")
            r.append(st.out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").map { "  " + $0 }.joined(separator: "\n"))
            if !st.err.isEmpty { r.append("  [stderr] " + st.err.replacingOccurrences(of: "\n", with: "\n  ")) }
            r.append("")
        }
        r.append("== 相关程序")
        r.append("codex：" + sh("/usr/bin/which", ["codex"]))
        r.append("claude：" + sh("/usr/bin/which", ["claude"]))
        for app in ["ChatGPT", "Codex", "Claude"] {
            for dir in ["/Applications", NSHomeDirectory() + "/Applications"] where fm.fileExists(atPath: "\(dir)/\(app).app") {
                let v = (NSDictionary(contentsOfFile: "\(dir)/\(app).app/Contents/Info.plist")?["CFBundleShortVersionString"] as? String) ?? "?"
                r.append("\(app).app：\(dir)，版本 \(v)")
            }
        }
        r.append("")
        r.append("== 最近的日志（\(logPath)）")
        let logText = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "（读不到日志）"
        r.append(logText.split(separator: "\n").suffix(300).joined(separator: "\n"))
        let stamp = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date()) }()
        let file = fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/\(appName) 诊断 \(stamp).txt")
        do {
            try r.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } catch {
            let alert = NSAlert(); alert.messageText = "导出失败"; alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }

    // MARK: 配置表单（原生弹窗），保存后在 API 模式下立即重新切换让新地址生效
    @objc private func configureCodex() { openConfigure(codex) }
    @objc private func configureClaude() { openConfigure(claude) }
    private func openConfigure(_ p: Product) {
        var baseURL = "", headers = ""
        for line in run(p, ["config"]).out.split(separator: "\n") {
            if line.hasPrefix("base_url=") { baseURL = String(line.dropFirst(9)) }
            else if line.hasPrefix("headers=") { headers = String(line.dropFirst(8)) }
        }
        showConfigureForm(p, baseURL: baseURL, headers: headers, error: nil)
    }
    private func showConfigureForm(_ p: Product, baseURL: String, headers: String, error: String?) {
        let alert = NSAlert()
        alert.messageText = "配置 \(p.name) API"
        alert.informativeText = error ?? (p.urlHint + " key 只保存在 macOS 钥匙串里，按地址域名保存，Codex 和 Claude Code 用同一个网关时共用一个 key。换地址时记得把 key 也换成该地址对应的。")
        if error != nil { alert.alertStyle = .warning }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 118))
        func row(_ title: String, _ field: NSTextField, y: CGFloat) {
            let label = NSTextField(labelWithString: title)
            label.frame = NSRect(x: 0, y: y + 2, width: 96, height: 20); label.alignment = .right
            field.frame = NSRect(x: 104, y: y, width: 336, height: 24)
            view.addSubview(label); view.addSubview(field)
        }
        let urlField = NSTextField(); urlField.stringValue = baseURL; urlField.placeholderString = p.urlPlaceholder
        let headerField = NSTextField(); headerField.stringValue = headers; headerField.placeholderString = "名称=值，多个用逗号分隔；通常留空"
        let keyField = NSTextField()   // 明文显示，并回填当前地址已保存的 key，方便核对
        let savedKey = baseURL.isEmpty ? "" : run(p, ["key", baseURL]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        keyField.stringValue = savedKey
        keyField.placeholderString = "sk-…"
        row("API 地址", urlField, y: 88); row("额外请求头", headerField, y: 48); row("API key", keyField, y: 8)
        urlField.nextKeyView = headerField; headerField.nextKeyView = keyField; keyField.nextKeyView = urlField
        alert.accessoryView = view
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = urlField
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let hdr = headerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = keyField.stringValue
        if url.isEmpty { showConfigureForm(p, baseURL: url, headers: hdr, error: "请填写 API 地址。"); return }
        if key.isEmpty && run(p, ["has-key", url]).code != 0 {
            showConfigureForm(p, baseURL: url, headers: hdr, error: "这个地址还没有保存过 key，请填写 API key。"); return
        }
        let result = run(p, ["configure"],
                         extraEnv: [p.configureEnvPrefix + "_BASE_URL": url, p.configureEnvPrefix + "_HEADERS": hdr, p.configureEnvPrefix + "_KEY_STDIN": "1"],
                         input: key + "\n")
        if result.code != 0 { showConfigureForm(p, baseURL: url, headers: hdr, error: result.err.replacingOccurrences(of: "错误：", with: "")); return }
        log("\(p.name) 配置已保存：\(url)")
        if mode[p.name] == "api" {   // 当前就在 API 模式：立即重新切换，让新地址 / 新 key 生效
            doSwitch(p, steps: [["api"]] + (p.resource == "claude-mode" && desktopMode == "gateway" ? [["desktop", "gateway"]] : []))
        } else {
            refresh()
            let done = NSAlert()
            done.messageText = "已保存"
            done.informativeText = "\(p.name) 当前是\(p.accountTitle)模式，新地址会在下次切换到 API 时使用。"
            done.addButton(withTitle: "好")
            done.runModal()
        }
    }
    private func openTerminal(_ p: Product, command: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(p.resource)-\(command.replacingOccurrences(of: " ", with: "-")).command")
        let script = "#!/bin/bash\nclear\n\(p.homeEnv)=\(quote(p.home)) \(quote(p.script)) \(command)\n"
            + "echo\necho '完成，可以关闭这个窗口。'\n"
        try? script.write(to: file, atomically: true, encoding: .utf8)
        chmod(file.path, 0o755)
        NSWorkspace.shared.open(file)
    }
    private func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    @objc private func openCodexBackups() { openBackups(codex) }
    @objc private func openClaudeBackups() { openBackups(claude) }
    private func openBackups(_ p: Product) {   // 脚本每次改配置前的备份（只留最近 20 次），出问题时手动找回用
        try? FileManager.default.createDirectory(atPath: p.backups, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: p.backups))
    }

    // MARK: 开机自启（LaunchAgent，只写/删 plist，下次登录生效）
    private var agentPath: String {
        NSString(string: "~/Library/LaunchAgents/\(bundleID).plist").expandingTildeInPath
    }
    private var loginEnabled: Bool { FileManager.default.fileExists(atPath: agentPath) }
    @objc private func toggleLogin() {
        if loginEnabled {
            try? FileManager.default.removeItem(atPath: agentPath)
        } else {
            let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let plist: [String: Any] = ["Label": bundleID, "ProgramArguments": [exe], "RunAtLoad": true]
            try? FileManager.default.createDirectory(atPath: (agentPath as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                FileManager.default.createFile(atPath: agentPath, contents: data)
            }
        }
        render()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Claude Code 的终端 / IDE 会话
    // Claude Code 是终端和 IDE 里跑的命令行程序，切换只对新会话生效，已开的会话不能替用户重启，只能提醒。
    // 这里列出当前活着的会话进程号；Claude 桌面应用自己启动的会话不算（它们本来就不读这份配置，见 claude-mode 脚本开头）。
    private func terminalSessions(_ p: Product) -> [Int32] {
        guard p.resource == "claude-mode" else { return [] }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,comm="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return [] }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        var parent: [Int32: Int32] = [:], command: [Int32: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.drop(while: { $0 == " " }).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
            parent[pid] = ppid
            command[pid] = String(parts[2])
        }
        return command.filter { $0.value == "claude" || $0.value.hasSuffix("/claude") }.keys.filter { pid in
            var cur = parent[pid], hops = 0
            while let c = cur, c > 1, hops < 64 {
                if command[c]?.contains("/Claude.app/") == true { return false }
                cur = parent[c]; hops += 1
            }
            return true
        }.sorted()
    }

    // MARK: 渲染图标和菜单
    private func render() {
        if menuOpen && !busy && needsRender == false && menu.items.count > 0 {
            needsRender = true       // 菜单打开时不重建（避免闪动），关闭后再刷新
            updateIcon()
            return
        }
        needsRender = false
        updateIcon()
        menu.removeAllItems()
        renderSection(codex, toApi: #selector(codexToApi), configure: #selector(configureCodex), backups: #selector(openCodexBackups))
        menu.addItem(.separator())
        renderSection(claude, toApi: #selector(claudeToApi), configure: #selector(configureClaude), backups: #selector(openClaudeBackups))
        menu.addItem(.separator())
        add("刷新状态", #selector(refresh), enabled: !busy)
        add("检查更新", #selector(checkUpdateManually), enabled: !busy)
        add("导出诊断信息…", #selector(exportDiagnostics), enabled: !busy)
        let login = add("开机自动启动", #selector(toggleLogin))
        login.state = loginEnabled ? .on : .off
        menu.addItem(.separator())
        if busy && busyProduct.isEmpty {
            add(busyText, enabled: false)
        } else if updateAvailable {
            add(latestTgzURL.isEmpty ? "有新版本 \(latestVersion)，点击下载…" : "有新版本 \(latestVersion)，点击更新…", #selector(openUpdate))
        }
        add("\(appName) \(appVersion)", enabled: false)
        add("退出", #selector(quit))
    }

    // status 命令的一行：“键：值”
    private struct Line { let key: String; let value: String }
    private func statusInfo(_ p: Product) -> [Line] {
        (statusLines[p.name] ?? []).map { l in
            if let r = l.range(of: "：") { return Line(key: String(l[..<r.lowerBound]), value: String(l[r.upperBound...])) }
            return Line(key: l, value: "")
        }
    }
    private static let urlKeys = ["请求发往", "API 地址（切换后使用）", "API 地址"]
    private func isWarning(_ l: Line) -> Bool {
        l.key == "注意" || l.key == "新地址尚未生效" || l.value.hasPrefix("未登录") || l.value.hasPrefix("未保存")
    }

    // 一个产品的分组：带产品图标的标题、一行“账号 ⟷ API”开关（Claude 的开关同时管命令行和桌面应用）、小字的 API 地址、只在异常时出现的提示行；
    // 配置、重新应用和正常态的详细信息都收进“更多”子菜单，正常时不占地方
    private func renderSection(_ p: Product, toApi: Selector, configure: Selector, backups: Selector) {
        let m = mode[p.name] ?? "unknown"
        let header = add(p.name, enabled: false)
        header.attributedTitle = NSAttributedString(string: p.name, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        header.image = productIcon(p)
        if m == "missing" {
            add("未找到 \(p.script)", enabled: false)
            add("请重新安装 \(appName)", enabled: false)
            return
        }
        if m == "absent" {
            add("这台电脑上没有找到 Claude Code", enabled: false)
            return
        }
        let info = statusInfo(p)
        let loaded = statusLines[p.name] != nil
        let url = info.first { Self.urlKeys.contains($0.key) }?.value ?? ""
        let configured = !loaded || (!url.isEmpty && url != "未配置")
        // 一个开关：开 = API。Claude Code 装了桌面应用时，开关同时管命令行和桌面应用；两边不一致时开关显示为关，并提示一句
        let desktop = p.resource == "claude-mode" && hasDesktop
        let isOn = m == "api" && (!desktop || desktopMode == "gateway")
        let mixed = desktop && ((m == "api") != (desktopMode == "gateway"))
        // 没切换过（Codex 默认配置）或两边不一致时哪格都不高亮
        let selected: Int? = isOn ? 1 : ((m == p.accountWord && !mixed) ? 0 : nil)
        if busy && busyProduct == p.name {
            add(busyText, enabled: false)
        } else {
            let row = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            row.view = SegmentRow(labels: [p.accountTitle, "API"], selected: selected, enabled: !busy, segmentWidth: segmentWidth) { [weak self] i in
                guard let self = self else { return }
                let on = i == 1
                self.menu.cancelTracking()
                if on && !configured { self.openConfigure(p); return }
                var steps: [[String]] = []
                if on {
                    if m != "api" { steps.append(["api"]) }
                    if desktop && self.desktopMode != "gateway" { steps.append(["desktop", "gateway"]) }
                } else {
                    if m != p.accountWord { steps.append([p.accountWord]) }
                    if desktop && self.desktopMode == "gateway" { steps.append(["desktop", "account"]) }
                }
                self.doSwitch(p, steps: steps)
            }
            menu.addItem(row)
        }
        if !loaded {
            addSmall("读取中…", nil)
        } else if configured {
            addSmall((m == "api" ? "API 请求发往 " : "切到 API 后请求发往 ") + shortURL(url), nil)
        } else {
            addSmall("还没配置 API 地址，点击填写…", configure)
        }
        if m == "none" {
            addSmall("还没用 \(appName) 切换过，当前按 Codex 自己的设置运行；点一格开始管理", nil)
        }
        if mixed {
            add("⚠ 命令行\(m == "api" ? "在 API" : "在账号")、桌面应用\(desktopMode == "gateway" ? "在网关" : "在账号")，点 API 会把两边都切到 API", enabled: false)
        }
        if desktop {
            addSmall("切换会重启 Claude 桌面应用，会话列表自动同步", nil)
        }
        if isMixed(p) {
            add(m == "api" ? "⚠ 配置指向 API 网关，但 Codex 用 ChatGPT 账号登录，请求会失败；再点一次当前模式即可修正"
                           : "⚠ 配置是 ChatGPT 账号模式，但 Codex 用 API key 登录；再点一次当前模式即可修正", enabled: false)
        }
        for l in info where isWarning(l) { add("⚠ " + l.key + (l.value.isEmpty ? "" : "：" + l.value), enabled: false) }
        if let stale = staleSessions[p.name], !stale.isEmpty {
            add("⚠ 有 \(stale.count) 个终端 / IDE 会话是切换前打开的，仍在用旧配置，重新打开后生效", enabled: false)
        }
        let more = NSMenu()
        more.autoenablesItems = false
        more.addItem(item("配置 API 地址 / key…", configure))
        if m == "api" && !busy {   // 手动改过配置文件、或想强制重来时用；表单保存后已自动做这一步
            let claudeDesktop = p.resource == "claude-mode" && desktopMode == "gateway"
            more.addItem(item(p.resource == "codex-mode" ? "重新应用 API 配置并重启 Codex" : (claudeDesktop ? "重新应用 API 配置并重启 Claude 桌面应用" : "重新应用 API 配置"), toApi))
        }
        more.addItem(item("打开备份文件夹", backups))
        let details = info.filter { !isWarning($0) && $0.key != "模式" && !Self.urlKeys.contains($0.key) }
        more.addItem(.separator())
        if !loaded { more.addItem(item("正在读取状态…", nil, enabled: false)) }
        for l in details { more.addItem(item(l.key + (l.value.isEmpty ? "" : "：" + l.value), nil, enabled: false)) }
        if let v = scriptVersion[p.name], !v.isEmpty { more.addItem(item("脚本：\(p.resource) \(v)", nil, enabled: false)) }   // 排查问题时看
        let moreItem = NSMenuItem(title: "更多", action: nil, keyEquivalent: "")
        moreItem.submenu = more
        menu.addItem(moreItem)
    }
    private func item(_ title: String, _ action: Selector?, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled && action != nil
        return item
    }
    @discardableResult
    private func add(_ title: String, _ action: Selector? = nil, enabled: Bool = true) -> NSMenuItem {
        let i = item(title, action, enabled: enabled)
        menu.addItem(i)
        return i
    }
    // 小字灰色的说明行；给了动作就可点
    @discardableResult
    private func addSmall(_ text: String, _ action: Selector?) -> NSMenuItem {
        let i = add(text, action, enabled: action != nil)
        i.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor])
        return i
    }
    private func shortURL(_ url: String) -> String {
        var u = url
        for prefix in ["https://", "http://"] where u.hasPrefix(prefix) { u = String(u.dropFirst(prefix.count)) }
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }
    // 分组标题前的产品图标：直接用本机装好的应用自己的图标（Codex.app，或 ChatGPT.app 里自带的 Codex 图标；Claude.app），
    // 没装时退回包里自己画的单色标记
    private var iconCache: [String: NSImage] = [:]
    private func productIcon(_ p: Product) -> NSImage? {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let key = p.resource + (dark ? "-dark" : "")
        if let cached = iconCache[key] { return cached }
        let fm = FileManager.default
        var image: NSImage?
        for dir in ["/Applications", NSHomeDirectory() + "/Applications"] where image == nil {
            if p.resource == "codex-mode" {
                if fm.fileExists(atPath: dir + "/Codex.app") {
                    image = NSWorkspace.shared.icon(forFile: dir + "/Codex.app")
                } else {
                    image = NSImage(contentsOfFile: dir + "/ChatGPT.app/Contents/Resources/icon-codex-" + (dark ? "dark-color" : "light") + ".png")
                }
            } else if fm.fileExists(atPath: dir + "/Claude.app") {
                image = NSWorkspace.shared.icon(forFile: dir + "/Claude.app")
            }
        }
        if image == nil, let path = Bundle.main.path(forResource: "product-" + p.resource.replacingOccurrences(of: "-mode", with: ""), ofType: "png") {
            image = NSImage(contentsOfFile: path)
            image?.isTemplate = true
        }
        image?.size = NSSize(width: 16, height: 16)
        if let image = image { iconCache[key] = image }
        return image
    }
    // 菜单栏图标是应用图标里的那只 AA 笑脸开关（包里的 menubar.png），静态、不带文字，不表示状态；找不到时退回系统符号
    private func menubarImage() -> NSImage? {
        if let path = Bundle.main.path(forResource: "menubar", ofType: "png"), let image = NSImage(contentsOfFile: path) {
            image.size = NSSize(width: 36, height: 18)   // 72x36 像素的 @2x 图
            image.isTemplate = false
            return image
        }
        let image = NSImage(systemSymbolName: "switch.2", accessibilityDescription: appName)
        image?.isTemplate = true
        return image
    }
    // 切换中图标半透明；鼠标悬停显示两个产品各自的模式
    private func updateIcon() {
        guard let button = statusItem.button else { return }
        button.alphaValue = busy ? 0.5 : 1
        func word(_ p: Product) -> String {
            switch mode[p.name] ?? "unknown" {
            case "api": return "API 模式" + (p.resource == "claude-mode" && hasDesktop && desktopMode != "gateway" ? "（桌面应用仍是账号）" : "")
            case p.accountWord: return p.accountTitle
            case "none": return "尚未切换过"
            case "missing": return "未安装脚本"
            case "absent": return "未安装"
            default: return "未知"
            }
        }
        let tooltip = busy ? busyText : products.map { "\($0.name)：" + word($0) }.joined(separator: "\n")
        button.toolTip = tooltip
        button.image?.accessibilityDescription = tooltip
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
