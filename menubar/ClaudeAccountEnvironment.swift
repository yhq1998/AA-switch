import AppKit
import Foundation

// Presentation and invocation only. Detection decisions come from the unchanged upstream scripts.
struct ClaudeEnvironmentReport {
    static let names = ["代理内核", "TUN网卡", "出口IP", "IP一致", "时区", "地区", "IPv6", "DNS", "WebRTC", "保镖", "规则置顶", "客户端语言", "ASN属性", "生态可达性"]
    struct Row {
        let state: String
        let detail: String
    }
    let raw: String
    let rows: [String: Row]
    let complete: Bool

    init(raw: String, exitCode: Int32) {
        self.raw = raw
        var rows: [String: Row] = [:]
        // Same name=state:detail protocol as upstream's UI; include all 14 script rows.
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, Self.names.contains(parts[0]) else { continue }
            let status = parts[1].split(separator: ":", maxSplits: 1).map(String.init)
            guard let code = status.first, ["ok", "warn", "fail"].contains(code) else { continue }
            rows[parts[0]] = Row(state: code, detail: status.count > 1 ? status[1] : "")
        }
        self.rows = rows
        complete = exitCode == 0 && rows.count == Self.names.count && raw.split(separator: "\n").contains("# 结束")
    }

    var summary: String {
        guard complete else { return "检测未完成（\(rows.count)/\(Self.names.count) 项），请查看详情后重试。" }
        let failed = rows.values.filter { $0.state == "fail" }.count
        let warnings = rows.values.filter { $0.state == "warn" }.count
        return "检测完成：\(rows.count - failed - warnings) 项通过，\(warnings) 项提醒，\(failed) 项未通过（原项目标准）。"
    }
}

private struct ClaudeEnvironmentConfiguration {
    static let key = "ClaudeAccountEnvironmentConfiguration"
    static let proxyModes = ["clash-verge", "shadowrocket", "sing-box", "clashx", "surge", "auto"]
    static let proxyTitles = ["Clash Verge", "Shadowrocket", "sing-box", "ClashX", "Surge", "自动识别"]
    // Same initial values as upstream's installer-editable configuration. First use asks the user to confirm.
    var proxyMode = "clash-verge"
    var country = "US"
    var timezone = "America/New_York"
    var locale = "en_US"
    var group = "IpEqual"

    static func load() -> Self? {
        guard let dict = UserDefaults.standard.dictionary(forKey: key) as? [String: String],
              let proxy = dict["proxy"], let country = dict["country"], let timezone = dict["timezone"],
              let locale = dict["locale"], let group = dict["group"] else { return nil }
        let value = Self(proxyMode: proxy, country: country, timezone: timezone, locale: locale, group: group)
        return value.valid ? value : nil
    }

    var valid: Bool {
        Self.proxyModes.contains(proxyMode) && country.range(of: "^[A-Z]{2}$", options: .regularExpression) != nil
            && TimeZone.knownTimeZoneIdentifiers.contains(timezone)
            && locale.range(of: "^[A-Za-z]{2,3}_[A-Za-z]{2}([.@][A-Za-z0-9_-]+)?$", options: .regularExpression) != nil
            && !group.isEmpty && group.count <= 128 && !group.contains(where: { $0.isNewline })
    }

    func save() {
        UserDefaults.standard.set(["proxy": proxyMode, "country": country, "timezone": timezone, "locale": locale, "group": group], forKey: Self.key)
    }

    var arguments: [String] { [proxyMode, country, timezone, locale, group] }
    var description: String { "代理：\(Self.proxyTitles[Self.proxyModes.firstIndex(of: proxyMode) ?? 0]) · 目标：\(country) / \(timezone) / \(locale)" }
}

final class ClaudeAccountEnvironmentController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var process: Process?
    private var generation = UUID()
    private var watchdog: DispatchWorkItem?
    private var configuration = ClaudeEnvironmentConfiguration.load()
    private var report: ClaudeEnvironmentReport?
    private var reportDate: Date?
    private let status = NSTextField(wrappingLabelWithString: "")
    private let target = NSTextField(wrappingLabelWithString: "")
    private let text = NSTextView()
    private var retry: NSButton!
    private var settings: NSButton!
    private var export: NSButton!
    private let stateDirectory: URL

    init(stateDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/AA Switch/claude-account-environment", isDirectory: true)) {
        self.stateDirectory = stateDirectory
    }

    func show() {
        if window == nil { buildWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if process != nil { return }
        if configuration == nil { configure() } else { start() }
    }

    private func buildWindow() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 710, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        win.title = "Claude 环境检测"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 620, height: 600)
        win.delegate = self
        win.center()
        let title = NSTextField(labelWithString: "Claude 环境检测")
        title.font = .boldSystemFont(ofSize: 20)
        let note = NSTextField(wrappingLabelWithString: "沿用 Claude Switcher 的全部 14 项检测标准；结果不能保证账号可用或防止 IP 泄漏。“保镖”仅检查已有安装。")
        note.textColor = .secondaryLabelColor
        target.textColor = .secondaryLabelColor
        target.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        retry = NSButton(title: "重新检测", target: self, action: #selector(start))
        settings = NSButton(title: "检测设置…", target: self, action: #selector(configure))
        export = NSButton(title: "导出结果…", target: self, action: #selector(exportReport))
        export.isEnabled = false
        let close = NSButton(title: "关闭", target: win, action: #selector(NSWindow.performClose(_:)))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [retry, settings, export, spacer, close])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        let stack = NSStackView(views: [title, note, target, status, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = win.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
            target.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        status.stringValue = "首次使用请确认检测设置。"
        window = win
    }

    @objc private func configure() {
        guard process == nil else { return }
        let value = configuration ?? ClaudeEnvironmentConfiguration()
        let alert = NSAlert()
        alert.messageText = "Claude 环境检测设置"
        alert.informativeText = "填写你期望的账号网络环境。首次预填原项目默认值（美国 / 纽约），请按实际情况修改。仅保存检测基准，不修改系统、代理或 Claude 配置。\n检测会访问 Cloudflare、ipinfo、Claude / Anthropic 和原版 STUN 服务；出口 IP 历史仅保存在本机。"
        alert.addButton(withTitle: "保存并检测")
        alert.addButton(withTitle: "取消")
        let popup = NSPopUpButton()
        popup.addItems(withTitles: ClaudeEnvironmentConfiguration.proxyTitles)
        popup.selectItem(at: ClaudeEnvironmentConfiguration.proxyModes.firstIndex(of: value.proxyMode) ?? 0)
        let country = NSTextField(string: value.country)
        let timezone = NSTextField(string: value.timezone)
        let locale = NSTextField(string: value.locale)
        let group = NSTextField(string: value.group)
        let form = NSGridView(views: [
            [NSTextField(labelWithString: "代理客户端"), popup],
            [NSTextField(labelWithString: "目标国家（如 US）"), country],
            [NSTextField(labelWithString: "目标时区"), timezone],
            [NSTextField(labelWithString: "目标地区（如 en_US）"), locale],
            [NSTextField(labelWithString: "Clash Verge 代理组"), group]
        ])
        form.rowSpacing = 10
        form.columnSpacing = 12
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).width = 280
        form.frame = NSRect(origin: .zero, size: form.fittingSize)
        alert.accessoryView = form
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        func trim(_ field: NSTextField) -> String { field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        let next = ClaudeEnvironmentConfiguration(proxyMode: ClaudeEnvironmentConfiguration.proxyModes[popup.indexOfSelectedItem], country: trim(country).uppercased(), timezone: trim(timezone), locale: trim(locale), group: trim(group))
        guard next.valid else {
            status.stringValue = "设置未保存：请填写两位国家代码、有效时区、地区格式和非空代理组。"
            return
        }
        next.save()
        configuration = next
        start()
    }

    @objc private func start() {
        guard process == nil else { return }
        guard let config = configuration else { configure(); return }
        report = nil
        reportDate = nil
        export.isEnabled = false
        target.stringValue = config.description
        text.string = ""
        guard let resource = Bundle.main.resourceURL else { status.stringValue = "找不到检测资源，请重新安装 AA Switch。"; return }
        let script = resource.appendingPathComponent("claude-account-environment.sh")
        guard FileManager.default.fileExists(atPath: script.path) else { status.stringValue = "缺少检测脚本，请重新安装 AA Switch。"; return }
        let job = Process()
        job.executableURL = URL(fileURLWithPath: "/bin/bash")
        job.arguments = [script.path, stateDirectory.path] + config.arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        job.environment = env
        let output = Pipe()
        job.standardOutput = output
        job.standardError = output
        job.standardInput = FileHandle.nullDevice
        generation = UUID()
        let token = generation
        do { try job.run() } catch { status.stringValue = "无法启动检测：\(error.localizedDescription)"; return }
        process = job
        retry.isEnabled = false
        settings.isEnabled = false
        export.isEnabled = false
        status.stringValue = "正在运行原版 14 项检测，通常需要数十秒…"
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, self.generation == token, job.isRunning else { return }
            job.terminate()
            self.status.stringValue = "检测超时，正在结束本次检测…"
        }
        watchdog = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: timeout)
        DispatchQueue.global(qos: .userInitiated).async {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            job.waitUntilExit()
            let result = ClaudeEnvironmentReport(raw: String(decoding: data, as: UTF8.self), exitCode: job.terminationStatus)
            DispatchQueue.main.async {
                guard self.process === job else { return }
                self.watchdog?.cancel()
                self.watchdog = nil
                self.process = nil
                self.retry.isEnabled = true
                self.settings.isEnabled = true
                guard self.generation == token else {
                    self.status.stringValue = "检测已取消，可以重新检测。"
                    return
                }
                self.report = result
                self.reportDate = Date()
                self.export.isEnabled = true
                self.status.stringValue = result.summary
                self.display(result)
            }
        }
    }

    private func display(_ report: ClaudeEnvironmentReport) {
        let content = NSMutableAttributedString(string: "")
        for name in ClaudeEnvironmentReport.names {
            let row = report.rows[name]
            let label: String
            let color: NSColor
            switch row?.state {
            case "ok": label = "通过"; color = .systemGreen
            case "warn": label = "提醒"; color = .systemOrange
            case "fail": label = "未通过"; color = .systemRed
            default: label = "未完成"; color = .secondaryLabelColor
            }
            content.append(NSAttributedString(string: "\(label)  \(name)\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: color]))
            if let detail = row?.detail, !detail.isEmpty {
                content.append(NSAttributedString(string: detail + "\n", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]))
            }
            content.append(NSAttributedString(string: "\n"))
        }
        if !report.complete {
            content.append(NSAttributedString(string: "原版脚本输出：\n" + report.raw, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.labelColor]))
        }
        text.textStorage?.setAttributedString(content)
        text.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    @objc private func exportReport() {
        guard let report = report else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Claude-环境检测.txt"
        panel.message = "结果包含出口 IP 及本机环境信息，请确认后再分享。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let date = reportDate.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        let output = "AA Switch \(appVersion) · Claude 环境检测\n\(date)\n\(configuration?.description ?? "")\n来源：Claude Switcher（MIT），commit 303cd1057cc1ab2f24cfac5b4c0a43094011caa1\n\(report.summary)\n\n\(report.raw)\n"
        do { try Data(output.utf8).write(to: url, options: [.atomic]) }
        catch { status.stringValue = "导出失败：\(error.localizedDescription)" }
    }

    func windowWillClose(_ notification: Notification) {
        watchdog?.cancel()
        watchdog = nil
        generation = UUID()
        if let job = process, job.isRunning { job.terminate() }
        // The reader clears process after exit; a second run cannot overlap local IP history writes.
    }
}
