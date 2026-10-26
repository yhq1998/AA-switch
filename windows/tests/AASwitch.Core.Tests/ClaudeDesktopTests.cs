using System.Text.Json.Nodes;
using System.Diagnostics;
using AASwitch.Core;

namespace AASwitch.Core.Tests;

public sealed class ClaudeDesktopTests : IDisposable
{
    const string Acct = "11111111-2222-3333-4444-555555555555", Org = "66666666-7777-8888-9999-000000000000";
    readonly string _root = Directory.CreateTempSubdirectory("aaswitch-desktop-").FullName;
    readonly AppPaths _paths;
    readonly List<string> _said = [];
    readonly FakeApp _app = new();
    readonly string _local, _roaming, _pkg;

    public ClaudeDesktopTests()
    {
        _paths = new AppPaths(Path.Combine(_root, "home"));
        _local = Path.Combine(_root, "Local");
        _roaming = Path.Combine(_root, "Roaming");
        _pkg = Path.Combine(_local, "Packages", "Claude_pzs8sxrjxfjjc");
        Directory.CreateDirectory(Path.Combine(_pkg, "LocalCache", "Roaming", "Claude"));
        Directory.CreateDirectory(_roaming);
        Directory.CreateDirectory(_paths.ClaudeHome);
        File.WriteAllText(_paths.ClaudeGlobalState, $$"""{ "oauthAccount": { "accountUuid": "{{Acct}}", "organizationUuid": "{{Org}}" } }""");
    }
    public void Dispose() => Directory.Delete(_root, recursive: true);

    sealed class FakeApp : IDesktopApp
    {
        public bool IsRunning;
        public List<string> Calls = [];
        public Action? OnQuit;
        public bool Running() => IsRunning;
        public void Quit() { Calls.Add("quit"); OnQuit?.Invoke(); IsRunning = false; }
        public void Open() { Calls.Add("open"); IsRunning = true; }
        public void OpenForAccountSignIn() { Calls.Add("open-account"); IsRunning = true; }
    }

    ClaudeDesktopPaths Dp => ClaudeDesktopPaths.Discover(_local, _roaming);
    ClaudeDesktop New() => new(Dp, _paths, _app, _said.Add);
    string Account => Path.Combine(_pkg, "LocalCache", "Roaming", "Claude");
    string Gateway3p => Path.Combine(_local, "Claude-3p");
    static JsonObject Read(string f) => (JsonObject)JsonNode.Parse(File.ReadAllText(f))!;
    static void Write(string f, string text) { Directory.CreateDirectory(Path.GetDirectoryName(f)!); File.WriteAllText(f, text); }

    // ---------- 位置 ----------
    [Fact]
    public void Discover_store_install()
    {
        Directory.CreateDirectory(Path.Combine(_local, "Packages", "Claude_notapackage"));
        var dp = Dp;
        Assert.Equal(_pkg, dp.PackageDir);
        Assert.Equal("Claude_pzs8sxrjxfjjc", dp.PackageFamily);
        Assert.Equal(Account, dp.AccountDir);
        Assert.Equal(Gateway3p, dp.GatewayDir);
        Assert.True(dp.Installed);
        Assert.Equal(Path.Combine(_roaming, "Claude", "local-agent-mode-sessions"), dp.AppView(Path.Combine(Account, "local-agent-mode-sessions")));
        Assert.Equal(Path.Combine(_local, "Foo"), dp.AppView(Path.Combine(_pkg, "LocalCache", "Local", "Foo")));
        Assert.Equal(Gateway3p, dp.AppView(Gateway3p));
    }

    [Fact]
    public void Discover_installer_or_nothing()
    {
        Directory.Delete(Path.Combine(_local, "Packages"), recursive: true);
        Assert.False(Dp.Installed);
        Directory.CreateDirectory(Path.Combine(_local, "AnthropicClaude"));
        Directory.CreateDirectory(Path.Combine(_roaming, "Claude-3p"));
        var dp = Dp;
        Assert.True(dp.Installed);
        Assert.Null(dp.PackageFamily);
        Assert.Equal(Path.Combine(_roaming, "Claude"), dp.AccountDir);
        Assert.Equal(Path.Combine(_roaming, "Claude-3p"), dp.GatewayDir);   // %LOCALAPPDATA% 下没有时沿用 %APPDATA% 下已有的
        Assert.Equal("absent", new ClaudeDesktop(ClaudeDesktopPaths.Discover(Path.Combine(_root, "x"), Path.Combine(_root, "y")), _paths, _app, _said.Add).ModeWord());
    }

    // ---------- 模式和网关配置 ----------
    void SeedGateway(string? mode, bool disableSignIn = false)
    {
        var cfg = new JsonObject { ["other"] = 1 };
        if (mode is not null) cfg["deploymentMode"] = mode;
        Write(Path.Combine(Gateway3p, "claude_desktop_config.json"), cfg.ToJsonString());
        var lib = Path.Combine(Gateway3p, "configLibrary");
        Write(Path.Combine(lib, "_meta.json"), """{"appliedId":"fixture","entries":[{"id":"fixture","name":"Mine"}]}""");
        Write(Path.Combine(lib, "fixture.json"), new JsonObject {
            ["inferenceProvider"] = "gateway", ["inferenceGatewayApiKey"] = "fixture-key",
            ["inferenceGatewayBaseUrl"] = "https://gateway.example.test", ["disableDeploymentModeChooser"] = disableSignIn,
        }.ToJsonString());
    }

    [Theory]
    [InlineData(null, false, "gateway")]
    [InlineData("", false, "gateway")]
    [InlineData("3p", false, "gateway")]
    [InlineData("1p", false, "account")]
    [InlineData("1p", true, "gateway")]
    public void Saved_gateway_uses_actual_Claude_mode_rules(string? mode, bool disabled, string expected)
    {
        SeedGateway(mode, disabled);
        Assert.Equal(expected, New().ModeWord());
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void Account_switch_restores_sign_in_and_opens_explicit_login(bool running)
    {
        SeedGateway("3p", true);
        _app.IsRunning = running;
        _app.OnQuit = () => Write(Path.Combine(Gateway3p, "claude_desktop_config.json"), """{"deploymentMode":"3p","other":1}""");
        New().SwitchToAccount();
        var cfg = Read(Path.Combine(Gateway3p, "claude_desktop_config.json"));
        Assert.Equal("1p", (string)cfg["deploymentMode"]!);
        Assert.Equal(1, (int)cfg["other"]!);
        var entry = Read(Path.Combine(Gateway3p, "configLibrary", "fixture.json"));
        Assert.False((bool)entry["disableDeploymentModeChooser"]!);
        Assert.Equal("fixture-key", (string)entry["inferenceGatewayApiKey"]!);
        Assert.Equal("account", New().ModeWord());
        Assert.Equal(running ? ["quit", "open-account"] : new[] { "open-account" }, _app.Calls);
        var backups = Directory.GetDirectories(_paths.ClaudeBackups);
        var saved = Read(Path.Combine(backups.Single(), "desktop", "configLibrary", "fixture.json"));
        Assert.True((bool)saved["disableDeploymentModeChooser"]!);
    }

    [Fact]
    public void Gateway_switch_keeps_account_sign_in_available()
    {
        SeedGateway("1p", true);
        New().SwitchToGateway("https://gateway.example.test", "new-fixture-key");
        var entry = Read(Path.Combine(Gateway3p, "configLibrary", "fixture.json"));
        Assert.False((bool)entry["disableDeploymentModeChooser"]!);
        Assert.Equal("gateway", New().ModeWord());
        Assert.Empty(_app.Calls);
    }

    [Theory]
    [InlineData(null)]
    [InlineData(false)]
    [InlineData(true)]
    public void Gateway_switch_enables_mcp_tool_search(bool? previous)
    {
        SeedGateway("3p");
        var file = Path.Combine(Gateway3p, "configLibrary", "fixture.json");
        var entry = Read(file);
        if (previous.HasValue) entry["toolSearchEnabled"] = previous.Value;
        entry["customSetting"] = new JsonObject { ["keep"] = true };
        Write(file, entry.ToJsonString());

        New().SwitchToGateway("https://gateway.example.test", "fixture-key");
        var applied = Read(file);
        Assert.True((bool?)applied["toolSearchEnabled"]);
        Assert.True((bool)applied["customSetting"]!["keep"]!);
        var backup = Directory.GetDirectories(_paths.ClaudeBackups).Single();
        var saved = Read(Path.Combine(backup, "desktop", "configLibrary", "fixture.json"));
        Assert.Equal(previous, (bool?)saved["toolSearchEnabled"]);

        New().SwitchToAccount();
        Assert.True((bool?)Read(file)["toolSearchEnabled"]);
    }

    [Fact]
    public void New_gateway_enables_mcp_tool_search()
    {
        New().SwitchToGateway("https://gateway.example.test", "fixture-key");
        var library = Path.Combine(Gateway3p, "configLibrary");
        var id = (string)Read(Path.Combine(library, "_meta.json"))["appliedId"]!;
        Assert.True((bool?)Read(Path.Combine(library, id + ".json"))["toolSearchEnabled"]);
    }

    [Fact]
    public void Windows_installer_receives_explicit_account_sign_in_argument()
    {
        if (!OperatingSystem.IsWindows()) return;
        var dp = Dp with { PackageDir = null };
        Directory.CreateDirectory(dp.InstallerDir);
        var exe = Path.Combine(dp.InstallerDir, "claude.exe");
        // A real executable records what the Windows launcher passes to the installed app.
        const string source = "using System; using System.IO; using System.Diagnostics; public class Probe { public static void Main(string[] args) { File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, \"pid.txt\"), Process.GetCurrentProcess().Id.ToString()); File.WriteAllLines(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, \"args.txt\"), args); } }";
        var compile = new ProcessStartInfo("powershell.exe") { UseShellExecute = false, RedirectStandardError = true, RedirectStandardOutput = true };
        foreach (var arg in new[] { "-NoProfile", "-NonInteractive", "-Command", "Add-Type -TypeDefinition '" + source + "' -OutputAssembly '" + exe.Replace("'", "''") + "' -OutputType ConsoleApplication" })
            compile.ArgumentList.Add(arg);
        using var compiler = Process.Start(compile)!;
        Assert.True(compiler.WaitForExit(30000));
        Assert.True(compiler.ExitCode == 0, compiler.StandardError.ReadToEnd());
        new WindowsDesktopApp(dp).OpenForAccountSignIn();
        var output = Path.Combine(dp.InstallerDir, "args.txt");
        Assert.True(SpinWait.SpinUntil(() => File.Exists(output) && new FileInfo(output).Length > 0, TimeSpan.FromSeconds(10)));
        var pid = int.Parse(File.ReadAllText(Path.Combine(dp.InstallerDir, "pid.txt")));
        try
        {
            using var probe = Process.GetProcessById(pid);
            Assert.True(probe.WaitForExit(10000));
        }
        catch (ArgumentException) { } // Probe already exited before its process handle was acquired.
        Assert.Equal(new[] { "--claude-first-party-sign-in" }, File.ReadAllLines(output));
    }

    [Theory]
    [InlineData("1p", false)]
    [InlineData("3p", true)]
    public void Model_update_applies_immediately_only_in_gateway_mode(string mode, bool restart)
    {
        SeedGateway(mode);
        _app.IsRunning = true;
        var d = New();
        var models = new[] { "claude-opus-5-5", "claude-sonnet-5" };
        d.UpdateModels(models, "https://gateway.example.test", "fixture-key");
        Assert.Equal(models, d.Models());
        Assert.Equal(restart ? new[] { "quit", "open" } : Array.Empty<string>(), _app.Calls);
        if (restart)
            Assert.Equal("claude-opus-5-5[1m]", (string)Read(Path.Combine(Gateway3p, "configLibrary", "fixture.json"))["inferenceModels"]![0]!);
        var before = File.ReadAllText(_paths.ClaudeConf);
        Assert.Throws<SwitchException>(() => d.UpdateModels(["bad name"], "https://gateway.example.test", "fixture-key"));
        Assert.Equal(before, File.ReadAllText(_paths.ClaudeConf));
        _app.Calls.Clear();
        d.UpdateModels(models, "https://gateway.example.test", "fixture-key");
        Assert.Empty(_app.Calls);
    }

    [Fact]
    public void Gateway_then_account_writes_config_and_restarts_app()
    {
        Write(Path.Combine(Gateway3p, "claude_desktop_config.json"), """{ "deploymentMode": "1p", "other": 1 }""");
        _app.IsRunning = true;
        var d = New();
        Assert.Equal("account", d.ModeWord());

        d.SwitchToGateway("https://gw.example.com/", "sk-1");
        Assert.Equal(["quit", "open"], _app.Calls);
        Assert.Equal("gateway", d.ModeWord());
        var cfg = Read(Path.Combine(Gateway3p, "claude_desktop_config.json"));
        Assert.Equal("3p", (string)cfg["deploymentMode"]!);
        Assert.Equal(1, (int)cfg["other"]!);
        var meta = Read(Path.Combine(Gateway3p, "configLibrary", "_meta.json"));
        var id = (string)meta["appliedId"]!;
        Assert.Equal("AA Switch", (string)meta["entries"]![0]!["name"]!);
        var g = Read(Path.Combine(Gateway3p, "configLibrary", id + ".json"));
        Assert.Equal("https://gw.example.com", (string)g["inferenceGatewayBaseUrl"]!);
        Assert.Equal("sk-1", (string)g["inferenceGatewayApiKey"]!);
        Assert.Equal("bearer", (string)g["inferenceGatewayAuthScheme"]!);
        Assert.Equal(["*"], g["coworkEgressAllowedHosts"]!.AsArray().Select(x => (string)x!).ToArray());
        Assert.Equal(ClaudeDesktop.DefaultModels.Split(',').Select(m => m + "[1m]"), g["inferenceModels"]!.AsArray().Select(x => (string)x!).ToArray());
        Assert.Equal(["桌面应用：网关模式（https://gw.example.com）", "桌面模型：默认 claude-opus-5-5，共 4 个"], d.Status());

        d.SwitchToAccount();
        Assert.Equal("account", d.ModeWord());
        Assert.Equal("1p", (string)Read(Path.Combine(Gateway3p, "claude_desktop_config.json"))["deploymentMode"]!);
        Assert.Equal(id, (string)Read(Path.Combine(Gateway3p, "configLibrary", "_meta.json"))["appliedId"]!);   // 网关配置留着
        var bk = Directory.GetDirectories(_paths.ClaudeBackups);
        Assert.True(File.Exists(Path.Combine(bk.Max()!, "desktop", "claude_desktop_config.json")));
    }

    [Fact]
    public void Gateway_reuses_applied_entry_and_conf_overrides()
    {
        var lib = Path.Combine(Gateway3p, "configLibrary");
        Write(Path.Combine(lib, "_meta.json"), """{ "appliedId": "abc-1", "entries": [ { "id": "abc-1", "name": "Mine" } ] }""");
        Write(Path.Combine(lib, "abc-1.json"), """{ "inferenceProvider": "bedrock", "inferenceCredentialKind": "static", "coworkEgressAllowedHosts": ["gw.example.com"] }""");
        File.WriteAllText(_paths.ClaudeConf, "desktop_base_url=https://desk.example.com\ndesktop_models=m1, m2[1m]\n");
        var d = New();
        d.SwitchToGateway("https://gw.example.com", "sk-2");
        Assert.Empty(_app.Calls);   // 没开着就不开
        Assert.Contains(_said, s => s.Contains("下次打开时生效"));
        var g = Read(Path.Combine(lib, "abc-1.json"));
        Assert.Equal("gateway", (string)g["inferenceProvider"]!);
        Assert.Equal("static", (string)g["inferenceCredentialKind"]!);
        Assert.Equal("https://desk.example.com", (string)g["inferenceGatewayBaseUrl"]!);
        Assert.Equal(["*"], g["coworkEgressAllowedHosts"]!.AsArray().Select(x => (string)x!).ToArray());
        Assert.Equal(["m1[1m]", "m2[1m]"], g["inferenceModels"]!.AsArray().Select(x => (string)x!).ToArray());
        Assert.Single(Read(Path.Combine(lib, "_meta.json"))["entries"]!.AsArray());
    }

    [Fact]
    public void Reopens_even_when_writing_fails()
    {
        Write(Path.Combine(Gateway3p, "claude_desktop_config.json"), "not json");
        _app.IsRunning = true;
        Assert.Throws<SwitchException>(() => New().SwitchToAccount());
        Assert.Equal(["quit", "open"], _app.Calls);
    }

    // ---------- Code 会话列表 ----------
    [Fact]
    public void Code_sessions_fill_in_both_ways_and_respect_deleted()
    {
        var a = Path.Combine(Account, "claude-code-sessions", Acct, Org);
        var other = Path.Combine(Account, "claude-code-sessions", Acct, "other-org");
        var b = Path.Combine(Gateway3p, "claude-code-sessions", "c0062ea9-0000-0000-0000-000000000000", "00000000-0000-0000-0000-000000000000");
        Write(Path.Combine(a, "local_1.json"), "{}");
        Write(Path.Combine(a, "local_2.json"), "{}");
        Write(Path.Combine(other, "local_x.json"), "{}");
        Write(Path.Combine(b, "local_3.json"), """{"b":1}""");
        Write(Path.Combine(b, "deleted_2"), "");
        Write(Path.Combine(Account, "claude_desktop_config.json"), """{ "preferences": { "localAgentModeTrustedFolders": ["C:\\a"] } }""");
        Write(Path.Combine(Gateway3p, "claude_desktop_config.json"), """{ "deploymentMode": "3p", "preferences": { "localAgentModeTrustedFolders": ["C:\\b"] } }""");

        new DesktopSessions(Dp, _paths, _said.Add).SyncCode();
        Assert.True(File.Exists(Path.Combine(b, "local_1.json")));
        Assert.False(File.Exists(Path.Combine(b, "local_2.json")));
        Assert.False(File.Exists(Path.Combine(b, "local_x.json")));
        Assert.Equal("""{"b":1}""", File.ReadAllText(Path.Combine(a, "local_3.json")));
        Assert.Contains("会话列表已同步（补齐 2 条）。", _said);
        foreach (var f in new[] { Account, Gateway3p })
            Assert.Equal(["C:\\a", "C:\\b"], Read(Path.Combine(f, "claude_desktop_config.json"))["preferences"]!["localAgentModeTrustedFolders"]!.AsArray().Select(x => (string)x!).ToArray());
        Assert.Equal("3p", (string)Read(Path.Combine(Gateway3p, "claude_desktop_config.json"))["deploymentMode"]!);
    }

    [Fact]
    public void Code_sessions_wait_for_gateway_dir()
    {
        Write(Path.Combine(Account, "claude-code-sessions", Acct, Org, "local_1.json"), "{}");
        new DesktopSessions(Dp, _paths, _said.Add).SyncCode();
        Assert.Contains(_said, s => s.StartsWith("会话列表暂时没法同步（网关模式还没初始化过"));
    }

    // ---------- Cowork ----------
    [Fact]
    public void Plan_follows_ledger()
    {
        var a = new Dictionary<string, long> { ["new_a"] = 5, ["same"] = 7, ["a_newer"] = 9, ["both"] = 20, ["gone_b"] = 3, ["first_a"] = 8 };
        var b = new Dictionary<string, long> { ["new_b"] = 6, ["same"] = 7, ["a_newer"] = 4, ["both"] = 21, ["first_a"] = 2 };
        var led = new Dictionary<string, long> { ["a_newer"] = 4, ["both"] = 10, ["gone_b"] = 3, ["dead"] = 1 };
        var plan = DesktopSessions.Plan(a, b, led).ToDictionary(p => p.Name);
        Assert.Equal("a2b", plan["new_a"].Action);
        Assert.Equal("b2a", plan["new_b"].Action);
        Assert.Equal("keep", plan["same"].Action);
        Assert.Equal("a2b", plan["a_newer"].Action);
        Assert.Equal(9, plan["a_newer"].New);
        Assert.Equal("conflict", plan["both"].Action);
        Assert.Equal(10, plan["both"].Old);
        Assert.Equal("gone", plan["gone_b"].Action);
        Assert.Equal("a2b", plan["first_a"].Action);   // 没记录：谁新用谁
        Assert.False(plan.ContainsKey("dead"));
    }

    [Fact]
    public void Cowork_copy_rewrites_paths_to_app_view()
    {
        var a = Path.Combine(Account, "local-agent-mode-sessions", Acct, Org);
        var b = Path.Combine(Gateway3p, "local-agent-mode-sessions", "c0062ea9", "00000000");
        // 账号模式里记录的路径是应用眼里的 %APPDATA%\Claude\…（系统替它重定向到了 LocalCache）
        var aView = Path.Combine(_roaming, "Claude", "local-agent-mode-sessions", Acct, Org);
        string Esc(string p) => p.Replace("\\", "\\\\");
        var cwd = Path.Combine(aView, "local_s1", "outputs");
        Write(Path.Combine(a, "local_s1.json"), $$"""{ "cwd": "{{Esc(cwd)}}", "lastActivityAt": 100 }""");
        var proj = Path.Combine(a, "local_s1", ".claude", "projects", DesktopSessions.Sanitize(cwd));
        Write(Path.Combine(proj, "x.jsonl"), $$"""{"cwd":"{{Esc(cwd)}}","other":"{{cwd.Replace('\\', '/')}}"}""" + "\n");
        Write(Path.Combine(a, "local_s1", "audit.jsonl"), cwd);
        Write(Path.Combine(a, "local_s1", "outputs", "note.txt"), "hi");
        // 网关模式里已有的会话告诉我们目标在应用眼里的位置
        Directory.CreateDirectory(b);
        var bCwd = Path.Combine(b, "local_old", "outputs");
        Write(Path.Combine(b, "local_old.json"), $$"""{ "cwd": "{{Esc(bCwd)}}", "lastActivityAt": 1 }""");
        Write(Path.Combine(b, "local_old", "outputs", "k.txt"), "");
        var mtime = new DateTime(2026, 1, 2, 3, 4, 5, DateTimeKind.Utc);
        File.SetLastWriteTimeUtc(Path.Combine(a, "local_s1.json"), mtime);

        var bk = Path.Combine(_root, "bk");
        new DesktopSessions(Dp, _paths, _said.Add).SyncCowork(bk);

        var meta = Read(Path.Combine(b, "local_s1.json"));
        var newCwd = Path.Combine(b, "local_s1", "outputs");
        Assert.Equal(newCwd, (string)meta["cwd"]!);
        Assert.Equal(mtime, File.GetLastWriteTimeUtc(Path.Combine(b, "local_s1.json")));
        var newProj = Path.Combine(b, "local_s1", ".claude", "projects", DesktopSessions.Sanitize(newCwd));
        var line = Read(Path.Combine(newProj, "x.jsonl"));
        Assert.Equal(newCwd, (string)line["cwd"]!);
        Assert.Equal(newCwd.Replace('\\', '/'), (string)line["other"]!);
        Assert.Equal(cwd, File.ReadAllText(Path.Combine(b, "local_s1", "audit.jsonl")));   // 带签名，不动
        Assert.Equal("hi", File.ReadAllText(Path.Combine(b, "local_s1", "outputs", "note.txt")));
        Assert.True(File.Exists(Path.Combine(a, "local_old.json")));   // 反方向也补
        Assert.False(Directory.EnumerateFileSystemEntries(b, ".aa-switch-*").Any());
        Assert.Contains("Cowork 会话已同步（更新 2 条）。", _said);
        var ledger = File.ReadAllText(Path.Combine(_paths.ClaudeHome, "claude-mode-cowork-sync"));
        Assert.Contains("local_s1 100", ledger);
        Assert.Contains("local_old 1", ledger);

        // 账号那边接着聊了：覆盖网关那份，旧的挪进备份；再跑一次什么都不变
        Write(Path.Combine(a, "local_s1.json"), $$"""{ "cwd": "{{Esc(cwd)}}", "lastActivityAt": 200 }""");
        _said.Clear();
        new DesktopSessions(Dp, _paths, _said.Add).SyncCowork(bk);
        Assert.Equal(200, (long)Read(Path.Combine(b, "local_s1.json"))["lastActivityAt"]!);
        Assert.True(File.Exists(Path.Combine(bk, "cowork", "00000000", "local_s1.json")));
        Assert.Contains("Cowork 会话已同步（更新 1 条）。", _said);
        _said.Clear();
        new DesktopSessions(Dp, _paths, _said.Add).SyncCowork(bk);
        Assert.Contains("Cowork 会话已同步（更新 0 条）。", _said);
    }

    [Fact]
    public void Cowork_broken_meta_is_not_copied()
    {
        var a = Path.Combine(Account, "local-agent-mode-sessions", Acct, Org);
        var b = Path.Combine(Gateway3p, "local-agent-mode-sessions", "c0062ea9", "00000000");
        Write(Path.Combine(a, "local_bad.json"), "{ not json");
        Directory.CreateDirectory(Path.Combine(a, "local_bad"));
        Directory.CreateDirectory(b);
        new DesktopSessions(Dp, _paths, _said.Add).SyncCowork(Path.Combine(_root, "bk"));
        Assert.False(File.Exists(Path.Combine(b, "local_bad.json")));
        Assert.Empty(Directory.GetFileSystemEntries(b));
        Assert.Contains("有 1 条 Cowork 会话复制失败，下次切换时再试。", _said);
        Assert.DoesNotContain("local_bad", File.ReadAllText(Path.Combine(_paths.ClaudeHome, "claude-mode-cowork-sync")));
    }

    [Fact]
    public void Root_from_cwd_handles_both_separators()
    {
        Assert.Equal(@"C:\Users\u\AppData\Roaming\Claude\x", DesktopSessions.RootFromCwd("""{"cwd":"C:\\Users\\u\\AppData\\Roaming\\Claude\\x\\local_a\\outputs"}""", "local_a"));
        Assert.Equal("/x/y", DesktopSessions.RootFromCwd("""{"cwd":"/x/y/local_a"}""", "local_a"));
        Assert.Null(DesktopSessions.RootFromCwd("""{"cwd":"C:\\elsewhere"}""", "local_a"));
    }

    // ---------- 和命令行一起切 ----------
    [Fact]
    public async Task Product_switches_cli_and_desktop_together()
    {
        var secrets = new MemorySecretStore();
        var mode = new ClaudeMode(_paths, secrets, _said.Add, new OkHandler(), _ => null);
        mode.Configure("https://gw.example.com", "", "sk-3");
        var d = New();
        var p = new ClaudeProduct(mode, _paths, secrets, d, _said.Add);
        Assert.Equal("account", p.DesktopMode());

        await p.SwitchToApiAsync();
        Assert.Equal("api", mode.ModeWord());
        Assert.Equal("gateway", p.DesktopMode());
        Assert.Contains("已切到 API 模式：终端、IDE 插件和 Claude 桌面应用都走 https://gw.example.com。", _said);
        Assert.Contains("桌面应用：网关模式（https://gw.example.com）", p.Status());

        p.SwitchToAccount();
        Assert.Equal("account", mode.ModeWord());
        Assert.Equal("account", p.DesktopMode());
    }

    [Fact]
    public void Global_env_warning()
    {
        var mode = new ClaudeMode(_paths, new MemorySecretStore(), _said.Add, null, n => n == "ANTHROPIC_BASE_URL" ? "https://x" : null);
        Assert.Contains(mode.Status(), l => l.StartsWith("注意：Windows 环境变量里设了 ANTHROPIC_BASE_URL"));
    }

    sealed class OkHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) =>
            Task.FromResult(new HttpResponseMessage(System.Net.HttpStatusCode.OK));
    }
}
