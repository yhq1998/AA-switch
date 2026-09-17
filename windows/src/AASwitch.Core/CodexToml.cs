using System.Text;
using System.Text.RegularExpressions;

namespace AASwitch.Core;

/// <summary>
/// 按行读写 Codex 的 config.toml，与 macOS 版 codex-mode 脚本里的 awk 逻辑一一对应：只认 model_provider 这一行和
/// [model_providers.X] 段，其余内容（包括注释、别的段）原样保留。不用 TOML 库，是因为要保住用户文件里的注释和排版。
/// </summary>
public sealed partial class CodexToml
{
    readonly List<string> _lines;

    public CodexToml(string text) => _lines = text.Length == 0 ? [] : [.. text.Replace("\r\n", "\n").TrimEnd('\n').Split('\n')];

    public static CodexToml Load(string path) => new(File.Exists(path) ? File.ReadAllText(path, Encoding.UTF8) : "");

    public sealed record Provider(string Name, string BaseUrl, string EnvKey);

    /// <summary>段头 → 该段的 provider 名；不是段头返回 null，不是 model_providers 段返回 ""。</summary>
    static string? HeaderProvider(string line)
    {
        if (!HeaderStart().IsMatch(line)) return null;
        var h = HeaderTail().Replace(HeaderStart().Replace(line, "", 1), "", 1);
        if (!h.StartsWith("model_providers.", StringComparison.Ordinal)) return "";
        var name = h["model_providers.".Length..];
        if (name.StartsWith('"')) name = name[1..];
        if (name.EndsWith('"')) name = name[..^1];
        return name;
    }

    static string FirstQuoted(string line)
    {
        var a = line.IndexOf('"');
        if (a < 0) return line;
        var rest = line[(a + 1)..];
        var b = rest.IndexOf('"');
        return b < 0 ? rest : rest[..b];
    }

    /// <summary>文件开头（第一个段之前）的 model_provider 值。</summary>
    public string PreambleProvider()
    {
        foreach (var line in _lines)
        {
            if (HeaderStart().IsMatch(line)) break;
            if (ModelProviderLine().IsMatch(line)) return FirstQuoted(line);
        }
        return "";
    }

    /// <summary>取 [model_providers.X] 里某键的值；activeOnly 为假时连注释掉的行也算（账号模式下地址是注释掉的）。</summary>
    public string SectionValue(string provider, string key, bool activeOnly = false)
    {
        if (provider.Length == 0) return "";
        var re = new Regex(@"^\s*" + (activeOnly ? "" : "#?") + @"\s*" + Regex.Escape(key) + @"\s*=\s*");
        var inSection = false;
        foreach (var line in _lines)
        {
            var p = HeaderProvider(line);
            if (p is not null) { inSection = p == provider; continue; }
            if (!inSection) continue;
            var m = re.Match(line);
            if (!m.Success) continue;
            var v = line[m.Length..];
            if (key == "base_url")
            {
                if (v.StartsWith('"')) v = v[1..];
                var q = v.IndexOf('"');
                return q < 0 ? v : v[..q];
            }
            var brace = v.LastIndexOf('}');
            return brace < 0 ? v : v[..(brace + 1)];
        }
        return "";
    }

    /// <summary>所有 provider 段：名字、生效中的 base_url、env_key（没有则为空）。</summary>
    public List<Provider> Inventory()
    {
        var order = new List<string>();
        var url = new Dictionary<string, string>();
        var env = new Dictionary<string, string>();
        var cur = "";
        foreach (var line in _lines)
        {
            var p = HeaderProvider(line);
            if (p is not null)
            {
                cur = p;
                if (cur.Length > 0 && !url.ContainsKey(cur)) { order.Add(cur); url[cur] = ""; env[cur] = ""; }
                continue;
            }
            if (cur.Length == 0) continue;
            if (ActiveBaseUrl().IsMatch(line)) url[cur] = FirstQuoted(line);
            else if (ActiveEnvKey().IsMatch(line)) env[cur] = FirstQuoted(line);
        }
        return [.. order.Select(n => new Provider(n, url[n], env[n]))];
    }

    /// <summary>
    /// 生成新配置：第一行固定 model_provider，原文件里 managed 的 provider 段和开头的 model_provider 行去掉，其余原样，
    /// 末尾追加 managed 的 provider 块（api 模式写地址，chatgpt 模式把地址注释掉）。
    /// </summary>
    public string Rewrite(string provider, IReadOnlyCollection<string> managed, bool apiMode, string baseUrl, string headersToml)
    {
        var output = new List<string> { $"model_provider = \"{provider}\"   # 两种模式都保持这一行；切换只改下面 provider 块里的 base_url / http_headers" };
        bool inSection = false, skip = false;
        foreach (var line in _lines)
        {
            var p = HeaderProvider(line);
            if (p is not null) { inSection = true; skip = p.Length > 0 && managed.Contains(p); if (!skip) output.Add(line); continue; }
            if (skip) continue;
            if (!inSection && AnyModelProviderLine().IsMatch(line)) continue;
            output.Add(line);
        }
        foreach (var name in managed)
        {
            output.Add("");
            output.Add($"[model_providers.{(BareKey().IsMatch(name) ? name : $"\"{name}\"")}]");
            output.Add($"name = \"{name}\"");
            output.Add(apiMode ? $"base_url = \"{baseUrl}\"" : $"# base_url = \"{baseUrl}\"   # 账号模式不写地址，走 OpenAI 官方后端");
            output.Add("wire_api = \"responses\"");
            output.Add("requires_openai_auth = true");
            output.Add("supports_websockets = false");
            if (headersToml.Length > 0)
                output.Add(apiMode ? $"http_headers = {headersToml}" : $"# http_headers = {headersToml}   # 仅 API 模式启用");
        }
        // 相当于 cat -s：连续的空行压成一行
        var squeezed = new List<string>();
        foreach (var line in output)
            if (line.Length > 0 || squeezed.Count == 0 || squeezed[^1].Length > 0) squeezed.Add(line);
        return string.Join("\n", squeezed) + "\n";
    }

    // ---------- 请求头：conf 里存成 TOML 内联表 { "a" = "b" }，界面上用 a=b, c=d ----------
    public static string PairsToToml(string pairs)
    {
        if (pairs.Trim().Length == 0) return "";
        var items = new List<string>();
        foreach (var raw in pairs.Split(','))
        {
            var eq = raw.IndexOf('=');
            if (eq < 0) throw new SwitchException($"请求头格式应为 名称=值：{raw}");
            string k = raw[..eq].Trim(), v = raw[(eq + 1)..].Trim();
            if (k.Length == 0) throw new SwitchException($"请求头名称不能为空：{raw}");
            if ((k + v).IndexOfAny(['"', '\\']) >= 0) throw new SwitchException($"请求头不能包含引号或反斜杠：{raw}");
            if (k.ToLowerInvariant() is "authorization" or "host" or "content-length")
                throw new SwitchException($"请通过 API key 认证，不要手动设置 {k} 请求头。");
            items.Add($"\"{k}\" = \"{v}\"");
        }
        return "{ " + string.Join(", ", items) + " }";
    }

    public static string TomlToPairs(string toml)
    {
        var s = TomlOpen().Replace(toml, "");
        s = TomlClose().Replace(s, "");
        return TomlEquals().Replace(s, "=").Replace("\"", "");
    }

    [GeneratedRegex(@"^\s*\[\s*")] private static partial Regex HeaderStart();
    [GeneratedRegex(@"\s*\]\s*(#.*)?$")] private static partial Regex HeaderTail();
    [GeneratedRegex(@"^\s*model_provider\s*=")] private static partial Regex ModelProviderLine();
    [GeneratedRegex(@"^\s*#?\s*model_provider\s*=")] private static partial Regex AnyModelProviderLine();
    [GeneratedRegex(@"^\s*base_url\s*=")] private static partial Regex ActiveBaseUrl();
    [GeneratedRegex(@"^\s*env_key\s*=")] private static partial Regex ActiveEnvKey();
    [GeneratedRegex(@"^[A-Za-z0-9_-]+$")] private static partial Regex BareKey();
    [GeneratedRegex(@"^\{ *")] private static partial Regex TomlOpen();
    [GeneratedRegex(@" *\}$")] private static partial Regex TomlClose();
    [GeneratedRegex(@""" *= *""")] private static partial Regex TomlEquals();
}
