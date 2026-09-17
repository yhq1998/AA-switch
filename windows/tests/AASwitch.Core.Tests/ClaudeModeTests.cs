using System.Net;
using System.Text.Json.Nodes;
using AASwitch.Core;

namespace AASwitch.Core.Tests;

public sealed class ClaudeModeTests : IDisposable
{
    readonly string _home = Directory.CreateTempSubdirectory("aaswitch-test-").FullName;
    readonly AppPaths _paths;
    readonly MemorySecretStore _secrets = new();
    readonly List<string> _said = [];
    readonly StubHandler _http = new();

    public ClaudeModeTests() => _paths = new AppPaths(_home);
    public void Dispose() => Directory.Delete(_home, recursive: true);

    ClaudeMode New() => new(_paths, _secrets, _said.Add, _http);
    void WriteSettings(string json) { Directory.CreateDirectory(_paths.ClaudeHome); File.WriteAllText(_paths.ClaudeSettings, json); }
    JsonObject Settings() => (JsonObject)JsonNode.Parse(File.ReadAllText(_paths.ClaudeSettings))!;

    sealed class StubHandler : HttpMessageHandler
    {
        public HttpStatusCode Status = HttpStatusCode.OK;
        public bool Unreachable;
        public HttpRequestMessage? Last;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Last = request;
            if (Unreachable) throw new HttpRequestException("no route");
            return Task.FromResult(new HttpResponseMessage(Status));
        }
    }

    [Fact]
    public async Task Api_then_account_roundtrip_keeps_other_settings()
    {
        WriteSettings("""{ "theme": "dark", "env": { "FOO": "1" }, "hooks": { "Stop": [] }, "说明": "中文" }""");
        var c = New();
        c.Configure("https://gw.example.com/v1/", "x-a = b, x-c=d", "sk-test");

        await c.SwitchToApiAsync();
        var env = (JsonObject)Settings()["env"]!;
        Assert.Equal("https://gw.example.com", (string)env["ANTHROPIC_BASE_URL"]!);
        Assert.Equal("sk-test", (string)env["ANTHROPIC_AUTH_TOKEN"]!);
        Assert.Equal("x-a: b\nx-c: d", (string)env["ANTHROPIC_CUSTOM_HEADERS"]!);
        Assert.Equal("1", (string)env["FOO"]!);
        Assert.Equal("https://gw.example.com/v1/models", _http.Last!.RequestUri!.ToString());
        Assert.Equal("Bearer sk-test", _http.Last.Headers.Authorization!.ToString());
        Assert.Equal("b", _http.Last.Headers.GetValues("x-a").Single());

        c.SwitchToAccount();
        var after = Settings();
        Assert.Equal(["theme", "env", "hooks", "说明"], after.Select(p => p.Key).ToArray());
        Assert.Equal(["FOO"], ((JsonObject)after["env"]!).Select(p => p.Key).ToArray());
        Assert.Contains("中文", File.ReadAllText(_paths.ClaudeSettings));   // 不转义成 \uXXXX
        Assert.DoesNotContain("\r", File.ReadAllText(_paths.ClaudeSettings));
        Assert.NotEmpty(Directory.GetDirectories(_paths.ClaudeBackups));
    }

    [Fact]
    public async Task Account_removes_empty_env_block_and_no_settings_file_stays_absent()
    {
        var c = New();
        c.SwitchToAccount();
        Assert.False(File.Exists(_paths.ClaudeSettings));

        c.Configure("https://gw.example.com", "", "k");
        await c.SwitchToApiAsync();
        Assert.Null(((JsonObject)Settings()["env"]!)["ANTHROPIC_CUSTOM_HEADERS"]);
        c.SwitchToAccount();
        Assert.Null(Settings()["env"]);
    }

    [Theory]
    [InlineData(HttpStatusCode.Unauthorized)]
    [InlineData(HttpStatusCode.Forbidden)]
    public async Task Rejected_key_stops_the_switch(HttpStatusCode status)
    {
        WriteSettings("{}");
        var c = New();
        c.Configure("https://gw.example.com", "", "bad");
        _http.Status = status;
        var e = await Assert.ThrowsAsync<SwitchException>(c.SwitchToApiAsync);
        Assert.Contains($"HTTP {(int)status}", e.Message);
        Assert.Equal("{}", File.ReadAllText(_paths.ClaudeSettings));
    }

    [Fact]
    public async Task Unreachable_gateway_or_404_does_not_block()
    {
        var c = New();
        c.Configure("https://gw.example.com", "", "k");
        _http.Unreachable = true;
        await c.SwitchToApiAsync();
        _http.Unreachable = false; _http.Status = HttpStatusCode.NotFound;
        await c.SwitchToApiAsync();
        Assert.Equal("https://gw.example.com", c.ReadEnv().BaseUrl);
    }

    [Fact]
    public async Task Missing_address_or_key_is_reported()
    {
        var c = New();
        await Assert.ThrowsAsync<SwitchException>(c.SwitchToApiAsync);
        c.Configure("https://gw.example.com", "", null);
        var e = await Assert.ThrowsAsync<SwitchException>(c.SwitchToApiAsync);
        Assert.Contains("gw.example.com", e.Message);
    }

    [Fact]
    public void First_run_inherits_codex_gateway_without_v1()
    {
        Directory.CreateDirectory(_paths.CodexHome);
        File.WriteAllText(_paths.CodexConf, "provider=x\nbase_url=https://api.example.com/v1\n");
        var c = New();
        Assert.Equal("https://api.example.com", c.LoadConfig().BaseUrl);
        Assert.Equal("https://api.example.com", new ConfFile(_paths.ClaudeConf).Get("base_url"));
    }

    [Fact]
    public void Broken_settings_json_is_not_overwritten()
    {
        WriteSettings("{ not json");
        var c = New();
        Assert.Throws<SwitchException>(c.SwitchToAccount);
        Assert.Equal("{ not json", File.ReadAllText(_paths.ClaudeSettings));
    }

    [Fact]
    public void Configure_validates_input()
    {
        var c = New();
        Assert.Throws<SwitchException>(() => c.Configure("gw.example.com", "", null));
        Assert.Throws<SwitchException>(() => c.Configure("https://gw.example.com", "no-equals-sign", null));
        Assert.Equal("", c.LoadConfig().BaseUrl);
    }

    [Fact]
    public void Status_and_foreign_api_key_warning()
    {
        WriteSettings("""{ "env": { "ANTHROPIC_API_KEY": "sk-ant" } }""");
        File.WriteAllText(_paths.ClaudeGlobalState, """{ "oauthAccount": { "emailAddress": "a@b.c" } }""");
        File.WriteAllText(_paths.ClaudeCredentialsFile, "{}");
        var lines = New().Status();
        Assert.Contains("模式：Claude 账号", lines);
        Assert.Contains("账号：已登录（a@b.c）", lines);
        Assert.Contains(lines, l => l.Contains("ANTHROPIC_API_KEY"));
    }

    [Fact]
    public async Task Backups_are_pruned_to_twenty()
    {
        WriteSettings("{}");
        Directory.CreateDirectory(_paths.ClaudeBackups);
        for (var i = 0; i < 25; i++) Directory.CreateDirectory(Path.Combine(_paths.ClaudeBackups, $"202001{i + 1:00}-000000"));
        Directory.CreateDirectory(Path.Combine(_paths.ClaudeBackups, "keep-me"));
        var c = New();
        c.Configure("https://gw.example.com", "", "k");
        await c.SwitchToApiAsync();
        var dirs = Directory.GetDirectories(_paths.ClaudeBackups).Select(Path.GetFileName).ToList();
        Assert.Equal(21, dirs.Count);
        Assert.Contains("keep-me", dirs);
        Assert.DoesNotContain("20200101-000000", dirs);
    }
}

public sealed class GatewayTests
{
    [Theory]
    [InlineData("https://api.example.com/v1", "api.example.com")]
    [InlineData("http://user@host.local:8080/x", "host.local")]
    public void UrlHost(string url, string host) => Assert.Equal(host, Gateway.UrlHost(url));

    [Theory]
    [InlineData("https://a.b", true)]
    [InlineData("https://", false)]
    [InlineData("ftp://a.b", false)]
    [InlineData("https://a b", false)]
    [InlineData("https://a\"b", false)]
    public void ValidUrl(string url, bool ok) => Assert.Equal(ok, Gateway.ValidUrl(url));

    [Fact]
    public void SecretName_matches_macos_keychain_entry() => Assert.Equal("codex-mode:api.example.com", Gateway.SecretName("https://api.example.com/v1"));
}
