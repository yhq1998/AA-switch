namespace AASwitch.Core;

/// <summary>托盘程序眼里的一个产品（Codex / Claude Code）：把两边大同小异的操作收成同一个接口，界面代码不用分情况。</summary>
public interface IProduct
{
    string Name { get; }            // 菜单里的分组标题
    string AccountWord { get; }     // ModeWord() 里账号模式的词：chatgpt / account
    string AccountTitle { get; }    // 菜单里账号模式的叫法
    string UrlPlaceholder { get; }
    string UrlHint { get; }
    bool IsCodex { get; }
    string BackupsDir { get; }
    string DataDir { get; }

    /// <summary>api / 账号词 / none（Codex 还没切换过）/ absent（这台电脑上没装）。</summary>
    string ModeWord();
    List<string> Status();
    (string Url, string HeaderPairs) LoadConfig();
    /// <summary>不问用户地找该地址的 key，找不到返回 ""。</summary>
    string FindKey(string url);
    string Configure(string url, string headerPairs, string? key);
    Task SwitchToApiAsync();
    void SwitchToAccount();
    /// <summary>探测 key 用的 models 接口地址。</summary>
    string ModelsEndpoint(string url);
    /// <summary>Claude 桌面应用的模式：gateway / account / absent（没装，或者不是 Claude）。</summary>
    string DesktopMode() => "absent";
}

/// <summary>Claude Code 加上 Claude 桌面应用（desktop 为 null 表示不管桌面应用）：点 API 两边都切到网关，点账号两边都切回账号，和 macOS 版一样。</summary>
public sealed class ClaudeProduct(ClaudeMode mode, AppPaths paths, ISecretStore secrets, ClaudeDesktop? desktop = null, Action<string>? say = null) : IProduct
{
    public string Name => "Claude Code";
    public string AccountWord => "account";
    public string AccountTitle => "Claude 账号";
    public string UrlPlaceholder => "https://api.example.com";
    public string UrlHint => "地址填网关根地址，不带 /v1（Claude Code 会自己加）。";
    public bool IsCodex => false;
    public string BackupsDir => paths.ClaudeBackups;
    public string DataDir => paths.ClaudeHome;
    public ClaudeDesktop? Desktop => desktop is { Installed: true } ? desktop : null;
    public string DesktopMode() => Desktop?.ModeWord() ?? "absent";
    // 只装了桌面应用、没装命令行也照样管：模式看 settings.json
    public string ModeWord()
    {
        var m = mode.ModeWord();
        return m == "absent" && Desktop is not null ? (mode.ReadEnv().BaseUrl.Length > 0 ? "api" : "account") : m;
    }
    public List<string> Status()
    {
        var lines = mode.Status();
        if (Desktop is { } d) lines.AddRange(d.Status());
        return lines;
    }
    public (string, string) LoadConfig() { var c = mode.LoadConfig(); return (c.BaseUrl, c.Headers); }
    public string FindKey(string url) => secrets.Get(Gateway.SecretName(url)) ?? "";
    public string Configure(string url, string headerPairs, string? key) => mode.Configure(url, headerPairs, key);
    /// <summary>命令行总是重写一遍；桌面应用不在网关模式就切过去，已经在网关模式、命令行也已经是 API（即“重新应用”）时也重写并重启，
    /// 命令行在账号、桌面应用已在网关（不一致）时只切命令行，免得白白重启应用。</summary>
    public async Task SwitchToApiAsync()
    {
        var wasApi = mode.ReadEnv().BaseUrl.Length > 0;
        await mode.SwitchToApiAsync();
        if (Desktop is not { } d) return;
        if (d.ModeWord() == "gateway" && !wasApi) return;
        var url = mode.LoadConfig().BaseUrl;
        d.SwitchToGateway(url, FindKey(url));
        var gw = d.GatewayUrl(url);
        say?.Invoke(gw == url.TrimEnd('/') ? $"已切到 API 模式：终端、IDE 插件和 {ClaudeDesktop.AppName}都走 {url}。"
                                           : $"已切到 API 模式：终端和 IDE 插件走 {url}，{ClaudeDesktop.AppName}走 {gw}。");
    }
    public void SwitchToAccount()
    {
        mode.SwitchToAccount();
        if (Desktop is not { } d || d.ModeWord() != "gateway") return;
        d.SwitchToAccount();
        say?.Invoke($"已切回 Claude 账号模式：终端、IDE 插件和 {ClaudeDesktop.AppName}都用账号登录。");
    }
    public string ModelsEndpoint(string url) => url.TrimEnd('/') + "/v1/models";
}

public sealed class CodexProduct(CodexMode mode, AppPaths paths, ISecretStore secrets, bool cliFound) : IProduct
{
    public string Name => "Codex";
    /// <summary>建这个对象时找没找到 codex 命令行：没找到的话托盘每次刷新会再找一遍。</summary>
    public bool CliFound => cliFound;
    public string AccountWord => "chatgpt";
    public string AccountTitle => "ChatGPT 账号";
    public string UrlPlaceholder => "https://api.example.com/v1";
    public string UrlHint => "地址填服务商给的完整地址，通常以 /v1 结尾。";
    public bool IsCodex => true;
    public string BackupsDir => paths.CodexBackups;
    public string DataDir => paths.CodexHome;
    public string ModeWord() => cliFound || File.Exists(paths.CodexConfig) ? mode.ModeWord() : "absent";
    public List<string> Status() => mode.Status();
    public (string, string) LoadConfig() { var c = mode.LoadConfig(); return (c.BaseUrl, c.HeaderPairs); }
    // 只有目标地址就是配置里的网关时才把“Codex 当前在用的 key”认作它的 key；别的地址只查凭据管理器
    public string FindKey(string url)
    {
        var configured = mode.LoadConfig().BaseUrl;
        return configured.Length > 0 && Gateway.UrlHost(configured) == Gateway.UrlHost(url) ? mode.DiscoverKey(url) : secrets.Get(Gateway.SecretName(url)) ?? "";
    }
    public string Configure(string url, string headerPairs, string? key) => mode.Configure(url, headerPairs, key);
    public Task SwitchToApiAsync() => mode.SwitchToApiAsync();
    public void SwitchToAccount() => mode.SwitchToChatGpt();
    public string ModelsEndpoint(string url) => url.TrimEnd('/') + "/models";
}
