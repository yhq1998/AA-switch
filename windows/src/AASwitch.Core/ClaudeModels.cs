using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace AASwitch.Core;

/// <summary>Claude desktop model discovery follows the macOS gateway filtering and ordering rules.</summary>
public static class ClaudeModels
{
    public static List<string> Normalize(IEnumerable<string> models)
    {
        var list = models.Select(m => m.Trim()).Where(m => m.Length > 0).ToList();
        if (list.Count == 0 || list.Any(m => !Regex.IsMatch(m, @"^[A-Za-z0-9._-]+(?:\[1m\])?$", RegexOptions.IgnoreCase)))
            throw new SwitchException("模型列表为空，或模型名包含不支持的字符。");
        return list;
    }

    public static List<string> Parse(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var rows = doc.RootElement;
        if (rows.ValueKind == JsonValueKind.Object)
        {
            if (!rows.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Array)
                rows = rows.TryGetProperty("models", out var models) ? models : default;
            else rows = data;
        }
        if (rows.ValueKind != JsonValueKind.Array) throw new SwitchException("网关没有返回模型列表。");
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var row in rows.EnumerateArray())
        {
            var id = row.ValueKind == JsonValueKind.String ? row.GetString()
                : row.ValueKind == JsonValueKind.Object && row.TryGetProperty("id", out var name) && name.ValueKind == JsonValueKind.String ? name.GetString() : null;
            if (id is null || !id.StartsWith("claude-", StringComparison.Ordinal)) continue;
            if (row.ValueKind == JsonValueKind.Object && row.TryGetProperty("supported_endpoint_types", out var kinds)
                && kinds.ValueKind == JsonValueKind.Array && kinds.GetArrayLength() > 0
                && !kinds.EnumerateArray().Any(k => k.ValueKind == JsonValueKind.String && k.GetString() == "anthropic")) continue;
            ids.Add(id);
        }
        var kept = ids.Where(id => !Regex.IsMatch(id, @"-20\d{6}$") || !ids.Contains(Regex.Replace(id, @"-20\d{6}$", ""))).ToList();
        kept.Sort(Compare);
        return Normalize(kept);
    }

    static int Compare(string a, string b)
    {
        static (string Family, int[] Version) Parts(string id)
        {
            var parts = id[7..].Split('-');
            return (string.Join("-", parts.Where(p => !Regex.IsMatch(p, @"^\d+$"))),
                    parts.Where(p => Regex.IsMatch(p, @"^\d+$")).Select(p => int.TryParse(p, out var n) ? n : int.MaxValue).ToArray());
        }
        static int Rank(string family) => family switch { "opus" => 0, "sonnet" => 1, "haiku" => 2, _ => 3 };
        var x = Parts(a); var y = Parts(b);
        var order = Rank(x.Family).CompareTo(Rank(y.Family));
        if (order != 0) return order;
        order = string.CompareOrdinal(x.Family, y.Family);
        if (order != 0) return order;
        for (var i = 0; i < Math.Max(x.Version.Length, y.Version.Length); i++)
        {
            order = (i < y.Version.Length ? y.Version[i] : -1).CompareTo(i < x.Version.Length ? x.Version[i] : -1);
            if (order != 0) return order;
        }
        return string.CompareOrdinal(a, b);
    }

    public static async Task<List<string>> FetchAsync(string url, string key, string headers, HttpMessageHandler? handler = null)
    {
        if (url.Length == 0 || key.Length == 0) throw new SwitchException("请先配置 Claude API 地址和 key。");
        using var http = handler is null ? new HttpClient() : new HttpClient(handler, disposeHandler: false);
        http.Timeout = TimeSpan.FromSeconds(20);
        using var request = new HttpRequestMessage(HttpMethod.Get, url.TrimEnd('/') + "/v1/models");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        foreach (var (name, value) in Gateway.ParseHeaderPairs(headers)) request.Headers.TryAddWithoutValidation(name, value);
        try
        {
            using var response = await http.SendAsync(request);
            if (!response.IsSuccessStatusCode) throw new SwitchException($"网关返回 HTTP {(int)response.StatusCode}，模型列表未改动。");
            return Parse(await response.Content.ReadAsStringAsync());
        }
        catch (JsonException) { throw new SwitchException("看不懂网关返回的模型列表，配置未改动。"); }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException) { throw new SwitchException("无法连接网关获取模型列表，配置未改动。"); }
    }
}
