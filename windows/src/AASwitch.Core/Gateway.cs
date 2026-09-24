using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.RegularExpressions;

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
    public static async Task<int> ProbeAsync(string modelsUrl, string key, string headerPairs, HttpMessageHandler? handler = null) =>
        (await ProbeWithReasonAsync(modelsUrl, key, headerPairs, handler)).Status;

    /// <summary>同 ProbeAsync，出错时（HTTP ≥ 300）再带上网关自己给的原因（见 GatewayMessage），没有就是 null。</summary>
    public static async Task<(int Status, string? Reason)> ProbeWithReasonAsync(string modelsUrl, string key, string headerPairs, HttpMessageHandler? handler = null)
    {
        using var http = handler is null ? new HttpClient() : new HttpClient(handler, disposeHandler: false);
        http.Timeout = TimeSpan.FromSeconds(15);
        using var req = new HttpRequestMessage(HttpMethod.Get, modelsUrl);
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        foreach (var (name, value) in ParseHeaderPairs(headerPairs)) req.Headers.TryAddWithoutValidation(name, value);
        try
        {
            using var resp = await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead);
            var status = (int)resp.StatusCode;
            if (status < 300) return (status, null);
            string body;
            try { body = await resp.Content.ReadAsStringAsync(); } catch (Exception e) when (e is HttpRequestException or TaskCanceledException or IOException) { body = ""; }
            return (status, GatewayMessage(body));
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or InvalidOperationException) { return (0, null); }
    }

    /// <summary>
    /// 从出错响应里取网关的说明：{"error":{"message":…}}、{"error":"…"}、{"message":…}；去掉请求 ID，遮住里面带的 key 片段，
    /// 最长 200 字。不是 JSON 或没有说明时返回 null。与 macOS 版的 gatewayMessage 一致。
    /// </summary>
    public static string? GatewayMessage(string body)
    {
        string? text = null;
        try
        {
            using var doc = JsonDocument.Parse(body);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            if (root.TryGetProperty("error", out var err))
            {
                if (err.ValueKind == JsonValueKind.Object && err.TryGetProperty("message", out var m) && m.ValueKind == JsonValueKind.String) text = m.GetString();
                else if (err.ValueKind == JsonValueKind.String) text = err.GetString();
            }
            if (text is null && root.TryGetProperty("message", out var msg) && msg.ValueKind == JsonValueKind.String) text = msg.GetString();
        }
        catch (JsonException) { return null; }
        if (text is null) return null;
        text = Regex.Replace(text, @"\s*[(（]\s*request id[^)）]*[)）]", "", RegexOptions.IgnoreCase);
        text = Regex.Replace(text, @"sk-[A-Za-z0-9_*\-]+", "sk-…");
        text = text.Trim();
        if (text.Length > 200) text = text[..200] + "…";
        return text.Length == 0 ? null : text;
    }

    /// <summary>key 里不会有空白和不可见字符：粘贴带进来的换行、零宽空格（Unicode 格式字符）一并去掉。</summary>
    public static string CleanKey(string key) => new(key.Where(c => !char.IsWhiteSpace(c) && !char.IsControl(c)
        && CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.Format).ToArray());

    public static bool Rejected(int status) => status is (int)HttpStatusCode.Unauthorized or (int)HttpStatusCode.Forbidden;
}
