using AASwitch.Core;

namespace AASwitch.Core.Tests;

public sealed class TrayViewTests
{
    sealed class Fake(bool codex) : IProduct
    {
        public string Name => codex ? "Codex" : "Claude Code";
        public string AccountWord => codex ? "chatgpt" : "account";
        public string AccountTitle => codex ? "ChatGPT 账号" : "Claude 账号";
        public string UrlPlaceholder => codex ? "https://api.example.com/v1" : "https://api.example.com";
        public string UrlHint => "";
        public bool IsCodex => codex;
        public string BackupsDir => ""; public string DataDir => "";
        public string ModeWord() => ""; public List<string> Status() => [];
        public (string, string) LoadConfig() => ("", ""); public string FindKey(string url) => "";
        public string Configure(string url, string headerPairs, string? key) => url;
        public Task SwitchToApiAsync() => Task.CompletedTask; public void SwitchToAccount() { }
        public string ModelsEndpoint(string url) => url;
    }
    static readonly IProduct Codex = new Fake(true), Claude = new Fake(false);

    [Fact]
    public void Api_mode_section()
    {
        var s = TrayView.Build(Claude, "api", ["模式：API（终端和 IDE 插件）", "请求发往：https://gw.example.com/", "账号：已登录（a@b.c）", "凭据管理器：已保存 key"], "AA Switch");
        Assert.Equal(1, s.Selected);
        Assert.Equal("API 请求发往 gw.example.com", s.UrlLine);
        Assert.False(s.UrlLineOpensConfigure);
        Assert.Empty(s.Warnings);
        Assert.Equal(["账号：已登录（a@b.c）", "凭据管理器：已保存 key"], s.Details);
        Assert.True(s.CanReapply);
    }

    [Fact]
    public void Unconfigured_account_mode_with_warnings()
    {
        var s = TrayView.Build(Claude, "account", ["模式：Claude 账号", "API 地址（切换后使用）：未配置", "账号：未登录", "注意：settings.json 里另有 ANTHROPIC_API_KEY，会盖过账号登录"], "AA Switch");
        Assert.Equal(0, s.Selected);
        Assert.True(s.UrlLineOpensConfigure);
        Assert.Equal(["⚠ 账号：未登录", "⚠ 注意：settings.json 里另有 ANTHROPIC_API_KEY，会盖过账号登录"], s.Warnings);
        Assert.False(s.CanReapply);
    }

    [Fact]
    public void Codex_never_switched_and_mixed_state()
    {
        var s = TrayView.Build(Codex, "none", ["模式：尚未切换过", "API 地址：https://api.example.com/v1", "登录：ChatGPT 账号"], "AA Switch");
        Assert.Null(s.Selected);
        Assert.Contains(s.Notes, n => n.Contains("还没用 AA Switch 切换过"));

        s = TrayView.Build(Codex, "api", ["模式：API", "请求发往：https://api.example.com/v1", "登录：ChatGPT 账号"], "AA Switch");
        Assert.Contains(s.Warnings, w => w.Contains("再点一次当前模式即可修正"));
        Assert.True(TrayView.NeedsSwitch(Codex, "api", TrayView.Parse(["登录：ChatGPT 账号"]), wantApi: true));    // 混合状态：重新切一次对齐
        Assert.False(TrayView.NeedsSwitch(Codex, "api", TrayView.Parse(["登录：API key"]), wantApi: true));
        Assert.False(TrayView.NeedsSwitch(Codex, "none", TrayView.Parse(["登录：ChatGPT 账号"]), wantApi: false));   // 没切换过 + 选账号：不动
        Assert.True(TrayView.NeedsSwitch(Claude, "api", [], wantApi: false));
        Assert.False(TrayView.NeedsSwitch(Claude, "account", [], wantApi: false));
    }

    [Fact]
    public void Loading_and_absent()
    {
        Assert.Equal("读取中…", TrayView.Build(Claude, "account", null, "AA Switch").UrlLine);
        Assert.NotNull(TrayView.Build(Codex, "absent", null, "AA Switch").Unavailable);
        Assert.Equal("Codex：API 模式\nClaude Code：Claude 账号", TrayView.Tooltip([(Codex, "api"), (Claude, "account")]));
    }

    [Theory]
    [InlineData(true, " https://api.example.com/ ", "https://api.example.com/v1", false)]
    [InlineData(true, "https://api.example.com/openai/v1", "https://api.example.com/openai/v1", false)]
    [InlineData(false, "https://api.example.com/v1/", "https://api.example.com", false)]
    [InlineData(false, "http://127.0.0.1:8080", "http://127.0.0.1:8080", false)]
    [InlineData(false, "api.example.com", "api.example.com", true)]
    [InlineData(false, "https://a b.com", "https://a b.com", true)]
    [InlineData(false, "https://nodomain", "https://nodomain", true)]
    [InlineData(false, "", "", true)]
    public void NormalizeUrl(bool codex, string raw, string url, bool error)
    {
        var (u, e) = TrayView.NormalizeUrl(raw, codex ? Codex : Claude);
        Assert.Equal(url, u);
        Assert.Equal(error, e is not null);
    }

    [Theory]
    [InlineData(200, true, false)]
    [InlineData(401, false, true)]
    [InlineData(403, false, true)]
    [InlineData(404, false, false)]
    [InlineData(500, false, false)]
    [InlineData(0, false, false)]
    public void ClassifyProbe(int status, bool ok, bool blocking)
    {
        var r = TrayView.ClassifyProbe(status, "https://x/v1/models", "https://x");
        Assert.Equal((ok, blocking), (r.Ok, r.Blocking));
        Assert.Equal(ok, r.Message is null);
    }

    [Fact]
    public void ClassifyProbe_appends_the_gateway_reason()
    {
        var r = TrayView.ClassifyProbe(401, "https://x/v1/models", "https://x", "额度已用完");
        Assert.True(r.Blocking);
        Assert.Contains("网关返回：额度已用完。", r.Message);
        Assert.DoesNotContain("网关返回", TrayView.ClassifyProbe(401, "https://x/v1/models", "https://x").Message);
    }
}
