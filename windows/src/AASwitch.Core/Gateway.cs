using System.Net;
using System.Net.Http.Headers;

namespace AASwitch.Core;

/// <summary>网关地址、请求头和 key 探测，Codex 和 Claude Code 两边共用。</summary>
public static class Gateway
{
    public static bool ValidUrl(string url) =>
        (url.StartsWith("http://", StringComparison.Ordinal) && url.Length > 7 || url.StartsWith("https://", StringComparison.Ordinal) && url.Length > 8)
        && !url.Any(c => char.IsWhiteSpace(c) || c is '"' or '\\');

    public static string UrlHost(string url)
    {
        var scheme = url.IndexOf("://", StringComparison.Ordinal);
        var h = scheme < 0 ? url : url[(scheme + 3)..];
        var slash = h.IndexOf('/'); if (slash >= 0) h = h[..slash];
        var at = h.LastIndexOf('@'); if (at >= 0) h = h[(at + 1)..];
        var colon = h.IndexOf(':'); if (colon >= 0) h = h[..colon];
        return h;
    }

    /// <summary>凭据条目名，与 macOS 钥匙串里的条目同名。</summary>
    public static string SecretName(string url) => "codex-mode:" + UrlHost(url);

    /// <summary>"a=b, c=d" → [(a, b), (c, d)]；格式不对抛 SwitchException。</summary>
    public static List<(string Name, string Value)> ParseHeaderPairs(string pairs)
    {
        var result = new List<(string, string)>();
        foreach (var raw in pairs.Split(','))
        {
            var pair = raw.Trim();
            if (pair.Length == 0) continue;
            var eq = pair.IndexOf('=');
            if (eq < 0) throw new SwitchException($"请求头格式应为 名称=值：{pair}");
            var name = pair[..eq].TrimEnd();
            if (name.Length == 0) throw new SwitchException($"请求头名称不能为空：{pair}");
            result.Add((name, pair[(eq + 1)..].TrimStart()));
        }
        return result;
    }

    /// <summary>ANTHROPIC_CUSTOM_HEADERS 的格式：每行一个 "名称: 值"。</summary>
    public static string HeaderLines(string pairs) => string.Join("\n", ParseHeaderPairs(pairs).Select(p => $"{p.Name}: {p.Value}"));

    /// <summary>用 key 请求 modelsUrl：只返回 HTTP 状态码，连不上返回 0。</summary>
    public static async Task<int> ProbeAsync(string modelsUrl, string key, string headerPairs, HttpMessageHandler? handler = null)
    {
        using var http = handler is null ? new HttpClient() : new HttpClient(handler, disposeHandler: false);
        http.Timeout = TimeSpan.FromSeconds(15);
        using var req = new HttpRequestMessage(HttpMethod.Get, modelsUrl);
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        foreach (var (name, value) in ParseHeaderPairs(headerPairs)) req.Headers.TryAddWithoutValidation(name, value);
        try
        {
            using var resp = await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead);
            return (int)resp.StatusCode;
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or InvalidOperationException) { return 0; }
    }

    public static bool Rejected(int status) => status is (int)HttpStatusCode.Unauthorized or (int)HttpStatusCode.Forbidden;
}
