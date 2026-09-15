// AA Switch（API / Account Switch）菜单栏小工具：在右上角显示 Codex 当前模式，点一下切换。
// 所有切换逻辑都在 ~/.codex/codex-mode 脚本里，本程序只负责安装脚本、调用和展示。
import AppKit
import Foundation

let bundleID = Bundle.main.bundleIdentifier ?? "local.aaswitch"
let appName = (Bundle.main.infoDictionary?["CFBundleName"] as? String) ?? "AA Switch"
let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let home: String = {
        let env = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "~/.codex"
        return NSString(string: env).expandingTildeInPath
    }()
    private var scriptPath: String { home + "/codex-mode" }
    private var logPath: String { home + "/codex-mode-menubar.log" }
    private var statusLines: [String] = []
    private var scriptVersion = ""
    private var mode = "unknown"      // api | chatgpt | none | unknown | missing
    private var busy = false
    private var menuOpen = false
    private var needsRender = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != NSRunningApplication.current }
        if !others.isEmpty { NSApp.terminate(nil); return }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageLeading
        log("\(appName) \(appVersion) 启动，脚本：\(scriptPath)")
        ensureScriptInstalled()
        refresh()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(message)\n"
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: Data(line.utf8), attributes: [.posixPermissions: 0o600])
        }
    }

    // MARK: 自带脚本：缺失或版本更旧时安装到 ~/.codex，并用包内 defaults.conf 补默认配置
    private func version(of data: Data?) -> [Int] {
        guard let data = data, let text = String(data: data, encoding: .utf8) else { return [0] }
        for line in text.split(separator: "\n", maxSplits: 40, omittingEmptySubsequences: true) where line.hasPrefix("CODEX_MODE_VERSION=") {
            let raw = line.dropFirst("CODEX_MODE_VERSION=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            return raw.split(separator: ".").map { Int($0) ?? 0 }
        }
        return [0]
    }
    private func ensureScriptInstalled() {
        let fm = FileManager.default
        guard let bundled = Bundle.main.path(forResource: "codex-mode", ofType: "sh"),
              let data = fm.contents(atPath: bundled) else { return }
        try? fm.createDirectory(atPath: home, withIntermediateDirectories: true)
        let installed = fm.contents(atPath: scriptPath)
        let newer = version(of: data), current = version(of: installed)
        if installed == nil || current.lexicographicallyPrecedes(newer) {
            if let old = installed {
                let dir = home + "/codex-mode-backups"
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
                fm.createFile(atPath: dir + "/codex-mode.old-" + stamp, contents: old)
            }
            fm.createFile(atPath: scriptPath, contents: data, attributes: [.posixPermissions: 0o755])
            log("已安装脚本 v" + newer.map(String.init).joined(separator: ".") + "（原来：" + current.map(String.init).joined(separator: ".") + "）")
        }
        let conf = home + "/codex-mode.conf"
        if !fm.fileExists(atPath: conf),
           let defaults = Bundle.main.path(forResource: "defaults", ofType: "conf"),
           let seed = fm.contents(atPath: defaults), !seed.isEmpty {
            fm.createFile(atPath: conf, contents: seed, attributes: [.posixPermissions: 0o600])
            log("已写入默认配置 codex-mode.conf")
        }
        scriptVersion = version(of: fm.contents(atPath: scriptPath)).map(String.init).joined(separator: ".")
    }

    // MARK: 菜单打开时先用快速的 mode 命令刷新，再异步刷新完整状态
    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        log("打开菜单，当前模式 \(mode)，菜单项：" + menu.items.map { $0.isSeparatorItem ? "|" : ($0.isEnabled ? "[\($0.title)]" : $0.title) }.joined(separator: " / "))
        if !busy { mode = readMode(); render() }
        refreshStatusAsync()
    }
    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        if needsRender { render() }
    }

    // MARK: 调用脚本
    private struct Result { let code: Int32; let out: String; let err: String }
    private final class DataBox { var data = Data() }
    private func run(_ args: [String], extraEnv: [String: String] = [:], input: String? = nil) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath] + args
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = home
        env["CODEX_MODE_NONINTERACTIVE"] = "1"
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
            log("无法启动脚本 \(args)：\(error.localizedDescription)")
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
        log("codex-mode \(args.joined(separator: " ")) → 退出码 \(process.terminationStatus)，耗时 \(String(format: "%.1f", Date().timeIntervalSince(started)))s"
            + (errText.isEmpty ? "" : "\n  " + errText.replacingOccurrences(of: "\n", with: "\n  ")))
        return Result(code: process.terminationStatus,
                      out: String(decoding: outData, as: UTF8.self),
                      err: errText)
    }

    private func readMode() -> String {
        guard FileManager.default.isExecutableFile(atPath: scriptPath) else { return "missing" }
        let result = run(["mode"])
        let word = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.code == 0 && ["api", "chatgpt", "none"].contains(word) ? word : "unknown"
    }
    @objc private func refresh() {
        guard !busy else { return }
        mode = readMode()
        render()
        refreshStatusAsync()
    }
    private func refreshStatusAsync() {
        guard !busy, mode != "missing" else { return }
        DispatchQueue.global().async {
            let result = self.run(["status"])
            DispatchQueue.main.async {
                guard !self.busy else { return }
                self.statusLines = result.out.split(separator: "\n").map(String.init)
                self.render()
            }
        }
    }

    // MARK: 切换
    @objc private func switchToApi() { doSwitch("api") }
    @objc private func switchToChatGPT() { doSwitch("chatgpt") }
    private func doSwitch(_ target: String) {
        guard !busy else { return }
        log("用户点击：切换到 \(target)")
        busy = true
        render()
        DispatchQueue.global().async {
            let result = self.run([target])
            DispatchQueue.main.async {
                self.busy = false
                self.refresh()
                if result.code != 0 {
                    let text = (result.err + "\n" + result.out).trimmingCharacters(in: .whitespacesAndNewlines)
                    self.showError(title: target == "api" ? "切换到 API 模式失败" : "切换到 ChatGPT 账号失败",
                                   text: text, retry: target)
                }
            }
        }
    }
    private func showError(title: String, text: String, retry: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text.isEmpty ? "脚本没有输出。" : text
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "在终端中运行")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { openTerminal(command: retry) }
    }

    // MARK: 配置表单（原生弹窗），保存后在 API 模式下立即重新切换让新地址生效
    @objc private func openConfigure() {
        var baseURL = "", headers = ""
        for line in run(["config"]).out.split(separator: "\n") {
            if line.hasPrefix("base_url=") { baseURL = String(line.dropFirst(9)) }
            else if line.hasPrefix("headers=") { headers = String(line.dropFirst(8)) }
        }
        showConfigureForm(baseURL: baseURL, headers: headers, error: nil)
    }
    private func showConfigureForm(baseURL: String, headers: String, error: String?) {
        let alert = NSAlert()
        alert.messageText = "配置 API"
        alert.informativeText = error ?? "填写你的 API 服务地址和 key。key 只保存在 macOS 钥匙串里。换地址时记得把 key 也换成该地址对应的。"
        if error != nil { alert.alertStyle = .warning }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 118))
        func row(_ title: String, _ field: NSTextField, y: CGFloat) {
            let label = NSTextField(labelWithString: title)
            label.frame = NSRect(x: 0, y: y + 2, width: 96, height: 20); label.alignment = .right
            field.frame = NSRect(x: 104, y: y, width: 336, height: 24)
            view.addSubview(label); view.addSubview(field)
        }
        let urlField = NSTextField(); urlField.stringValue = baseURL; urlField.placeholderString = "https://api.example.com/v1"
        let headerField = NSTextField(); headerField.stringValue = headers; headerField.placeholderString = "名称=值，多个用逗号分隔；通常留空"
        let keyField = NSTextField()   // 明文显示，并回填当前地址已保存的 key，方便核对
        let savedKey = baseURL.isEmpty ? "" : run(["key", baseURL]).out.trimmingCharacters(in: .whitespacesAndNewlines)
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
        if url.isEmpty { showConfigureForm(baseURL: url, headers: hdr, error: "请填写 API 地址。"); return }
        if key.isEmpty && run(["has-key", url]).code != 0 {
            showConfigureForm(baseURL: url, headers: hdr, error: "这个地址还没有保存过 key，请填写 API key。"); return
        }
        let result = run(["configure"], extraEnv: ["CODEX_MODE_BASE_URL": url, "CODEX_MODE_HEADERS": hdr, "CODEX_MODE_KEY_STDIN": "1"],
                         input: key + "\n")
        if result.code != 0 { showConfigureForm(baseURL: url, headers: hdr, error: result.err.replacingOccurrences(of: "错误：", with: "")); return }
        log("配置已保存：\(url)")
        if mode == "api" {
            doSwitch("api")   // 当前就在 API 模式：立即重新切换，让新地址 / 新 key 生效
        } else {
            refresh()
            let done = NSAlert()
            done.messageText = "已保存"
            done.informativeText = "当前是 ChatGPT 账号模式，新地址会在下次切换到 API 时使用。"
            done.addButton(withTitle: "好")
            done.runModal()
        }
    }
    private func openTerminal(command: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("codex-mode-\(command).command")
        let script = "#!/bin/bash\nclear\nCODEX_HOME=\(quote(home)) \(quote(scriptPath)) \(command)\n"
            + "echo\necho '完成，可以关闭这个窗口。'\n"
        try? script.write(to: file, atomically: true, encoding: .utf8)
        chmod(file.path, 0o755)
        NSWorkspace.shared.open(file)
    }
    private func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    @objc private func openBackups() {
        let path = home + "/codex-mode-backups"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
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
        if mode == "missing" {
            add("未找到 \(scriptPath)", enabled: false)
            add("请重新安装 \(appName)", enabled: false)
        } else if statusLines.isEmpty {
            add("正在读取状态…", enabled: false)
        } else {
            for line in statusLines { add(line, enabled: false) }
        }
        menu.addItem(.separator())
        if busy {
            add("正在切换，Codex 会退出并重新打开…", enabled: false)
        } else {
            add(mode == "api" ? "重新登录 API（换 key 后用）" : "切换到 API 模式", #selector(switchToApi), enabled: mode != "missing")
            add("切换到 ChatGPT 账号", #selector(switchToChatGPT), enabled: mode != "chatgpt" && mode != "missing")
        }
        menu.addItem(.separator())
        add("配置 API 地址 / key…", #selector(openConfigure), enabled: mode != "missing")
        add("刷新状态", #selector(refresh), enabled: !busy)
        add("打开备份文件夹", #selector(openBackups))
        let login = add("开机自动启动", #selector(toggleLogin))
        login.state = loginEnabled ? .on : .off
        menu.addItem(.separator())
        add("\(appName) \(appVersion)" + (scriptVersion.isEmpty ? "" : " · 脚本 \(scriptVersion)"), enabled: false)
        add("退出", #selector(quit))
    }
    @discardableResult
    private func add(_ title: String, _ action: Selector? = nil, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled && action != nil
        menu.addItem(item)
        return item
    }
    // 菜单栏图标是包里的 menubar-*.png（AA Switch 的笑脸拨动开关，按钮位置表示模式），找不到时退回系统符号
    private func updateIcon() {
        let variant: String, symbol: String, label: String, tip: String
        if busy { (variant, symbol, label, tip) = ("off", "arrow.triangle.2.circlepath", "…", "正在切换") }
        else if mode == "api" { (variant, symbol, label, tip) = ("api", "key.fill", "API", "Codex：API 模式") }
        else if mode == "chatgpt" { (variant, symbol, label, tip) = ("chatgpt", "person.crop.circle", "GPT", "Codex：ChatGPT 账号") }
        else if mode == "missing" { (variant, symbol, label, tip) = ("off", "exclamationmark.triangle", "", "未安装 codex-mode") }
        else { (variant, symbol, label, tip) = ("off", "questionmark.circle", "", "Codex 模式未知") }
        if let path = Bundle.main.path(forResource: "menubar-" + variant, ofType: "png"), let image = NSImage(contentsOfFile: path) {
            image.size = NSSize(width: 36, height: 18)   // 72x36 像素的 @2x 图
            image.isTemplate = false
            image.accessibilityDescription = tip
            statusItem.button?.image = image
        } else if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) {
            image.isTemplate = true
            statusItem.button?.image = image
        }
        statusItem.button?.title = label.isEmpty ? "" : " " + label
        statusItem.button?.toolTip = tip
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
