using AASwitch.Core;

namespace AASwitch.Tray;

/// <summary>--render --demo 用的假产品：一套固定的、好看的状态，用来给 README 出截图。不读也不写任何真实配置。</summary>
sealed class DemoProduct(bool codex, string mode) : IProduct
{
    public string Name => codex ? "Codex" : "Claude Code";
    public string AccountWord => codex ? "chatgpt" : "account";
    public string AccountTitle => codex ? "ChatGPT 账号" : "Claude 账号";
    public string UrlPlaceholder => codex ? "https://api.example.com/v1" : "https://api.example.com";
    public string UrlHint => codex ? "地址填服务商给的完整地址，通常以 /v1 结尾。" : "地址填网关根地址，不带 /v1（Claude Code 会自己加）。";
    public bool IsCodex => codex;
    public string BackupsDir => ""; public string DataDir => "";
    string Url => codex ? "https://api.example.com/v1" : "https://api.example.com";
    public string ModeWord() => mode;
    public List<string> Status() => codex
        ? [mode == "api" ? "模式：API" : "模式：ChatGPT 账号", (mode == "api" ? "请求发往：" : "API 地址（切换后使用）：") + Url, mode == "api" ? "登录：API key" : "登录：ChatGPT 账号", "凭据管理器：已保存 key"]
        : [mode == "api" ? "模式：API（终端和 IDE 插件）" : "模式：Claude 账号", (mode == "api" ? "请求发往：" : "API 地址（切换后使用）：") + Url, "账号：已登录（you@example.com）", "凭据管理器：已保存 key"];
    public (string, string) LoadConfig() => (Url, "");
    public string FindKey(string url) => "sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
    public string Configure(string url, string headerPairs, string? key) => url;
    public Task SwitchToApiAsync() => Task.CompletedTask;
    public void SwitchToAccount() { }
    public string ModelsEndpoint(string url) => url;
}
