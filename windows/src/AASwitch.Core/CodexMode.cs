using System.Text.RegularExpressions;

namespace AASwitch.Core;

/// <summary>
/// Codex 在「ChatGPT 账号」和「自定义 API」之间切换，对应 macOS 版的 codex-mode 脚本，历史会话在两种模式下都能继续。
/// 原理：Codex 把每条会话创建时用的 provider 名记在会话里，配置里必须有同名 provider 才能继续该会话。所以 config.toml 的默认
/// provider 固定为一个名字，两种模式都不改这一行，只改 provider 块里的 base_url / http_headers；历史上出现过的其他 provider 名都
/// 写成指向同一地址的别名块。指向其他服务且自带密钥（env_key）的 provider 原样保留。内置的 openai 不允许被覆盖，记成 openai
/// 的会话改记为默认 provider（改前有备份）。
/// 退出 / 重开 Codex 桌面应用不在这里做：调用方保证切换时没有 Codex 进程在跑（runningCodex 返回非空就拒绝切换）。
/// </summary>
public sealed partial class CodexMode(AppPaths paths, ISecretStore secrets, ICodexCli? codex, Action<string> say,
    Func<IReadOnlyList<string>>? runningCodex = null, HttpMessageHandler? http = null)
{
    const int KeepBackups = 20;
    readonly ConfFile _conf = new(paths.CodexConf);
    readonly CodexSessions _sessions = new(paths.CodexHome);

    public sealed record Config(string BaseUrl, string HeadersToml, string Provider)
    {
        public string HeaderPairs => CodexToml.TomlToPairs(HeadersToml);
    }

    CodexToml Toml() => CodexToml.Load(paths.CodexConfig);

    // ---------- 读状态 ----------
    /// <summary>已保存的配置；首次运行从现有 config.toml 的默认 provider 推断。</summary>
    public Config LoadConfig()
    {
        string url = _conf.Get("base_url"), headers = _conf.Get("headers"), provider = _conf.Get("provider");
        if (url.Length == 0)
        {
            var toml = Toml();
            var cur = toml.PreambleProvider();
            if (cur.Length > 0 && cur != "openai")
            {
                var found = toml.SectionValue(cur, "base_url");
                if (found.Length > 0)
                {
                    url = found; headers = toml.SectionValue(cur, "http_headers");
                    if (provider.Length == 0) provider = cur;
                    _conf.Set("base_url", url); _conf.Set("headers", headers); _conf.Set("provider", provider);
                    say($"已从现有配置读取 API 地址 {url}，保存到 {paths.CodexConf}。");
                }
            }
        }
        return new Config(url, headers, provider);
    }

    /// <summary>api / chatgpt / none（还没切换过），给托盘菜单用。</summary>
    public string ModeWord()
    {
        var toml = Toml();
        var p = toml.PreambleProvider();
        if (p.Length == 0 || p == "openai") return "none";
        return toml.SectionValue(p, "base_url", activeOnly: true).Length > 0 ? "api" : "chatgpt";
    }

    /// <summary>chatgpt / api_key / ""（未登录或没有 codex 命令行）。</summary>
    public string AuthMode()
    {
        if (codex is null) return "";
        var s = codex.LoginStatus();
        if (s.Contains("ChatGPT", StringComparison.Ordinal) || s.Contains("chatgpt", StringComparison.Ordinal)) return "chatgpt";
        if (s.Contains("API key", StringComparison.Ordinal) || s.Contains("api key", StringComparison.Ordinal) || s.Contains("api_key", StringComparison.Ordinal)) return "api_key";
        return "";
    }

    public bool HasKey(string url) => !string.IsNullOrEmpty(secrets.Get(Gateway.SecretName(url)));

    // ---------- 配置 ----------
    public string Configure(string url, string headerPairs, string? key)
    {
        url = url.Trim().TrimEnd('/');
        if (!Gateway.ValidUrl(url)) throw new SwitchException($"地址格式不对：{url}（需要以 http:// 或 https:// 开头的完整地址）");
        if (!url[(url.IndexOf("://", StringComparison.Ordinal) + 3)..].Contains('/'))
        {
            url += "/v1";
            say($"提示：OpenAI 风格的地址通常以 /v1 结尾，已补上：{url}");
        }
        var toml = CodexToml.PairsToToml(headerPairs);
        _conf.Set("base_url", url); _conf.Set("headers", toml);
        say($"已保存到 {paths.CodexConf}。");
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

    /// <summary>不问用户地找 key：凭据管理器里这个地址的 → Codex 当前正在用的 API key（找到就存进凭据管理器）。找不到返回 ""。</summary>
    public string DiscoverKey(string url)
    {
        var name = Gateway.SecretName(url);
        var key = secrets.Get(name) ?? "";
        if (key.Length == 0 && AuthMode() == "api_key")
        {
            try { key = JsonFile.String(JsonFile.ReadObject(paths.CodexAuth)["OPENAI_API_KEY"]) ?? ""; } catch (SwitchException) { }
            if (key.Length > 0) { secrets.Set(name, key); say($"已把当前正在使用的 API key 保存到凭据管理器条目 {name}。"); }
        }
        return key;
    }

    // ---------- 切换 ----------
    public async Task SwitchToApiAsync()
    {
        NeedCodex();
        var cfg = LoadConfig();
        if (cfg.BaseUrl.Length == 0) throw new SwitchException("还没有配置 API 地址。");
        var key = DiscoverKey(cfg.BaseUrl);
        if (key.Length == 0) throw new SwitchException($"还没有保存 {Gateway.UrlHost(cfg.BaseUrl)} 的 API key。");
        var status = await Gateway.ProbeAsync(cfg.BaseUrl.TrimEnd('/') + "/models", key, cfg.HeaderPairs, http);
        if (Gateway.Rejected(status))
            throw new SwitchException($"这个 API key 在 {cfg.BaseUrl} 上无效（HTTP {status}）。每个网关的 key 不通用，请在“配置 API 地址 / key”里填写该地址对应的 key。");
        EnsureNotRunning();
        var backup = PrepareSwitch(cfg, apiMode: true);
        if (!codex!.LoginWithApiKey(key))
        {
            Restore(backup);
            throw new SwitchException("用 API key 登录失败，已恢复到切换前。请检查 key 后重试。");
        }
        say($"已切到 API 模式（{cfg.BaseUrl}）。");
    }

    public void SwitchToChatGpt()
    {
        NeedCodex();
        var cfg = LoadConfig();
        EnsureNotRunning();
        PrepareSwitch(cfg, apiMode: false);
        if (AuthMode() == "chatgpt") say("已切到账号模式（账号仍在登录状态）。");
        else if (RestoreChatGptAuth()) say("已切到账号模式并恢复了之前的 ChatGPT 登录态。");
        else { codex!.Logout(); say("已切到账号模式，请在 Codex 里用 ChatGPT 账号登录。"); }
    }

    /// <summary>只做「统一会话 provider」这一步，不改模式。</summary>
    public void FixThreads()
    {
        NeedCodex();
        var cfg = LoadConfig();
        EnsureNotRunning();
        PrepareSwitch(cfg, apiMode: ModeWord() == "api");
    }

    public List<string> Status()
    {
        var cfg = LoadConfig();
        var toml = Toml();
        var p = toml.PreambleProvider();
        var active = toml.SectionValue(p, "base_url", activeOnly: true);
        var unset = cfg.BaseUrl.Length > 0 ? cfg.BaseUrl : "未配置";
        var lines = new List<string>();
        if (p.Length == 0 || p == "openai") { lines.Add("模式：尚未切换过"); lines.Add($"API 地址：{unset}"); }
        else if (active.Length > 0)
        {
            lines.Add("模式：API"); lines.Add($"请求发往：{active}");
            if (cfg.BaseUrl.Length > 0 && cfg.BaseUrl.TrimEnd('/') != active.TrimEnd('/')) lines.Add($"新地址尚未生效：{cfg.BaseUrl}（重新切换到 API 后生效）");
        }
        else { lines.Add("模式：ChatGPT 账号"); lines.Add($"API 地址（切换后使用）：{unset}"); }
        if (codex is not null)
            lines.Add("登录：" + AuthMode() switch { "chatgpt" => "ChatGPT 账号", "api_key" => "API key", _ => "未登录" });
        else lines.Add("登录：未知（没有找到 codex 命令行）");
        if (cfg.BaseUrl.Length > 0) lines.Add(HasKey(cfg.BaseUrl) ? "凭据管理器：已保存 key" : "凭据管理器：未保存 key");
        var pending = _sessions.CountOpenAiThreads();
        if (pending > 0) lines.Add($"待统一的会话：{pending} 条记成 openai，下次切换时会处理");
        return lines;
    }

    // ---------- 一次切换的公共部分：备份 → 规划 → 写配置 → 统一会话 → 校验 ----------
    CodexBackup PrepareSwitch(Config cfg, bool apiMode)
    {
        Directory.CreateDirectory(paths.CodexHome);
        var backup = new CodexBackup(paths.CodexHome, Path.Combine(paths.CodexBackups, DateTime.Now.ToString("yyyyMMdd-HHmmss")));
        Directory.CreateDirectory(backup.Dir);
        PruneBackups();
        backup.File(paths.CodexConfig);
        backup.File(paths.CodexAuth);   // 登录态也备份，回滚时一起恢复
        StashChatGptAuth();

        var toml = Toml();
        var (managed, kept) = PlanProviders(toml, cfg.Provider, cfg.BaseUrl);
        var provider = ChooseProvider(toml, cfg, kept);
        (managed, _) = PlanProviders(toml, provider, cfg.BaseUrl);
        AtomicFile.WriteAllText(paths.CodexConfig, toml.Rewrite(provider, managed, apiMode, cfg.BaseUrl, cfg.HeadersToml));

        var n = _sessions.FixThreads(provider, backup);
        say(n > 0 ? $"已把 {n} 处账号时期的会话记录改记为 {provider}（改前有备份）。" : "会话 provider 已统一，无需处理。");

        // 让 Codex 自己读一遍新配置：login status 会完整加载配置（语法、provider 引用都查）
        var check = codex!.LoginStatus();
        if (check.Contains("error loading config", StringComparison.OrdinalIgnoreCase))
        {
            foreach (var line in check.Split('\n').Where(l => l.Contains("error", StringComparison.OrdinalIgnoreCase))) say(line.TrimEnd());
            Restore(backup);
            throw new SwitchException($"新配置没有通过 Codex 校验，已恢复。备份在 {backup.Dir}，请把上面的错误发给管理员。");
        }
        say($"切换前的备份：{backup.Dir}");
        return backup;
    }

    /// <summary>哪些 provider 名写成别名（managed），哪些指向别的服务且自带密钥要保留（kept）。</summary>
    (List<string> Managed, List<string> Kept) PlanProviders(CodexToml toml, string provider, string baseUrl)
    {
        var inventory = toml.Inventory();
        var names = new[] { provider }.Concat(inventory.Select(p => p.Name)).Append(toml.PreambleProvider()).Concat(_sessions.HistoryProviders())
            .Where(n => n.Length > 0 && n != "openai" && n.IndexOfAny(['\\', '"']) < 0).Distinct().ToList();
        List<string> managed = [], kept = [];
        foreach (var name in names)
        {
            var p = inventory.FirstOrDefault(x => x.Name == name);
            var foreign = p is not null && p.BaseUrl.Length > 0 && p.BaseUrl.TrimEnd('/') != baseUrl.TrimEnd('/') && p.EnvKey.Length > 0;
            (foreign ? kept : managed).Add(name);
        }
        return (managed, kept);
    }

    /// <summary>默认 provider 名：沿用配置里已有的；否则按地址域名生成；不能和保留的 provider 重名。</summary>
    string ChooseProvider(CodexToml toml, Config cfg, List<string> kept)
    {
        var p = cfg.Provider;
        if (p.Length == 0 || p == "openai") p = toml.PreambleProvider();
        if (p.Length == 0 || p == "openai" || !BareName().IsMatch(p))
        {
            p = NotBare().Replace(Gateway.UrlHost(cfg.BaseUrl), "_");
            if (p.Length == 0) p = "codex_mode";
        }
        while (kept.Contains(p)) p += "_api";
        _conf.Set("provider", p);
        return p;
    }

    void Restore(CodexBackup backup) { backup.RestoreAll(); say("已把配置和会话恢复到切换前的状态。"); }

    // ---------- ChatGPT 登录态存档：切走前存一份，切回来直接恢复，不用重新登录 ----------
    void StashChatGptAuth()
    {
        if (!File.Exists(paths.CodexAuth) || AuthMode() != "chatgpt") return;
        if (!File.ReadAllText(paths.CodexAuth).Contains("\"refresh_token\"", StringComparison.Ordinal)) return;
        Directory.CreateDirectory(Path.GetDirectoryName(paths.CodexAuthStash)!);
        File.Copy(paths.CodexAuth, paths.CodexAuthStash, overwrite: true);
        OwnerOnly(paths.CodexAuthStash);
    }

    bool RestoreChatGptAuth()
    {
        if (!File.Exists(paths.CodexAuthStash)) return false;
        File.Copy(paths.CodexAuthStash, paths.CodexAuth, overwrite: true);
        OwnerOnly(paths.CodexAuth);
        return AuthMode() == "chatgpt";
    }

    // Windows 的用户目录本来就只有本人能读；其他系统上收紧成 600
    static void OwnerOnly(string path)
    {
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
    }

    void NeedCodex()
    {
        if (codex is null) throw new SwitchException("找不到 Codex 命令行（PATH 里的 codex），可用环境变量 CODEX_BIN 指定。");
    }

    void EnsureNotRunning()
    {
        var running = runningCodex?.Invoke() ?? [];
        if (running.Count > 0)
            throw new SwitchException($"还有 Codex 在运行（{string.Join("、", running)}），请先关闭 Codex 应用、codex 命令行和 IDE 里的 Codex 会话再切换，避免同时写会话记录。");
    }

    void PruneBackups()
    {
        if (!Directory.Exists(paths.CodexBackups)) return;
        var old = Directory.GetDirectories(paths.CodexBackups)
            .Where(d => BackupDirName().IsMatch(Path.GetFileName(d)))
            .OrderByDescending(d => Path.GetFileName(d), StringComparer.Ordinal).Skip(KeepBackups);
        foreach (var d in old) { try { Directory.Delete(d, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
    }

    [GeneratedRegex(@"^[A-Za-z0-9_-]+$")] private static partial Regex BareName();
    [GeneratedRegex(@"[^A-Za-z0-9_-]")] private static partial Regex NotBare();
    [GeneratedRegex(@"^\d{8}-\d{6}$")] private static partial Regex BackupDirName();
}
