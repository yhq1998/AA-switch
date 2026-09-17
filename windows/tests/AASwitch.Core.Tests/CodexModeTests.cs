using System.Net;
using AASwitch.Core;
using Microsoft.Data.Sqlite;

namespace AASwitch.Core.Tests;

public sealed class CodexModeTests : IDisposable
{
    readonly string _home = Directory.CreateTempSubdirectory("aaswitch-codex-").FullName;
    readonly AppPaths _paths;
    readonly MemorySecretStore _secrets = new();
    readonly List<string> _said = [];
    readonly FakeCodex _cli;
    readonly StubHandler _http = new();
    List<string> _running = [];

    public CodexModeTests()
    {
        _paths = new AppPaths(_home);
        Directory.CreateDirectory(_paths.CodexHome);
        _cli = new FakeCodex(_paths);
    }
    public void Dispose() => Directory.Delete(_home, recursive: true);

    CodexMode New() => new(_paths, _secrets, _cli, _said.Add, () => _running, _http);
    string Config() => File.ReadAllText(_paths.CodexConfig);

    sealed class StubHandler : HttpMessageHandler
    {
        public HttpStatusCode Status = HttpStatusCode.OK;
        public HttpRequestMessage? Last;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) { Last = request; return Task.FromResult(new HttpResponseMessage(Status)); }
    }

    /// <summary>模仿真的 codex：登录态就是 auth.json；配置里有 BROKEN 字样就报配置错误。</summary>
    sealed class FakeCodex(AppPaths paths) : ICodexCli
    {
        public bool FailLogin;
        public string LoginStatus()
        {
            if (File.Exists(paths.CodexConfig) && File.ReadAllText(paths.CodexConfig).Contains("BROKEN")) return "Error loading config.toml: invalid";
            if (!File.Exists(paths.CodexAuth)) return "Not logged in";
            var a = File.ReadAllText(paths.CodexAuth);
            return a.Contains("refresh_token") ? "Logged in using ChatGPT" : "Logged in using an API key - ***";
        }
        public bool LoginWithApiKey(string key)
        {
            if (FailLogin) return false;
            File.WriteAllText(paths.CodexAuth, $$"""{ "auth_mode": "apikey", "OPENAI_API_KEY": "{{key}}" }""");
            return true;
        }
        public void Logout() => File.Delete(paths.CodexAuth);
    }

    const string ChatGptAuth = """{ "auth_mode": "chatgpt", "OPENAI_API_KEY": null, "tokens": { "refresh_token": "rt" } }""";

    string NewDb(string name, params string[] providers)
    {
        var db = Path.Combine(_paths.CodexHome, name);
        using var c = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = db, Pooling = false }.ToString());
        c.Open();
        using var cmd = c.CreateCommand();
        cmd.CommandText = "pragma journal_mode=wal; create table threads(id integer primary key, model_provider text);";
        cmd.ExecuteNonQuery();
        foreach (var p in providers) { cmd.CommandText = "insert into threads(model_provider) values ($p)"; cmd.Parameters.Clear(); cmd.Parameters.AddWithValue("$p", p); cmd.ExecuteNonQuery(); }
        return db;
    }

    static List<string> DbProviders(string db)
    {
        using var c = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = db, Pooling = false, Mode = SqliteOpenMode.ReadOnly }.ToString());
        c.Open();
        using var cmd = c.CreateCommand(); cmd.CommandText = "select model_provider from threads order by id";
        using var r = cmd.ExecuteReader();
        var list = new List<string>(); while (r.Read()) list.Add(r.GetString(0)); return list;
    }

    string NewSession(string rel, string firstLine, string rest = "{\"type\":\"event\",\"model_provider\":\"openai\"}\n")
    {
        var f = Path.Combine(_paths.CodexHome, rel);
        Directory.CreateDirectory(Path.GetDirectoryName(f)!);
        File.WriteAllText(f, firstLine + "\n" + rest);
        return f;
    }

    [Fact]
    public async Task Fresh_install_api_then_chatgpt_roundtrip()
    {
        File.WriteAllText(_paths.CodexAuth, ChatGptAuth);
        File.WriteAllText(_paths.CodexConfig, "model = \"gpt-5\"\n\n[features]\nfoo = true\n");
        var c = New();
        Assert.Equal("none", c.ModeWord());
        c.Configure("https://api.example.com", "x-actor = gw", "sk-1");

        await c.SwitchToApiAsync();
        Assert.Equal("https://api.example.com/v1/models", _http.Last!.RequestUri!.ToString());
        Assert.Equal("gw", _http.Last.Headers.GetValues("x-actor").Single());
        Assert.Equal("api", c.ModeWord());
        var cfg = Config();
        Assert.StartsWith("model_provider = \"api_example_com\"", cfg);
        Assert.Contains("model = \"gpt-5\"\n\n[features]\nfoo = true\n\n[model_providers.api_example_com]\nname = \"api_example_com\"\nbase_url = \"https://api.example.com/v1\"\nwire_api = \"responses\"\nrequires_openai_auth = true\nsupports_websockets = false\nhttp_headers = { \"x-actor\" = \"gw\" }\n", cfg);
        Assert.Contains("sk-1", File.ReadAllText(_paths.CodexAuth));
        Assert.Equal(ChatGptAuth, File.ReadAllText(_paths.CodexAuthStash));   // 切走前存了一份账号登录态

        c.SwitchToChatGpt();
        Assert.Equal("chatgpt", c.ModeWord());
        Assert.Contains("# base_url = \"https://api.example.com/v1\"", Config());
        Assert.Contains("# http_headers = { \"x-actor\" = \"gw\" }", Config());
        Assert.Equal(ChatGptAuth, File.ReadAllText(_paths.CodexAuth));   // 不用重新登录
        Assert.Contains(_said, s => s.Contains("恢复了之前的 ChatGPT 登录态"));
        Assert.Equal(1, Config().Split('\n').Count(l => l.StartsWith("[model_providers.")));

        await c.SwitchToApiAsync();   // 再切一次：块不重复，名字不变
        Assert.Equal(1, Config().Split('\n').Count(l => l.StartsWith("[model_providers.")));
        Assert.StartsWith("model_provider = \"api_example_com\"", Config());
    }

    [Fact]
    public async Task History_providers_become_aliases_and_foreign_provider_with_own_key_is_kept()
    {
        File.WriteAllText(_paths.CodexConfig, """
            model_provider = "oldgw"   # 旧版脚本写的

            [model_providers.oldgw]
            name = "oldgw"
            base_url = "https://old.example.com/v1"
            http_headers = { "x-a" = "1" }

            [model_providers.deepseek]
            name = "DeepSeek"
            base_url = "https://api.deepseek.com/v1"
            env_key = "DEEPSEEK_API_KEY"

            [mcp_servers.x]
            command = "npx"
            """.Replace("            ", ""));
        var db = NewDb("state_5.sqlite", "openai", "ancient", "deepseek", "openai");
        var s1 = NewSession("sessions/2026/01/02/a.jsonl", """{"timestamp":"t","type":"session_meta","payload":{"id":"1","model_provider":"openai"}}""");
        var s2 = NewSession("archived_sessions/b.jsonl", """{"timestamp":"t","type":"session_meta","payload":{"id":"2","model_provider":"weird one"}}""");
        var s1Time = new DateTime(2026, 1, 2, 3, 4, 5, DateTimeKind.Utc);
        File.SetLastWriteTimeUtc(s1, s1Time);
        _secrets.Set("codex-mode:old.example.com", "sk-old");

        var c = New();
        var loaded = c.LoadConfig();   // 首次运行：从现有配置推断
        Assert.Equal(("https://old.example.com/v1", "{ \"x-a\" = \"1\" }", "oldgw"), (loaded.BaseUrl, loaded.HeadersToml, loaded.Provider));
        Assert.Equal(3, c.Status().Count(l => l.Contains("待统一的会话：2 条") || l.StartsWith("模式：API") || l.StartsWith("请求发往")));

        await c.SwitchToApiAsync();
        var cfg = Config();
        Assert.StartsWith("model_provider = \"oldgw\"", cfg);
        Assert.Equal(1, cfg.Split('\n').Count(l => l.StartsWith("model_provider")));
        Assert.Contains("[model_providers.deepseek]\nname = \"DeepSeek\"\nbase_url = \"https://api.deepseek.com/v1\"\nenv_key = \"DEEPSEEK_API_KEY\"", cfg);
        Assert.Contains("[mcp_servers.x]\ncommand = \"npx\"", cfg);
        Assert.Contains("[model_providers.ancient]\nname = \"ancient\"\nbase_url = \"https://old.example.com/v1\"", cfg);
        Assert.Contains("[model_providers.\"weird one\"]\nname = \"weird one\"", cfg);
        Assert.DoesNotContain("\n\n\n", cfg);

        Assert.Equal(["oldgw", "ancient", "deepseek", "oldgw"], DbProviders(db));
        var lines = File.ReadAllText(s1).Split('\n');
        Assert.Contains("\"model_provider\":\"oldgw\"", lines[0]);
        Assert.Contains("\"model_provider\":\"openai\"", lines[1]);   // 只改第一行
        Assert.Equal(s1Time, File.GetLastWriteTimeUtc(s1));          // 不把旧会话顶到最前
        Assert.Contains("weird one", File.ReadAllText(s2));
        Assert.Contains(_said, s => s.Contains("已把 3 处"));

        var backup = Directory.GetDirectories(_paths.CodexBackups).Single();
        Assert.Contains("\"model_provider\":\"openai\"", File.ReadAllText(Path.Combine(backup, "sessions", "2026", "01", "02", "a.jsonl")).Split('\n')[0]);
        Assert.Equal(["openai", "ancient", "deepseek", "openai"], DbProviders(Path.Combine(backup, "state_5.sqlite")));
        Assert.False(File.Exists(Path.Combine(backup, "state_5.sqlite-wal")));
    }

    [Fact]
    public async Task Failed_login_or_broken_config_restores_everything()
    {
        const string original = "model = \"x\"\n";
        File.WriteAllText(_paths.CodexConfig, original);
        File.WriteAllText(_paths.CodexAuth, ChatGptAuth);
        var db = NewDb("state_5.sqlite", "openai");
        var s = NewSession("sessions/a.jsonl", """{"type":"session_meta","payload":{"model_provider":"openai"}}""");
        var c = New();
        c.Configure("https://api.example.com/v1", "", "sk-1");

        _cli.FailLogin = true;
        var e = await Assert.ThrowsAsync<SwitchException>(c.SwitchToApiAsync);
        Assert.Contains("已恢复", e.Message);
        Assert.Equal(original, Config());
        Assert.Equal(ChatGptAuth, File.ReadAllText(_paths.CodexAuth));
        Assert.Equal(["openai"], DbProviders(db));
        Assert.Contains("\"model_provider\":\"openai\"", File.ReadAllText(s));

        _cli.FailLogin = false;
        c.Configure("https://api.example.com/v1", "x-note=BROKEN", null);
        e = await Assert.ThrowsAsync<SwitchException>(c.SwitchToApiAsync);
        Assert.Contains("没有通过 Codex 校验", e.Message);
        Assert.Equal(original, Config());
        Assert.Equal(["openai"], DbProviders(db));
    }

    [Fact]
    public async Task Refuses_while_codex_is_running_or_key_rejected_and_touches_nothing()
    {
        File.WriteAllText(_paths.CodexConfig, "model = \"x\"\n");
        var c = New();
        c.Configure("https://api.example.com/v1", "", "sk-1");
        _running = ["codex ×1"];
        var e = await Assert.ThrowsAsync<SwitchException>(c.SwitchToApiAsync);
        Assert.Contains("codex ×1", e.Message);
        Assert.Throws<SwitchException>(c.SwitchToChatGpt);

        _running = []; _http.Status = HttpStatusCode.Unauthorized;
        e = await Assert.ThrowsAsync<SwitchException>(c.SwitchToApiAsync);
        Assert.Contains("HTTP 401", e.Message);
        Assert.Equal("model = \"x\"\n", Config());
        Assert.False(Directory.Exists(_paths.CodexBackups));
    }

    [Fact]
    public async Task Key_in_use_by_codex_is_adopted()
    {
        File.WriteAllText(_paths.CodexAuth, """{ "auth_mode": "apikey", "OPENAI_API_KEY": "sk-inuse" }""");
        var c = New();
        c.Configure("https://api.example.com/v1", "", null);
        await c.SwitchToApiAsync();
        Assert.Equal("sk-inuse", _secrets.Get("codex-mode:api.example.com"));
    }

    [Fact]
    public void Chatgpt_without_stash_logs_out()
    {
        File.WriteAllText(_paths.CodexAuth, """{ "auth_mode": "apikey", "OPENAI_API_KEY": "sk" }""");
        var c = New();
        c.Configure("https://api.example.com/v1", "", null);
        c.SwitchToChatGpt();
        Assert.False(File.Exists(_paths.CodexAuth));
        Assert.Contains(_said, s => s.Contains("请在 Codex 里用 ChatGPT 账号登录"));
    }

    [Fact]
    public void Header_validation()
    {
        Assert.Equal("{ \"a\" = \"b\", \"c\" = \"d e\" }", CodexToml.PairsToToml(" a = b ,c=d e"));
        Assert.Equal("a=b, c=d e", CodexToml.TomlToPairs("{ \"a\" = \"b\", \"c\" = \"d e\" }"));
        Assert.Equal("", CodexToml.PairsToToml(""));
        Assert.Throws<SwitchException>(() => CodexToml.PairsToToml("Authorization=x"));
        Assert.Throws<SwitchException>(() => CodexToml.PairsToToml("a=\"b\""));
        Assert.Throws<SwitchException>(() => CodexToml.PairsToToml("novalue"));
    }
}
