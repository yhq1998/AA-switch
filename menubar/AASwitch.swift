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
    init(labels: [String], selected: Int?, enabled: Bool, segmentWidth: CGFloat, inset: CGFloat = 14, onSelect: @escaping (Int) -> Void) {
        self.labels = labels
        self.selected = selected
        self.enabled = enabled
        self.onSelect = onSelect
        super.init(frame: .zero)
        let height: CGFloat = 24
        var x = inset   // 菜单里 14：和普通菜单项的文字左对齐；窗口里 0
        for _ in labels { rects.append(NSRect(x: x, y: 4, width: segmentWidth, height: height)); x += segmentWidth }
        frame = NSRect(x: 0, y: 0, width: x + inset, height: height + 8)
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
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }   // 放在窗口里时，窗口不在前台也能一下点中
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
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
    private var pendingLaunchReveal = false
    private var panel: NSWindow?                        // 从访达 / 启动台 / 聚焦搜索打开时显示的窗口，内容和菜单一样
    private lazy var building = menu                    // render 正在往哪个菜单里加项（菜单本身，或给窗口用的临时菜单）
    private let revealNotification = Notification.Name(bundleID + ".reveal")
    private var needsRender = false
    private var products: [Product] { [codex, claude] }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if offerInstallFromDiskImage() { return }   // 要放在单实例检查前面：装新版时得先把已经在跑的旧版关掉
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != NSRunningApplication.current }
        if !others.isEmpty {
            // 已经在运行（多半是图标被刘海挡住、用户以为没开）：让正在运行的那个把菜单弹出来，自己退出
            DistributedNotificationCenter.default().postNotificationName(revealNotification, object: nil, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil); return
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(revealFromOtherInstance), name: revealNotification, object: nil)
        // 开机自启（launchd 按 LaunchAgent 启动时 XPC_SERVICE_NAME 就是 plist 的 Label）和应用内更新后的重开都安静地待在菜单栏；
        // 用户手动打开的，状态读完后把菜单弹出来，让人知道它开了、在哪
        let env = ProcessInfo.processInfo.environment
        pendingLaunchReveal = env["XPC_SERVICE_NAME"] != bundleID && !CommandLine.arguments.contains("--quiet")
        installEditMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.image = menubarImage()
        statusItem.button?.title = ""
        log("\(appName) \(appVersion) 启动，脚本：\(codex.script)、\(claude.script)")
        repairLoginItem()
        for p in products { ensureScriptInstalled(p) }
        refresh()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        checkUpdate()
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.checkUpdate() }
        if let out = ProcessInfo.processInfo.environment["AASWITCH_RENDER_MENU"], !out.isEmpty { renderMenuForScreenshot(to: out) }
    }

    // MARK: 给 README 出截图：设了环境变量 AASWITCH_RENDER_MENU=输出.png 时，等状态读完后自己点开菜单、拍成 PNG 然后退出。
    // 配合 CODEX_HOME / CLAUDE_CONFIG_DIR 指到一份演示数据用（做法见 docs/screenshots/README.md）。
    // 菜单是毛玻璃材质，后面得有东西才是平时看到的样子，所以把菜单弹在屏幕中间、后面垫一个渐变色的窗口，再把这块屏幕区域拍下来。
    // 程序没有屏幕录制权限时，拍到的只有自己的窗口（衬底 + 菜单），不会把别的应用拍进去。
    private var screenshotBackdrop: NSWindow?
    private func renderMenuForScreenshot(to path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self = self else { return }
            // 菜单打开期间主线程停在菜单的事件循环里，所以定时器要加到 common 模式才会触发
            let placeBackdrop = Timer(timeInterval: 1.0, repeats: false) { _ in
                guard let menuRect = self.menuWindowRect() else { self.log("截图菜单：没找到菜单窗口"); exit(1) }
                let area = menuRect.insetBy(dx: -32, dy: -32)   // CoreGraphics 坐标：原点在主屏左上角
                let screenHeight = NSScreen.screens.first?.frame.height ?? 0
                let window = NSWindow(contentRect: NSRect(x: area.minX, y: screenHeight - area.maxY, width: area.width, height: area.height),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                let gradient = CAGradientLayer()
                gradient.colors = [NSColor(srgbRed: 1.0, green: 0.89, blue: 0.925, alpha: 1).cgColor, NSColor(srgbRed: 0.79, green: 0.84, blue: 1.0, alpha: 1).cgColor]
                window.contentView?.wantsLayer = true
                gradient.frame = window.contentView?.bounds ?? .zero
                window.contentView?.layer?.addSublayer(gradient)
                window.level = .floating          // 在普通窗口之上、菜单之下
                window.ignoresMouseEvents = true
                window.orderFrontRegardless()
                self.screenshotBackdrop = window
                let capture = Timer(timeInterval: 0.8, repeats: false) { _ in
                    let ok = self.captureScreen(area, to: path)
                    self.log("截图菜单到 \(path)：\(ok ? "成功" : "失败")")
                    exit(ok ? 0 : 1)
                }
                RunLoop.main.add(capture, forMode: .common)
            }
            RunLoop.main.add(placeBackdrop, forMode: .common)
            // 不从菜单栏图标弹出，而是把同一个菜单弹在屏幕中间：系统菜单栏就算没有屏幕录制权限也会被拍进去，上面有别的应用的图标
            let screen = NSScreen.screens.first?.visibleFrame ?? .zero
            self.menu.popUp(positioning: nil, at: NSPoint(x: screen.midX - 160, y: screen.maxY - 120), in: nil)
        }
    }
    // 自己的菜单窗口在屏幕上的位置。菜单在弹出菜单那一层（101）；状态栏图标自己也是一个窗口，所以按高度取最大的
    private func menuWindowRect() -> CGRect? {
        let pid = ProcessInfo.processInfo.processIdentifier
        let rects = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 101 }
            .compactMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }
        return rects.max { $0.height < $1.height }
    }
    private func captureScreen(_ area: CGRect, to path: String) -> Bool {
        // CGWindowListCreateImage 在新 SDK 里被标成不可用（让人改用 ScreenCaptureKit），这里按符号名调用
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return false }
        // 1 = 屏幕上这块区域里的所有窗口；8 = 按屏幕的实际分辨率（Retina 下是 2 倍）
        guard let image = unsafeBitCast(symbol, to: CreateImage.self)(area, 1, 0, 8)?.takeRetainedValue() else { return false }
        // 裁成圆角
        let scale = CGFloat(image.width) / area.width
        let width = image.width, height = image.height
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return false }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        context.cgContext.addPath(CGPath(roundedRect: canvas, cornerWidth: 18 * scale, cornerHeight: 18 * scale, transform: nil))
        context.cgContext.clip()
        context.cgContext.draw(image, in: canvas)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
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
                guard self.spawnDetached("exec /bin/bash \(self.quote(launcher.path))") else {
                    self.log("更新失败：启动替换脚本失败")
                    self.render()
                    return
                }
                NSApp.terminate(nil)
            }
        }.resume()
    }
    // 退出前交给后台脚本收尾（替换自己、推出 dmg、重新打开）。脚本放到新的会话里跑：
    // 开机自启时本进程是 launchd 按 LaunchAgent 启动的，主进程一退出，launchd 会把同一进程组里的子进程一起杀掉，脚本就半路没了
    private func spawnDetached(_ script: String) -> Bool {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        let args = ["/bin/bash", "-c", script].map { strdup($0) } + [nil]
        defer { args.forEach { free($0) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, "/bin/bash", nil, &attr, args, environ) == 0
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
        # 旧版先挪到一边，新版放好并且真的跑起来了才删；任何一步不行就把旧版放回去重新打开，不会两个版本都没了
        target=\(quote(target)); new=\(quote(newApp.path)); work=\(quote(work.path)); old="$work/old.app"; logf=\(quote(logPath))
        say() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) 更新脚本：$*" >> "$logf"; }
        restore() { say "$1，恢复旧版"; rm -rf "$target"; mv "$old" "$target" && open -a "$target"; exit 1; }
        for _ in $(seq 1 150); do kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null || break; sleep 0.2; done
        mv "$target" "$old" || { say "挪开旧版失败"; open -a "$target"; exit 1; }
        mv "$new" "$target" || restore "放入新版失败"
        xattr -dr com.apple.quarantine "$target" 2>/dev/null
        open -a "$target" --args --quiet || restore "打开新版失败"
        sleep 8
        pgrep -f "$target/Contents/MacOS/" >/dev/null || restore "新版启动后没有在运行"
        say "已更新到 \(newVersion)"
        rm -rf "$work"
        """.write(to: script, atomically: true, encoding: .utf8)
        return script
    }

    // MARK: 直接在 dmg 里打开时（或被系统“应用转移”到随机的只读目录里运行），提议装进“应用程序”再从那里重开。
    // 不装的话：聚焦搜索和启动台找不到它，推出 dmg 或重启后图标就没了，开机自启记下的路径也会失效。
    private var runningFromTemporaryLocation: Bool {
        let path = Bundle.main.bundlePath
        if path.contains("/AppTranslocation/") { return true }
        guard path.hasPrefix("/Volumes/") else { return false }   // 外接硬盘上的可写目录不算，只管只读的 dmg
        return (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
    }
    // 被“应用转移”时 bundlePath 是随机目录，原位置（dmg 里）要问 Security 框架；拿不到就当没转移
    private func originalBundlePath() -> String {
        let path = Bundle.main.bundlePath
        guard path.contains("/AppTranslocation/"),
              let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let sym = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return path }
        typealias Fn = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let original = unsafeBitCast(sym, to: Fn.self)(URL(fileURLWithPath: path) as CFURL, nil)?.takeRetainedValue() as URL?
        return original?.path ?? path
    }
    // 返回 true 表示已经装好、正在退出并从新位置重开
    private func offerInstallFromDiskImage() -> Bool {
        guard runningFromTemporaryLocation else { return false }
        let original = originalBundlePath()
        let dir = FileManager.default.isWritableFile(atPath: "/Applications") ? "/Applications" : NSHomeDirectory() + "/Applications"
        let dest = dir + "/" + (original as NSString).lastPathComponent
        log("从临时位置启动：\(Bundle.main.bundlePath)（原位置 \(original)）")
        let alert = NSAlert()
        alert.messageText = "把 \(appName) 装进“应用程序”？"
        alert.informativeText = "现在是直接从安装盘里打开的。装好后会从“应用程序”重新打开，以后在启动台和聚焦搜索里都能找到，安装盘也会自动推出。\n\n不装的话，推出安装盘或重启后菜单栏图标就会消失。"
        alert.addButton(withTitle: "安装到应用程序")
        alert.addButton(withTitle: "暂不安装")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { log("用户选择暂不安装"); return false }
        if let failure = installCopy(to: dest) {
            log("安装到 \(dest) 失败：\(failure)")
            let error = NSAlert()
            error.messageText = "没能装进“应用程序”"
            error.informativeText = failure + "\n\n请在安装盘窗口里把 \(appName) 拖到 Applications 文件夹，再从“应用程序”打开。"
            error.alertStyle = .warning
            error.runModal()
            return false
        }
        // 装好的那份要等本进程退出后再打开，否则它的单实例检查会把自己关掉；dmg 也只能等本进程退出后才推得掉
        var volume = ""
        if let values = try? URL(fileURLWithPath: original).resourceValues(forKeys: [.volumeURLKey, .volumeIsReadOnlyKey]),
           values.volumeIsReadOnly == true, let url = values.volume, url.path.hasPrefix("/Volumes/") { volume = url.path }
        let script = """
        for _ in $(seq 1 150); do kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null || break; sleep 0.2; done
        \(volume.isEmpty ? "" : "hdiutil detach \(quote(volume)) -quiet 2>/dev/null")
        open -a \(quote(dest))
        """
        _ = spawnDetached(script)
        log("已装到 \(dest)，退出并从那里重新打开" + (volume.isEmpty ? "" : "，推出 \(volume)"))
        NSApp.terminate(nil)
        return true
    }
    // 复制到 dest，返回 nil 表示成功。已经在跑的旧版先关掉；dest 上的旧版移到废纸篓（出问题还能找回）
    private func installCopy(to dest: String) -> String? {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { $0 != NSRunningApplication.current }
        others.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while others.contains(where: { !$0.isTerminated }) && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest) {
                do { try fm.trashItem(at: URL(fileURLWithPath: dest), resultingItemURL: nil) } catch { try fm.removeItem(atPath: dest) }
            }
        } catch { return error.localizedDescription }
        let (code, out) = shell("/usr/bin/ditto", [Bundle.main.bundlePath, dest])
        guard code == 0 else { try? fm.removeItem(atPath: dest); return "复制失败：" + out }
        _ = shell("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest])
        return nil
    }

    // 菜单栏程序没有主菜单，⌘C / ⌘V / ⌘A 这类快捷键要靠“编辑”菜单转发；装一个不可见的即可
    private func installEditMenu() {
        let main = NSMenu()
        // 窗口开着时程序在前台、有自己的菜单栏，⌘W / ⌘Q 要能用
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "退出 \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; main.addItem(appItem)
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
        // 超过 1MB 就把当前日志改名成 .1（覆盖更早的那份），最多占 2MB
        if let size = (try? FileManager.default.attributesOfItem(atPath: logPath))?[.size] as? Int, size > 1_000_000 {
            try? FileManager.default.removeItem(atPath: logPath + ".1")
            try? FileManager.default.moveItem(atPath: logPath, toPath: logPath + ".1")
        }
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

    // MARK: 再次打开（在访达 / 启动台 / 聚焦搜索里双击）时把菜单弹出来。
    // 菜单栏放不下时，排在后面的图标会被藏到刘海后面（或被菜单栏管理工具折叠），用户就以为程序没开；所以把同一个菜单弹在屏幕上方中间，顶上说明图标在哪
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        log("再次打开")
        revealMenu()
        return false
    }
    @objc private func revealFromOtherInstance() {
        log("另一份程序被打开，已退出，这边弹出菜单")
        revealMenu()
    }
    private func revealMenu() {
        guard NSApp.modalWindow == nil else { return }
        DispatchQueue.main.async { [weak self] in self?.showWindow() }
    }

    // MARK: 窗口：把菜单的内容原样摆进一个普通窗口（分组标题、切换开关、说明、按钮），顶上加一句图标在哪。
    // 窗口开着时程序在 Dock 里显示图标（点 Dock 图标也会回到窗口），关掉后回到只在菜单栏
    private func showWindow() {
        if panel == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 400), styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = appName
            w.isReleasedWhenClosed = false
            w.delegate = self
            panel = w
        }
        guard let w = panel else { return }
        let wasVisible = w.isVisible
        refreshWindow()
        if !wasVisible, let screen = NSScreen.main?.visibleFrame {   // 放在屏幕上方偏中间
            w.setFrameTopLeftPoint(NSPoint(x: screen.midX - w.frame.width / 2, y: screen.maxY - screen.height * 0.12))
        }
        log("显示窗口")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel else { return }
        NSApp.setActivationPolicy(.accessory)
    }
    private func refreshWindow() {
        guard let w = panel else { return }
        let items = NSMenu()
        items.autoenablesItems = false
        building = items
        buildItems(forWindow: true)
        building = menu
        let content = windowContent(from: items)
        let top = w.frame.maxY
        w.contentView = content
        w.setContentSize(content.fittingSize)
        if w.isVisible { w.setFrameTopLeftPoint(NSPoint(x: w.frame.minX, y: top)) }   // 内容变高变矮时顶边不动
    }
    // 菜单项 → 窗口里的控件：不可点的项变文字，可点的变按钮（连着的几个排成一行），带勾的变复选框，子菜单变下拉按钮，分隔线照搬
    private func windowContent(from items: NSMenu) -> NSView {
        let width: CGFloat = 430
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 18, right: 16)
        stack.widthAnchor.constraint(equalToConstant: width + 32).isActive = true
        var buttonRow: NSStackView?
        func button(_ i: NSMenuItem) -> NSButton {
            let b = NSButton(title: i.title, target: i.target, action: i.action)
            b.bezelStyle = .rounded
            b.isEnabled = i.isEnabled
            return b
        }
        for i in items.items {
            let isPlainButton = i.view == nil && i.submenu == nil && !i.isSeparatorItem && i.action != nil && i.state == .off
                && i.attributedTitle == nil
            if !isPlainButton { buttonRow = nil }
            if i.isSeparatorItem {
                let line = NSBox()
                line.boxType = .separator
                stack.addArrangedSubview(line)
                line.widthAnchor.constraint(equalToConstant: width).isActive = true
                stack.setCustomSpacing(10, after: stack.arrangedSubviews[max(0, stack.arrangedSubviews.count - 2)])
                stack.setCustomSpacing(10, after: line)
            } else if let v = i.view {
                i.view = nil   // 先从菜单项上摘下来：临时菜单释放时，菜单项会把自己的 view 从窗口里移走
                v.translatesAutoresizingMaskIntoConstraints = false
                v.widthAnchor.constraint(equalToConstant: v.frame.width).isActive = true
                v.heightAnchor.constraint(equalToConstant: v.frame.height).isActive = true
                stack.addArrangedSubview(v)
            } else if let sub = i.submenu {
                let pop = NSPopUpButton(frame: .zero, pullsDown: true)
                let copy = sub.copy() as! NSMenu
                copy.insertItem(withTitle: i.title + "…", action: nil, keyEquivalent: "", at: 0)   // 下拉按钮拿第一项当按钮文字
                pop.menu = copy
                pop.controlSize = .small
                stack.addArrangedSubview(pop)
            } else if i.action != nil && i.state == .on || i.action == #selector(toggleLogin) {
                let box = NSButton(checkboxWithTitle: i.title, target: i.target, action: i.action)
                box.state = i.state
                stack.addArrangedSubview(box)
            } else if isPlainButton {
                if buttonRow == nil {
                    let row = NSStackView()
                    row.orientation = .horizontal
                    row.spacing = 8
                    stack.addArrangedSubview(row)
                    buttonRow = row
                }
                buttonRow?.addArrangedSubview(button(i))
            } else {
                let text = i.attributedTitle.map { NSMutableAttributedString(attributedString: $0) } ?? NSMutableAttributedString(
                    string: i.title, attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                                                  .foregroundColor: i.isEnabled ? NSColor.labelColor : NSColor.secondaryLabelColor])
                let label = NSTextField(wrappingLabelWithString: "")
                label.attributedStringValue = text
                label.preferredMaxLayoutWidth = width - (i.image == nil ? 0 : 24)
                label.isSelectable = false
                var view: NSView = label
                if let image = i.image {
                    let icon = NSImageView(image: image)
                    view = NSStackView(views: [icon, label])
                    stack.setCustomSpacing(8, after: stack.arrangedSubviews.last ?? label)
                }
                if i.action != nil {   // 可点的说明行（比如“还没配置 API 地址，点击填写…”）
                    let link = NSButton(title: "", target: i.target, action: i.action)
                    link.isBordered = false
                    link.attributedTitle = NSAttributedString(string: i.title, attributes: [
                        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.linkColor])
                    view = link
                }
                stack.addArrangedSubview(view)
            }
        }
        return stack
    }

    // MARK: 菜单打开时先用快速的 mode 命令刷新，再异步刷新完整状态
    func menuWillOpen(_ menu: NSMenu) {
        if !busy { readModes() }
        render()            // 菜单还没显示，这时重建是安全的
        menuOpen = true
        log("打开菜单，Codex \(mode[codex.name] ?? "?")，Claude \(mode[claude.name] ?? "?")，菜单项：" + menu.items.map { $0.isSeparatorItem ? "|" : ($0.isEnabled ? "[\($0.title)]" : $0.title) }.joined(separator: " / "))
        refreshStatusAsync()   // 读到的新状态等菜单关了再画，下次打开时就是新的
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
                if self.pendingLaunchReveal && !self.onboardingShown {
                    self.pendingLaunchReveal = false
                    self.revealMenu()
                }
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
        guard !onboardingShown, !UserDefaults.standard.bool(forKey: "onboardingDone"), !busy, !menuOpen else { return }
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
    // 依次对多个产品执行切换（每个产品内部的步骤也按顺序），前一个做完再做下一个；切到 API 的先确保配好
    private func runPlan(_ plan: [(Product, [[String]])]) {
        guard let first = plan.first else { return }
        let rest = Array(plan.dropFirst())
        if first.1.contains(where: { $0.first == "api" }) {
            ensureConfiguredThenSwitch(first.0, steps: first.1) { [weak self] in self?.runPlan(rest) }
        } else {
            doSwitch(first.0, steps: first.1) { [weak self] in self?.runPlan(rest) }
        }
    }

    // MARK: 切换
    @objc private func codexToApi() { ensureConfiguredThenSwitch(codex, steps: [["api"]]) }
    @objc private func claudeToApi() { ensureConfiguredThenSwitch(claude, steps: [["api"]] + (desktopMode == "gateway" ? [["desktop", "gateway"]] : [])) }
    // 切到 API 之前先确认地址和 key 都齐了：没有就弹配置表单，保存后再执行 steps；用户取消就什么都不做
    private func ensureConfiguredThenSwitch(_ p: Product, steps: [[String]], then: (() -> Void)? = nil) {
        let info = statusInfo(p)
        let url = info.first { Self.urlKeys.contains($0.key) }?.value ?? ""
        let configured = !url.isEmpty && url != "未配置"
        if configured && run(p, ["find-key", url]).code == 0 { doSwitch(p, steps: steps, then: then); return }
        log("\(p.name) 切到 API 前还没配好（地址：\(url.isEmpty ? "无" : url)），先弹配置表单")
        openConfigure(p) { [weak self] saved in
            guard let self = self else { return }
            if saved { self.doSwitch(p, steps: steps, then: then) } else { then?() }
        }
    }
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
    // then：表单关掉后的回调，参数是“保存成功了没有”；从“切到 API 但还没配好”的流程进来时用它接着切换
    private func openConfigure(_ p: Product, then: ((Bool) -> Void)? = nil) {
        var baseURL = "", headers = ""
        for line in run(p, ["config"]).out.split(separator: "\n") {
            if line.hasPrefix("base_url=") { baseURL = String(line.dropFirst(9)) }
            else if line.hasPrefix("headers=") { headers = String(line.dropFirst(8)) }
        }
        showConfigureForm(p, baseURL: baseURL, headers: headers, error: nil, then: then)
    }
    // 地址规范化：去空格和末尾斜杠；Codex 是 OpenAI 风格，只给了域名就补 /v1；Claude Code 自己会加 /v1，填了就去掉
    private func normalizeURL(_ raw: String, for p: Product) -> (String, String?) {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return ("", "请填写 API 地址。") }
        guard url.lowercased().hasPrefix("https://") || url.lowercased().hasPrefix("http://") else { return (url, "地址要以 https:// 开头，例如 \(p.urlPlaceholder)。") }
        guard url.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, !url.contains("\""), !url.contains("\\") else { return (url, "地址里不能有空格或引号。") }
        while url.hasSuffix("/") { url.removeLast() }
        let afterScheme = url.drop { $0 != ":" }.dropFirst(3)   // 去掉 https://
        guard let host = afterScheme.split(separator: "/").first, host.contains(".") else { return (url, "地址里看不到域名，例如 \(p.urlPlaceholder)。") }
        if p.resource == "codex-mode" {
            if !afterScheme.contains("/") { url += "/v1" }
        } else if url.hasSuffix("/v1") {
            url = String(url.dropLast(3))
        }
        return (url, nil)
    }
    // 用 key 探测地址：请求 models 接口。2xx 通过；401/403 是 key 不对；其他情况告诉用户但允许坚持保存
    // 网关自己给的原因（key 无效、已过期、额度用完……）一并显示并记进日志，否则用户和诊断信息里都只看得到一个状态码
    private func probe(_ p: Product, url: String, key: String, headers: String) -> (ok: Bool, message: String?, blocking: Bool) {
        let endpoint = p.resource == "codex-mode" ? url + "/models" : url + "/v1/models"
        var args = ["-s", "-m", "12", "-w", "\n%{http_code}", endpoint, "-H", "Authorization: Bearer " + key]
        for pair in headers.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, !kv[0].isEmpty { args += ["-H", kv[0] + ": " + kv[1]] }
        }
        let (code, out) = shell("/usr/bin/curl", args)
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = Int(trimmed.suffix(3)) ?? 0
        let said = status >= 300 ? gatewayMessage(String(trimmed.dropLast(3))) : nil
        log("\(p.name) 配置校验 \(endpoint) → " + (code != 0 || status == 0 ? "连不上（curl 退出码 \(code)）" : "HTTP \(status)") + (said.map { "，网关：\($0)" } ?? ""))
        if code != 0 || status == 0 { return (false, "连不上 \(endpoint)（超时或域名不对）。", false) }
        let reason = said.map { "网关返回：\($0)。" } ?? ""
        switch status {
        case 200..<300: return (true, nil, false)
        case 401, 403: return (false, "这个 key 在 \(url) 上被拒绝（HTTP \(status)）。\(reason)每个网关的 key 不通用，请填该地址对应的 key；如果确认没填错，可能是 key 已过期、被禁用或额度用完，请到网关后台看一下。", true)
        case 404: return (false, "地址能连上，但 \(endpoint) 不存在（HTTP 404），地址的路径可能不对。\(reason)", false)
        default: return (false, "地址返回了 HTTP \(status)，可能不是一个兼容的网关。\(reason)", false)
        }
    }
    // 从出错响应里取网关的说明：{"error":{"message":…}}、{"error":"…"}、{"message":…}；去掉请求 ID，遮住里面带的 key 片段
    private func gatewayMessage(_ body: String) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else { return nil }
        let nested = (obj["error"] as? [String: Any])?["message"] as? String
        guard var text = nested ?? obj["error"] as? String ?? obj["message"] as? String else { return nil }
        text = text.replacingOccurrences(of: #"\s*[(（]\s*request id[^)）]*[)）]"#, with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"sk-[A-Za-z0-9_*\-]+"#, with: "sk-…", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 200 { text = String(text.prefix(200)) + "…" }
        return text.isEmpty ? nil : text
    }
    // key：出错后重新弹表单时带上用户刚填的，不要换成钥匙串里的（新地址通常还没存过，会把刚粘贴的 key 清空）
    private func showConfigureForm(_ p: Product, baseURL: String, headers: String, key typedKey: String? = nil, error: String?, then: ((Bool) -> Void)? = nil) {
        let alert = NSAlert()
        alert.messageText = "配置 \(p.name) API"
        alert.informativeText = error ?? (p.urlHint + " key 只保存在 macOS 钥匙串里，按地址域名保存，Codex 和 Claude Code 用同一个网关时共用一个 key。换地址时记得把 key 也换成该地址对应的。")
        if let error = error { alert.alertStyle = .warning; log("\(p.name) 配置表单提示：\(error)") }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 150))
        func row(_ title: String, _ field: NSTextField, y: CGFloat, height: CGFloat = 24) {
            let label = NSTextField(labelWithString: title)
            label.frame = NSRect(x: 0, y: y + height - 22, width: 96, height: 20); label.alignment = .right
            field.frame = NSRect(x: 104, y: y, width: 336, height: height)
            view.addSubview(label); view.addSubview(field)
        }
        // 地址和请求头是单行：太长时在框里横向滚动，而不是折到看不见的第二行
        func singleLine(_ field: NSTextField) {
            field.cell?.usesSingleLineMode = true; field.cell?.wraps = false; field.cell?.isScrollable = true
        }
        let urlField = NSTextField(); urlField.stringValue = baseURL; urlField.placeholderString = p.urlPlaceholder
        let headerField = NSTextField(); headerField.stringValue = headers; headerField.placeholderString = "名称=值，多个用逗号分隔；通常留空"
        singleLine(urlField); singleLine(headerField)
        // 明文显示，并回填当前地址已保存的 key，方便核对。key 很长，给四行高、等宽小字、按字符折行，整个 key 都看得到
        let keyField = NSTextField()
        keyField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        keyField.cell?.wraps = true; keyField.cell?.isScrollable = false
        keyField.cell?.lineBreakMode = .byCharWrapping
        let savedKey = typedKey != nil || baseURL.isEmpty ? "" : run(p, ["key", baseURL]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        keyField.stringValue = typedKey ?? savedKey
        keyField.placeholderString = "sk-…"
        row("API 地址", urlField, y: 120); row("额外请求头", headerField, y: 80); row("API key", keyField, y: 8, height: 56)
        urlField.nextKeyView = headerField; headerField.nextKeyView = keyField; keyField.nextKeyView = urlField
        alert.accessoryView = view
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = urlField
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { log("\(p.name) 配置表单：取消"); then?(false); return }
        let hdr = headerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // key 里不会有空白和不可见字符；粘贴带进来的换行、零宽空格一并去掉
        let key = String(String.UnicodeScalarView(keyField.stringValue.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0)
        }))
        let retype: String? = key.isEmpty ? nil : key
        let (url, urlError) = normalizeURL(urlField.stringValue, for: p)
        if let urlError = urlError { showConfigureForm(p, baseURL: url, headers: hdr, key: retype, error: urlError, then: then); return }
        if !key.unicodeScalars.allSatisfy({ $0.isASCII }) {
            showConfigureForm(p, baseURL: url, headers: hdr, key: retype, error: "API key 里有中文或全角字符，可能把 key 前后的文字一起复制进来了，请只粘贴 key 本身。", then: then); return
        }
        // key 留空时看这个地址有没有存过（Codex 还会尝试当前在用的 / 旧版条目）
        let keyForProbe = key.isEmpty ? (run(p, ["find-key", url]).code == 0 ? run(p, ["key", url]).out.trimmingCharacters(in: .whitespacesAndNewlines) : "") : key
        if keyForProbe.isEmpty {
            showConfigureForm(p, baseURL: url, headers: hdr, error: "这个地址还没有保存过 key，请填写 API key。", then: then); return
        }
        let check = probe(p, url: url, key: keyForProbe, headers: hdr)
        if !check.ok {
            if check.blocking {
                // 最常见的情况：改了地址，但 key 框里还是原地址回填的那个
                let oldHost = URL(string: baseURL)?.host ?? baseURL
                let keptOld = !savedKey.isEmpty && key == savedKey && URL(string: url)?.host != oldHost
                let hint = keptOld ? "\n\n你改了地址，但 API key 还是原来 \(oldHost) 的那个，请换成新地址对应的 key。" : ""
                showConfigureForm(p, baseURL: url, headers: hdr, key: retype, error: (check.message ?? "") + hint, then: then); return
            }
            let ask = NSAlert()
            ask.messageText = "地址校验没有通过"
            ask.informativeText = (check.message ?? "") + "\n\n可以返回修改，也可以坚持保存。"
            ask.alertStyle = .warning
            ask.addButton(withTitle: "返回修改")
            ask.addButton(withTitle: "仍然保存")
            if ask.runModal() == .alertFirstButtonReturn { showConfigureForm(p, baseURL: url, headers: hdr, key: retype, error: nil, then: then); return }
            log("\(p.name) 配置校验没通过，用户选择仍然保存")
        }
        let result = run(p, ["configure"],
                         extraEnv: [p.configureEnvPrefix + "_BASE_URL": url, p.configureEnvPrefix + "_HEADERS": hdr, p.configureEnvPrefix + "_KEY_STDIN": "1"],
                         input: key + "\n")
        if result.code != 0 { showConfigureForm(p, baseURL: url, headers: hdr, key: retype, error: result.err.replacingOccurrences(of: "错误：", with: ""), then: then); return }
        log("\(p.name) 配置已保存：\(url)")
        if let then = then {   // 从切换流程进来的：保存完接着切，不再弹“已保存”
            refresh()
            then(true)
            return
        }
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
            writeLoginItem()
        }
        render()
    }
    private func writeLoginItem() {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        // AbandonProcessGroup：退出时别让 launchd 顺手杀掉交给后台的收尾脚本（见 spawnDetached）
        let plist: [String: Any] = ["Label": bundleID, "ProgramArguments": [exe], "RunAtLoad": true, "AbandonProcessGroup": true]
        try? FileManager.default.createDirectory(atPath: (agentPath as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            FileManager.default.createFile(atPath: agentPath, contents: data)
        }
    }
    // 以前在 dmg 里（或别的位置）开过自启的，记下的路径会失效；从正式位置启动时改成当前路径
    private func repairLoginItem() {
        guard loginEnabled, !runningFromTemporaryLocation, let exe = Bundle.main.executablePath,
              let data = FileManager.default.contents(atPath: agentPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let old = (plist["ProgramArguments"] as? [String])?.first,
              old != exe || plist["AbandonProcessGroup"] as? Bool != true else { return }
        log("更新开机自启：\(old) → \(exe)")
        writeLoginItem()
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
        if panel?.isVisible == true { refreshWindow() }
        if menuOpen {
            // 菜单显示期间不重建：内容高度一变，菜单窗口会保持底边不动地缩放，顶上和菜单栏之间空出一截（或者往上顶）。
            // 关闭后再刷新
            needsRender = true
            updateIcon()
            return
        }
        needsRender = false
        updateIcon()
        menu.removeAllItems()
        buildItems(forWindow: false)
    }
    private func buildItems(forWindow: Bool) {
        let menu = building
        if forWindow {
            let hint = NSMenuItem()
            hint.attributedTitle = NSAttributedString(
                string: "\(appName) 平时在屏幕右上角的菜单栏里，点图标就能切换。看不到图标的话，多半是被刘海挡住或被折叠了：按住 ⌘ 把它往右拖，或者退出一些别的菜单栏图标。",
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor])
            hint.isEnabled = false
            menu.addItem(hint)
            menu.addItem(.separator())
        }
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
        let menu = building
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
            row.view = SegmentRow(labels: [p.accountTitle, "API"], selected: selected, enabled: !busy, segmentWidth: segmentWidth, inset: building === self.menu ? 14 : 0) { [weak self] i in
                guard let self = self else { return }
                let on = i == 1
                self.menu.cancelTracking()
                var steps: [[String]] = []
                if on {
                    if m != "api" { steps.append(["api"]) }
                    if desktop && self.desktopMode != "gateway" { steps.append(["desktop", "gateway"]) }
                    self.ensureConfiguredThenSwitch(p, steps: steps)
                } else {
                    if m != p.accountWord { steps.append([p.accountWord]) }
                    if desktop && self.desktopMode == "gateway" { steps.append(["desktop", "account"]) }
                    self.doSwitch(p, steps: steps)
                }
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
        building.addItem(i)
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

// 新的菜单栏图标默认排在最左边，刘海屏上最容易被挡住。第一次运行时让它排到靠右的位置（数值是离屏幕右边缘的距离），
// 用户按住 ⌘ 拖过之后系统会记下新位置，这里不再动
let iconPositionKey = "NSStatusItem Preferred Position Item-0"
if UserDefaults.standard.object(forKey: iconPositionKey) == nil { UserDefaults.standard.set(250.0, forKey: iconPositionKey) }
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
