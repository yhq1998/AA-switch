using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace AASwitch.Core;

/// <summary>
/// Claude Code（终端和 IDE 插件）在「Claude 账号」和「自定义 API」之间切换，对应 macOS 版的 claude-mode 脚本。
/// 原理相同：settings.json 的 env 块里有 ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN 时新会话走网关，删掉就回到账号登录；
/// settings.json 的其他内容原样保留，写之前先备份。桌面应用的第三方推理模式另见 ClaudeDesktop（待 Windows 路径确认后实现）。
/// </summary>
public sealed partial class ClaudeMode(AppPaths paths, ISecretStore secrets, Action<string> say, HttpMessageHandler? http = null)
{
    public const string Version = "0.1.0";
    const int KeepBackups = 20;
    static readonly string[] EnvKeys = ["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_CUSTOM_HEADERS"];

    readonly ConfFile _conf = new(paths.ClaudeConf);

    public sealed record EnvState(string BaseUrl, bool HasToken, bool HasForeignApiKey);
    public sealed record Config(string BaseUrl, string Headers);

    // ---------- 读状态 ----------
    public EnvState ReadEnv()
    {
        var env = JsonFile.ReadObject(paths.ClaudeSettings)["env"] as JsonObject;
        return new EnvState(
            JsonFile.String(env?["ANTHROPIC_BASE_URL"]) ?? "",
            !string.IsNullOrEmpty(JsonFile.String(env?["ANTHROPIC_AUTH_TOKEN"])),
            !string.IsNullOrEmpty(JsonFile.String(env?["ANTHROPIC_API_KEY"])));
    }

    /// <summary>api / account / absent，给托盘菜单用。</summary>
    public string ModeWord() => !Installed() ? "absent" : ReadEnv().BaseUrl.Length > 0 ? "api" : "account";

    public bool Installed() =>
        File.Exists(paths.ClaudeGlobalState) || Directory.Exists(Path.Combine(paths.ClaudeHome, "projects")) || OnPath("claude");

    public bool AccountLoggedIn() => File.Exists(paths.ClaudeCredentialsFile);

    public string AccountEmail()
    {
        try { return JsonFile.String(JsonFile.ReadObject(paths.ClaudeGlobalState)["oauthAccount"]?["emailAddress"]) ?? ""; }
        catch (SwitchException) { return ""; }
    }

    /// <summary>已保存的地址和请求头；首次运行沿用 codex-mode 配的网关（去掉 OpenAI 风格的 /v1）。</summary>
    public Config LoadConfig()
    {
        var url = _conf.Get("base_url");
        if (url.Length == 0)
        {
            var other = new ConfFile(paths.CodexConf).Get("base_url");
            if (other.Length > 0)
            {
                url = StripV1(other);
                _conf.Set("base_url", url);
                say($"已沿用 codex-mode 的网关地址 {url}，保存到 {paths.ClaudeConf}。");
            }
        }
        return new Config(url, _conf.Get("headers"));
    }

    public bool HasKey(string url) => !string.IsNullOrEmpty(secrets.Get(Gateway.SecretName(url)));

    // ---------- 配置 ----------
    /// <summary>规范化并保存地址和请求头；key 非空时存入凭据管理器。返回规范化后的地址。</summary>
    public string Configure(string url, string headers, string? key)
    {
        url = url.Trim().TrimEnd('/');
        if (!Gateway.ValidUrl(url)) throw new SwitchException($"地址格式不对：{url}（需要以 http:// 或 https:// 开头的完整地址）");
        if (url.EndsWith("/v1", StringComparison.Ordinal))
        {
            say("提示：Claude Code 会自己在地址后面加 /v1/…，已去掉你填的 /v1。");
            url = url[..^3];
        }
        Gateway.ParseHeaderPairs(headers);   // 只做格式检查
        _conf.Set("base_url", url);
        _conf.Set("headers", headers);
        say($"已保存到 {paths.ClaudeConf}。");
        if (!string.IsNullOrEmpty(key)) { secrets.Set(Gateway.SecretName(url), key); say("key 已存入 Windows 凭据管理器。"); }
        return url;
    }

    public void SetKey(string key)
    {
        var cfg = LoadConfig();
        if (cfg.BaseUrl.Length == 0) throw new SwitchException("请先配置 API 地址。");
        if (key.Length == 0) throw new SwitchException("未输入 key。");
        secrets.Set(Gateway.SecretName(cfg.BaseUrl), key);
        say("已存入 Windows 凭据管理器。");
    }

    public void ForgetKey()
    {
        var cfg = LoadConfig();
        if (cfg.BaseUrl.Length == 0) throw new SwitchException("请先配置 API 地址。");
        say(secrets.Delete(Gateway.SecretName(cfg.BaseUrl)) ? "已从凭据管理器删除。" : "凭据管理器里没有保存的 key。");
    }

    // ---------- 切换 ----------
    /// <summary>切到 API。地址和 key 必须已经配好（调用方先用 LoadConfig / HasKey 检查，缺了先让用户配置）。</summary>
    public async Task SwitchToApiAsync()
    {
        var cfg = LoadConfig();
        if (cfg.BaseUrl.Length == 0) throw new SwitchException("还没有配置 API 地址。");
        var key = secrets.Get(Gateway.SecretName(cfg.BaseUrl));
        if (string.IsNullOrEmpty(key)) throw new SwitchException($"还没有保存 {Gateway.UrlHost(cfg.BaseUrl)} 的 API key。");

        // 先用 key 探测地址：明确被拒（401/403）就停下，连不上或别的状态码放行
        var status = await Gateway.ProbeAsync(cfg.BaseUrl + "/v1/models", key, cfg.Headers, http);
        if (Gateway.Rejected(status))
            throw new SwitchException($"这个 API key 在 {cfg.BaseUrl} 上无效（HTTP {status}）。每个网关的 key 不通用，请在“配置 Claude Code API”里填写该地址对应的 key。");

        var before = ReadEnv();
        var obj = JsonFile.ReadObject(paths.ClaudeSettings);
        BackupSettings();
        if (obj["env"] is not JsonObject env) obj["env"] = env = [];
        env["ANTHROPIC_BASE_URL"] = cfg.BaseUrl;
        env["ANTHROPIC_AUTH_TOKEN"] = key;
        var lines = Gateway.HeaderLines(cfg.Headers);
        if (lines.Length > 0) env["ANTHROPIC_CUSTOM_HEADERS"] = lines; else env.Remove("ANTHROPIC_CUSTOM_HEADERS");
        JsonFile.Write(paths.ClaudeSettings, obj);

        say($"已切到 API 模式（{cfg.BaseUrl}）。终端和 IDE 插件里新开的 Claude Code 会话立即生效。");
        if (before.HasForeignApiKey) say("注意：settings.json 的 env 里另有 ANTHROPIC_API_KEY，不是本程序写的；切回账号时它仍会盖过账号登录。");
    }

    public void SwitchToAccount()
    {
        var before = ReadEnv();
        var obj = JsonFile.ReadObject(paths.ClaudeSettings);
        BackupSettings();
        if (obj["env"] is JsonObject env)
        {
            foreach (var k in EnvKeys) env.Remove(k);
            if (env.Count == 0) obj.Remove("env");
        }
        if (File.Exists(paths.ClaudeSettings) || obj.Count > 0) JsonFile.Write(paths.ClaudeSettings, obj);

        say(AccountLoggedIn()
            ? "已切回 Claude 账号模式（账号仍在登录状态）。"
            : "已切回 Claude 账号模式。当前没有账号登录态，请在 Claude Code 里运行 /login 登录。");
        if (before.HasForeignApiKey) say("注意：settings.json 的 env 里另有 ANTHROPIC_API_KEY，不是本程序写的，它会盖过账号登录；不需要的话请手动删掉。");
    }

    public List<string> Status()
    {
        var cfg = LoadConfig();
        var env = ReadEnv();
        var lines = new List<string>();
        if (env.BaseUrl.Length > 0)
        {
            lines.Add("模式：API（终端和 IDE 插件）");
            lines.Add($"请求发往：{env.BaseUrl}");
            if (cfg.BaseUrl.Length > 0 && cfg.BaseUrl.TrimEnd('/') != env.BaseUrl.TrimEnd('/'))
                lines.Add($"新地址尚未生效：{cfg.BaseUrl}（重新切换到 API 后生效）");
        }
        else
        {
            lines.Add("模式：Claude 账号");
            lines.Add("API 地址（切换后使用）：" + (cfg.BaseUrl.Length > 0 ? cfg.BaseUrl : "未配置"));
        }
        var email = AccountEmail();
        lines.Add(AccountLoggedIn() ? (email.Length > 0 ? $"账号：已登录（{email}）" : "账号：已登录") : "账号：未登录");
        if (cfg.BaseUrl.Length > 0) lines.Add(HasKey(cfg.BaseUrl) ? "凭据管理器：已保存 key" : "凭据管理器：未保存 key");
        if (env.HasForeignApiKey) lines.Add("注意：settings.json 里另有 ANTHROPIC_API_KEY，会盖过账号登录");
        return lines;
    }

    // ---------- 备份：每次写 settings.json 之前复制一份，只留最近 20 次 ----------
    void BackupSettings()
    {
        if (!File.Exists(paths.ClaudeSettings)) return;
        var dir = Path.Combine(paths.ClaudeBackups, DateTime.Now.ToString("yyyyMMdd-HHmmss"));
        Directory.CreateDirectory(dir);
        File.Copy(paths.ClaudeSettings, Path.Combine(dir, "settings.json"), overwrite: true);
        var old = Directory.GetDirectories(paths.ClaudeBackups)
            .Where(d => BackupDirName().IsMatch(Path.GetFileName(d)))
            .OrderByDescending(d => Path.GetFileName(d), StringComparer.Ordinal)
            .Skip(KeepBackups);
        foreach (var d in old) { try { Directory.Delete(d, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
    }

    static string StripV1(string url)
    {
        url = url.TrimEnd('/');
        return url.EndsWith("/v1", StringComparison.Ordinal) ? url[..^3] : url;
    }

    static bool OnPath(string command)
    {
        var exts = OperatingSystem.IsWindows() ? new[] { ".exe", ".cmd", ".bat", ".ps1" } : [""];
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
            foreach (var ext in exts)
                try { if (File.Exists(Path.Combine(dir.Trim('"'), command + ext))) return true; } catch (ArgumentException) { }
        return false;
    }

    [GeneratedRegex(@"^\d{8}-\d{6}$")]
    private static partial Regex BackupDirName();
}
