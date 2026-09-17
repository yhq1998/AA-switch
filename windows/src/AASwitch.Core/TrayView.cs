namespace AASwitch.Core;

/// <summary>
/// 托盘菜单和弹窗该显示什么：纯逻辑，不依赖 WinForms，行为与 macOS 菜单栏版对齐。界面层只管把这里算出来的东西画出来。
/// </summary>
public static class TrayView
{
    static readonly string[] UrlKeys = ["请求发往", "API 地址（切换后使用）", "API 地址"];

    public sealed record Line(string Key, string Value)
    {
        public override string ToString() => Value.Length == 0 ? Key : $"{Key}：{Value}";
    }

    /// <summary>一个产品在菜单里的一组。</summary>
    public sealed record Section(
        string? Unavailable,       // 非空：整组只显示这一句（没装）
        int? Selected,             // 分段控件高亮哪一格：0 账号、1 API、null 都不亮（还没切换过 / 状态不一致）
        string UrlLine,            // 小字：请求发往哪
        bool UrlLineOpensConfigure,
        List<string> Notes,        // 小字说明
        List<string> Warnings,     // ⚠ 行
        List<string> Details,      // “更多”子菜单里的详细信息
        bool CanReapply);

    public static List<Line> Parse(IEnumerable<string> statusLines) => [.. statusLines.Select(l =>
    {
        var i = l.IndexOf('：');
        return i < 0 ? new Line(l, "") : new Line(l[..i], l[(i + 1)..]);
    })];

    public static string ConfiguredUrl(List<Line> info)
    {
        var url = info.FirstOrDefault(l => UrlKeys.Contains(l.Key))?.Value ?? "";
        return url == "未配置" ? "" : url;
    }

    static bool IsWarning(Line l) => l.Key is "注意" or "新地址尚未生效" || l.Value.StartsWith("未登录") || l.Value.StartsWith("未保存");

    static string LoginWord(List<Line> info) => info.FirstOrDefault(l => l.Key == "登录")?.Value ?? "";

    /// <summary>Codex 的两个轴不一致：配置指向网关但用 ChatGPT 登录，或反过来。</summary>
    public static bool IsMixed(IProduct p, string mode, List<Line> info)
    {
        if (!p.IsCodex) return false;
        var login = LoginWord(info);
        return (mode == "api" && login.Length > 0 && !login.StartsWith("API key") && !login.StartsWith("未知")) || (mode == "chatgpt" && login.StartsWith("API key"));
    }

    public static string ShortUrl(string url)
    {
        foreach (var prefix in new[] { "https://", "http://" }) if (url.StartsWith(prefix)) url = url[prefix.Length..];
        return url.TrimEnd('/');
    }

    public static Section Build(IProduct p, string mode, List<string>? statusLines, string appName)
    {
        if (mode == "absent")
            return new Section(p.IsCodex ? "这台电脑上没有找到 Codex（PATH 里没有 codex 命令）" : "这台电脑上没有找到 Claude Code", null, "", false, [], [], [], false);

        var loaded = statusLines is not null;
        var info = Parse(statusLines ?? []);
        var url = ConfiguredUrl(info);
        var mixed = IsMixed(p, mode, info);
        int? selected = mode == "api" ? 1 : mode == p.AccountWord ? 0 : null;

        string urlLine; var opensConfigure = false;
        if (!loaded) urlLine = "读取中…";
        else if (url.Length > 0) urlLine = (mode == "api" ? "API 请求发往 " : "切到 API 后请求发往 ") + ShortUrl(url);
        else { urlLine = "还没配置 API 地址，点击填写…"; opensConfigure = true; }

        var notes = new List<string>();
        if (mode == "none") notes.Add($"还没用 {appName} 切换过，当前按 Codex 自己的设置运行；点一格开始管理");
        if (p.IsCodex) notes.Add("切换前请先关掉 Codex 应用、codex 命令行和 IDE 里的 Codex 会话");

        var warnings = new List<string>();
        if (mixed)
            warnings.Add(mode == "api" ? "⚠ 配置指向 API 网关，但 Codex 用 ChatGPT 账号登录，请求会失败；再点一次当前模式即可修正"
                                       : "⚠ 配置是 ChatGPT 账号模式，但 Codex 用 API key 登录；再点一次当前模式即可修正");
        warnings.AddRange(info.Where(IsWarning).Select(l => "⚠ " + l));

        var details = info.Where(l => !IsWarning(l) && l.Key != "模式" && !UrlKeys.Contains(l.Key)).Select(l => l.ToString()).ToList();
        return new Section(null, selected, urlLine, opensConfigure, notes, warnings, details, mode == "api");
    }

    /// <summary>托盘图标的悬停提示：两个产品各自的模式。Windows 的提示最长 127 个字符，调用方自己截断。</summary>
    public static string Tooltip(IEnumerable<(IProduct Product, string Mode)> products) => string.Join("\n", products.Select(x => $"{x.Product.Name}：" + x.Mode switch
    {
        "api" => "API 模式",
        "none" => "尚未切换过",
        "absent" => "未安装",
        var m when m == x.Product.AccountWord => x.Product.AccountTitle,
        _ => "未知",
    }));

    // ---------- 配置表单 ----------
    /// <summary>地址规范化：去空格和末尾斜杠；Codex 是 OpenAI 风格，只给了域名就补 /v1；Claude Code 自己会加 /v1，填了就去掉。</summary>
    public static (string Url, string? Error) NormalizeUrl(string raw, IProduct p)
    {
        var url = raw.Trim();
        if (url.Length == 0) return ("", "请填写 API 地址。");
        var lower = url.ToLowerInvariant();
        if (!lower.StartsWith("https://") && !lower.StartsWith("http://")) return (url, $"地址要以 https:// 开头，例如 {p.UrlPlaceholder}。");
        if (url.Any(c => char.IsWhiteSpace(c) || c is '"' or '\\')) return (url, "地址里不能有空格或引号。");
        url = url.TrimEnd('/');
        var afterScheme = url[(url.IndexOf("://", StringComparison.Ordinal) + 3)..];
        var host = afterScheme.Split('/')[0];
        if (!host.Contains('.') && !host.StartsWith("localhost")) return (url, $"地址里看不到域名，例如 {p.UrlPlaceholder}。");
        if (p.IsCodex) { if (!afterScheme.Contains('/')) url += "/v1"; }
        else if (url.EndsWith("/v1", StringComparison.Ordinal)) url = url[..^3];
        return (url, null);
    }

    public sealed record ProbeResult(bool Ok, string? Message, bool Blocking);

    /// <summary>探测结果分类：2xx 通过；401/403 是 key 不对（拦下）；其他情况告诉用户但允许坚持保存。status 为 0 表示连不上。</summary>
    public static ProbeResult ClassifyProbe(int status, string endpoint, string url) => status switch
    {
        0 => new(false, $"连不上 {endpoint}（超时或域名不对）。", false),
        >= 200 and < 300 => new(true, null, false),
        401 or 403 => new(false, $"这个 key 在 {url} 上无效（HTTP {status}）。每个网关的 key 不通用，请填该地址对应的 key。", true),
        404 => new(false, $"地址能连上，但 {endpoint} 不存在（HTTP 404），地址的路径可能不对。", false),
        _ => new(false, $"地址返回了 HTTP {status}，可能不是一个兼容的网关。", false),
    };

    // ---------- 初始设置 ----------
    public static string DetectedText(IProduct p, string mode, List<Line> info)
    {
        if (!p.IsCodex) return mode switch { "api" => "API 模式", "account" => "账号模式", _ => "状态未知" };
        var login = LoginWord(info);
        var tail = login.Length == 0 ? "" : $"，登录方式：{login}";
        return mode switch
        {
            "none" => "尚未用 AA Switch 切换过，按 Codex 自己的设置运行" + tail,
            "api" => "请求发往 API 网关" + tail,
            "chatgpt" => "ChatGPT 账号模式" + tail,
            _ => "状态未知",
        };
    }

    /// <summary>用户在初始设置里选了 wantApi，要不要真的切一次：只对“选的和现状不一致”的产品切；Codex 的混合状态也算不一致。</summary>
    public static bool NeedsSwitch(IProduct p, string mode, List<Line> info, bool wantApi)
    {
        var mixed = IsMixed(p, mode, info);
        if (wantApi) return !(mode == "api" && !mixed);
        return p.IsCodex ? !((mode is "chatgpt" or "none") && !mixed) : mode != "account";
    }
}
