using System.Security.Cryptography;
using System.Text.Json.Nodes;

namespace AASwitch.Core;

/// <summary>
/// 检查更新和下载新版本。官网的 latest.json 顶层是 macOS 版的字段，Windows 版在 "windows" 这一段：
///   { "version": "2.3.0", …, "windows": { "version": "0.2.0", "date": "2026-09-17", "url": "https://…/AA%20Switch.exe", "sha256": "…" } }
/// Windows 版没有代码签名，下载内容的可信度靠两条：更新地址必须是 https，下载地址必须和 latest.json 同一个主机；再校验 sha256 防传输损坏。
/// （本机回环地址允许 http，测试用。）
/// </summary>
public static class Updater
{
    public sealed record Release(string Version, string Date, string Url, string Sha256);

    /// <summary>解析 latest.json 的 windows 段；没有这一段（还没发布过 Windows 版）返回 null。</summary>
    public static Release? Parse(string json)
    {
        JsonNode? root;
        try { root = JsonNode.Parse(json); } catch (System.Text.Json.JsonException) { throw new SwitchException("官网返回的版本信息读不懂。"); }
        if (root?["windows"] is not JsonObject w) return null;
        var version = JsonFile.String(w["version"]) ?? "";
        if (version.Length == 0) throw new SwitchException("官网返回的版本信息里没有 Windows 版的版本号。");
        return new Release(version, JsonFile.String(w["date"]) ?? "", JsonFile.String(w["url"]) ?? "", (JsonFile.String(w["sha256"]) ?? "").ToLowerInvariant());
    }

    /// <summary>按数字逐段比较："0.10.0" 比 "0.9.1" 新；段数不同按缺的为 0。</summary>
    public static bool IsNewer(string latest, string current)
    {
        static int[] Parts(string s) => [.. s.Split('.').Select(p => int.TryParse(new string([.. p.TakeWhile(char.IsDigit)]), out var n) ? n : 0)];
        int[] a = Parts(latest), b = Parts(current);
        for (var i = 0; i < Math.Max(a.Length, b.Length); i++)
        {
            int x = i < a.Length ? a[i] : 0, y = i < b.Length ? b[i] : 0;
            if (x != y) return x > y;
        }
        return false;
    }

    static bool Trusted(Uri u) => u.Scheme == Uri.UriSchemeHttps || (u.Scheme == Uri.UriSchemeHttp && u.IsLoopback);

    public static async Task<Release?> CheckAsync(string updateUrl, HttpMessageHandler? handler = null)
    {
        if (!Uri.TryCreate(updateUrl, UriKind.Absolute, out var u) || !Trusted(u)) throw new SwitchException("更新地址必须是 https。");
        using var http = handler is null ? new HttpClient() : new HttpClient(handler, disposeHandler: false);
        http.Timeout = TimeSpan.FromSeconds(15);
        using var req = new HttpRequestMessage(HttpMethod.Get, u);
        req.Headers.CacheControl = new() { NoCache = true };
        try
        {
            using var resp = await http.SendAsync(req);
            if (!resp.IsSuccessStatusCode) throw new SwitchException($"官网返回了 HTTP {(int)resp.StatusCode}。");
            return Parse(await resp.Content.ReadAsStringAsync());
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException) { throw new SwitchException("连不上官网：" + e.Message); }
    }

    /// <summary>下载新版本到 destination 并校验；任何一步不对都抛 SwitchException 并删掉下载的文件。</summary>
    public static async Task DownloadAsync(Release release, string updateUrl, string destination, HttpMessageHandler? handler = null)
    {
        if (release.Sha256.Length != 64) throw new SwitchException("官网的版本信息里没有校验值（sha256），不自动更新。");
        if (!Uri.TryCreate(release.Url, UriKind.Absolute, out var u) || !Trusted(u)) throw new SwitchException("下载地址必须是 https。");
        if (!string.Equals(u.Host, new Uri(updateUrl).Host, StringComparison.OrdinalIgnoreCase)) throw new SwitchException($"下载地址（{u.Host}）和更新地址不是同一个网站，不自动更新。");
        using var http = handler is null ? new HttpClient() : new HttpClient(handler, disposeHandler: false);
        http.Timeout = TimeSpan.FromMinutes(10);
        try
        {
            using (var resp = await http.GetAsync(u, HttpCompletionOption.ResponseHeadersRead))
            {
                if (!resp.IsSuccessStatusCode) throw new SwitchException($"下载失败（HTTP {(int)resp.StatusCode}）。");
                Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
                await using var file = new FileStream(destination, FileMode.Create, FileAccess.Write, FileShare.None);
                await resp.Content.CopyToAsync(file);
            }
            string hash;
            await using (var file = File.OpenRead(destination))
            {
                var head = new byte[2];
                if (file.Length < 1_000_000 || await file.ReadAsync(head) != 2 || head[0] != (byte)'M' || head[1] != (byte)'Z') throw new SwitchException("下载到的不是一个 Windows 程序。");
                file.Position = 0;
                hash = Convert.ToHexStringLower(await SHA256.HashDataAsync(file));
            }
            if (hash != release.Sha256) throw new SwitchException("下载的文件校验不通过（sha256 对不上），可能没下完整。");
        }
        catch (Exception e)
        {
            try { File.Delete(destination); } catch (IOException) { }
            if (e is SwitchException) throw;
            if (e is HttpRequestException or TaskCanceledException or IOException) throw new SwitchException("下载失败：" + e.Message);
            throw;
        }
    }
}
