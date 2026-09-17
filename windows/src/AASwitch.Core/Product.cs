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
}

public sealed class ClaudeProduct(ClaudeMode mode, AppPaths paths, ISecretStore secrets) : IProduct
{
    public string Name => "Claude Code";
    public string AccountWord => "account";
    public string AccountTitle => "Claude 账号";
    public string UrlPlaceholder => "https://api.example.com";
    public string UrlHint => "地址填网关根地址，不带 /v1（Claude Code 会自己加）。";
    public bool IsCodex => false;
    public string BackupsDir => paths.ClaudeBackups;
    public string DataDir => paths.ClaudeHome;
    public string ModeWord() => mode.ModeWord();
    public List<string> Status() => mode.Status();
    public (string, string) LoadConfig() { var c = mode.LoadConfig(); return (c.BaseUrl, c.Headers); }
    public string FindKey(string url) => secrets.Get(Gateway.SecretName(url)) ?? "";
    public string Configure(string url, string headerPairs, string? key) => mode.Configure(url, headerPairs, key);
    public Task SwitchToApiAsync() => mode.SwitchToApiAsync();
    public void SwitchToAccount() => mode.SwitchToAccount();
    public string ModelsEndpoint(string url) => url.TrimEnd('/') + "/v1/models";
}

public sealed class CodexProduct(CodexMode mode, AppPaths paths, ISecretStore secrets, bool cliFound) : IProduct
{
    public string Name => "Codex";
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
