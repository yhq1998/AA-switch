using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace AASwitch.Core;

/// <summary>
/// Claude 桌面应用（Code、Cowork 标签）在「Claude 账号」和「API 网关」之间切换，对应 macOS 版 claude-mode 的 desktop gateway / desktop account。
/// 桌面应用里的 Code 标签不认 ~/.claude/settings.json 的 env，只能把整个应用切到第三方推理模式：
///   %LOCALAPPDATA%\Claude-3p\claude_desktop_config.json 的 deploymentMode（1p 账号，3p 网关），启动时生效；
///   网关地址、key、模型列表在同目录的 configLibrary\&lt;id&gt;.json，_meta.json 的 appliedId 指向在用的那份。
/// 两种模式的数据目录是分开的（账号模式在应用商店版的 LocalCache\Roaming\Claude），所以切换时把两边的 Code 会话列表互相补齐、
/// Cowork 会话互相同步（见 DesktopSessions）。改之前先备份，改完退出并重新打开应用（原来没开着就等下次打开生效）。
/// </summary>
public sealed class ClaudeDesktop(ClaudeDesktopPaths dp, AppPaths paths, IDesktopApp app, Action<string> say)
{
    public const string AppName = "Claude 桌面应用";
    /// <summary>没配过 desktop_models 时用的列表（第一个是桌面应用的默认模型），和 macOS 版相同。</summary>
    public const string DefaultModels = "claude-opus-5-5,claude-sonnet-5,claude-haiku-4-5,claude-fable-5-1";

    readonly ConfFile _conf = new(paths.ClaudeConf);

    public ClaudeDesktopPaths Paths => dp;
    public bool Installed => dp.Installed;
    string GatewayConfig => Path.Combine(dp.GatewayDir, "claude_desktop_config.json");
    string Library => Path.Combine(dp.GatewayDir, "configLibrary");
    string Meta => Path.Combine(Library, "_meta.json");

    public sealed record GatewayState(string Deployment, string Provider, string Url);

    public GatewayState ReadGateway()
    {
        var deployment = JsonFile.String(JsonFile.ReadObject(GatewayConfig)["deploymentMode"]) ?? "";
        var id = JsonFile.String(JsonFile.ReadObject(Meta)["appliedId"]) ?? "";
        if (!SafeId(id)) return new(deployment, "", "");
        var g = JsonFile.ReadObject(Path.Combine(Library, id + ".json"));
        return new(deployment, JsonFile.String(g["inferenceProvider"]) ?? "", JsonFile.String(g["inferenceGatewayBaseUrl"]) ?? "");
    }

    /// <summary>gateway / account / absent。</summary>
    public string ModeWord()
    {
        if (!Installed) return "absent";
        try { var s = ReadGateway(); return s.Deployment == "3p" && s.Provider == "gateway" ? "gateway" : "account"; }
        catch (SwitchException) { return "account"; }
    }

    public List<string> Models()
    {
        var raw = _conf.Get("desktop_models");
        var list = (raw.Length > 0 ? raw : DefaultModels).Split(',').Select(m => m.Trim()).Where(m => m.Length > 0).ToList();
        return list.Count > 0 ? list : [.. DefaultModels.Split(',')];
    }

    /// <summary>桌面应用用的网关地址：claude-mode.conf 的 desktop_base_url，没配就同命令行（不带 /v1，应用自己加 /v1/messages）。</summary>
    public string GatewayUrl(string baseUrl)
    {
        var url = _conf.Get("desktop_base_url");
        return (url.Length > 0 ? url : baseUrl).TrimEnd('/');
    }

    public List<string> Status()
    {
        var lines = new List<string>();
        var mode = ModeWord();
        if (mode == "absent") return lines;
        if (mode == "gateway") lines.Add($"桌面应用：网关模式（{ReadGateway().Url}）");
        else lines.Add("桌面应用：账号模式");
        var models = Models();
        lines.Add($"桌面模型：默认 {models[0]}，共 {models.Count} 个");
        return lines;
    }

    // ---------- 切换 ----------
    public void SwitchToGateway(string baseUrl, string key)
    {
        if (!Installed) throw new SwitchException($"这台电脑上没有找到 {AppName}。");
        var url = GatewayUrl(baseUrl);
        var models = Models();
        Apply(() => { WriteGateway(url, key, models); SetDeployment("3p"); },
              $"已把 {AppName}切到网关模式（{url}，模型：{string.Join(",", models)}）。");
    }

    public void SwitchToAccount()
    {
        if (!Installed) throw new SwitchException($"这台电脑上没有找到 {AppName}。");
        Apply(() => SetDeployment("1p"), $"已把 {AppName}切回账号模式。");
    }

    /// <summary>只同步两边的会话（不改模式）。应用开着时 Cowork 会话可能正写到一半，跳过。</summary>
    public void SyncOnly()
    {
        if (!Installed) throw new SwitchException($"这台电脑上没有找到 {AppName}。");
        var bk = Backup();
        Sessions.SyncCode();
        if (app.Running()) say($"Cowork 会话要在 {AppName}退出后才能同步（切换时会自动做），这次跳过。");
        else Sessions.SyncCowork(bk);
    }

    DesktopSessions Sessions => new(dp, paths, say);

    /// <summary>备份 → 退出应用 → 改配置 → 同步会话 → 重新打开。先退出再改：应用退出时会把内存里的设置写回 claude_desktop_config.json，
    /// 开着的时候改可能被盖掉；会话文件也可能正写到一半。</summary>
    void Apply(Action write, string done)
    {
        var bk = Backup();
        var wasRunning = app.Running();
        if (wasRunning) { say($"正在退出 {AppName}…"); app.Quit(); }
        var ok = false;
        try
        {
            write();
            Sessions.SyncCode();
            Sessions.SyncCowork(bk);
            say(done);
            ok = true;
        }
        finally
        {
            if (wasRunning)
                try { app.Open(); } catch (Exception e) { say($"请手动打开 {AppName}（自动打开失败：{e.Message}）。"); }
            else if (ok) say($"{AppName}没有在运行，下次打开时生效。");
        }
    }

    string Backup()
    {
        var bk = ClaudeMode.NewBackupDir(paths);
        var dir = Path.Combine(bk, "desktop");
        Directory.CreateDirectory(dir);
        if (File.Exists(GatewayConfig)) File.Copy(GatewayConfig, Path.Combine(dir, "claude_desktop_config.json"), overwrite: true);
        var account = Path.Combine(dp.AccountDir, "claude_desktop_config.json");
        if (File.Exists(account)) File.Copy(account, Path.Combine(dir, "account-claude_desktop_config.json"), overwrite: true);
        if (Directory.Exists(Library)) DesktopSessions.CopyDir(Library, Path.Combine(dir, "configLibrary"));
        ClaudeMode.PruneBackups(paths);
        return bk;
    }

    void SetDeployment(string mode)
    {
        var o = JsonFile.ReadObject(GatewayConfig);
        o["deploymentMode"] = mode;
        JsonFile.Write(GatewayConfig, o);
    }

    /// <summary>写进 appliedId 指向的那份配置（用户在应用里自己建过就沿用），没有就新建一份叫 “AA Switch” 的。</summary>
    void WriteGateway(string url, string key, List<string> models)
    {
        var meta = JsonFile.ReadObject(Meta);
        if (meta["entries"] is not JsonArray entries) meta["entries"] = entries = [];
        var id = JsonFile.String(meta["appliedId"]) ?? "";
        if (!SafeId(id) || !entries.Any(e => JsonFile.String(e?["id"]) == id))
        {
            id = Guid.NewGuid().ToString();
            entries.Add(new JsonObject { ["id"] = id, ["name"] = "AA Switch" });
            meta["appliedId"] = id;
        }
        var file = Path.Combine(Library, id + ".json");
        var g = JsonFile.ReadObject(file);
        g["inferenceProvider"] = "gateway";
        g["inferenceGatewayBaseUrl"] = url;
        g["inferenceGatewayApiKey"] = key;
        g["inferenceGatewayAuthScheme"] = "bearer";
        // 名字后面加 [1m]：桌面应用把模型名原样交给 Claude Code，带 [1m] 才按 1M 上下文算（和命令行的默认一样）
        g["inferenceModels"] = new JsonArray([.. models.Select(m => (JsonNode)With1M(m))]);
        JsonFile.Write(file, g);
        JsonFile.Write(Meta, meta);
    }

    public static string With1M(string model) => model.EndsWith("[1m]", StringComparison.OrdinalIgnoreCase) ? model : model + "[1m]";

    /// <summary>appliedId 要拿来拼文件名：只认 uuid 这类字符，防止指到目录外面。</summary>
    static bool SafeId(string id) => Regex.IsMatch(id, "^[0-9A-Za-z-]{1,64}$");
}

/// <summary>Claude 桌面应用在这台电脑上的位置。</summary>
/// <param name="AccountDir">账号模式的数据目录：应用商店版是 %LOCALAPPDATA%\Packages\Claude_…\LocalCache\Roaming\Claude（应用自己看到的是 %APPDATA%\Claude，
/// 系统替它重定向了），安装包版是 %APPDATA%\Claude。</param>
/// <param name="GatewayDir">网关模式的数据目录：%LOCALAPPDATA%\Claude-3p（应用商店版实测不在 LocalCache 里）。</param>
/// <param name="PackageDir">应用商店版的包目录（%LOCALAPPDATA%\Packages\Claude_…），不是应用商店版为 null。</param>
/// <param name="InstallerDir">安装包版的安装目录（%LOCALAPPDATA%\AnthropicClaude）。</param>
public sealed record ClaudeDesktopPaths(string AccountDir, string GatewayDir, string? PackageDir, string InstallerDir, string LocalAppData, string AppData)
{
    public bool Installed => PackageDir is not null || Directory.Exists(InstallerDir) || Directory.Exists(AccountDir);
    /// <summary>应用商店版的包系列名（Claude_pzs8sxrjxfjjc），用来通过 shell:AppsFolder 打开应用。</summary>
    public string? PackageFamily => PackageDir is null ? null : Path.GetFileName(PackageDir);

    public static ClaudeDesktopPaths Discover(string localAppData, string appData)
    {
        string? package = null;
        var packages = Path.Combine(localAppData, "Packages");
        if (Directory.Exists(packages))
            package = Directory.GetDirectories(packages, "Claude_*")
                .Where(d => Regex.IsMatch(Path.GetFileName(d), "^Claude_[0-9a-z]{13}$"))
                .OrderByDescending(d => Directory.Exists(Path.Combine(d, "LocalCache", "Roaming", "Claude")))
                .FirstOrDefault();
        var account = package is not null ? Path.Combine(package, "LocalCache", "Roaming", "Claude") : Path.Combine(appData, "Claude");
        // 安装包版的 -3p 目录没实测过：%APPDATA% 下已经有就用它，否则和应用商店版一样放 %LOCALAPPDATA%
        var gateway = Path.Combine(localAppData, "Claude-3p");
        var roaming3p = Path.Combine(appData, "Claude-3p");
        if (package is null && !Directory.Exists(gateway) && Directory.Exists(roaming3p)) gateway = roaming3p;
        return new(account, gateway, package, Path.Combine(localAppData, "AnthropicClaude"), localAppData, appData);
    }

    public static ClaudeDesktopPaths FromEnvironment() => Discover(
        CodexCli.KnownFolder("LOCALAPPDATA", Environment.SpecialFolder.LocalApplicationData) ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "AppData", "Local"),
        CodexCli.KnownFolder("APPDATA", Environment.SpecialFolder.ApplicationData) ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "AppData", "Roaming"));

    /// <summary>应用自己眼里的路径：应用商店版把 %APPDATA% / %LOCALAPPDATA% 下的写入重定向进 LocalCache，
    /// 会话记录里写的是重定向之前的路径。不在 LocalCache 里的原样返回。</summary>
    public string AppView(string path)
    {
        if (PackageDir is null) return path;
        foreach (var (sub, real) in new[] { ("Roaming", AppData), ("Local", LocalAppData) })
        {
            var cache = Path.Combine(PackageDir, "LocalCache", sub);
            if (path.Equals(cache, StringComparison.OrdinalIgnoreCase)) return real;
            if (path.StartsWith(cache + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) return real + path[cache.Length..];
        }
        return path;
    }
}
