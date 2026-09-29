using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace AASwitch.Core;

/// <summary>
/// 桌面应用两种模式的会话互相同步，对应 macOS 版的 desktop_sync_sessions / desktop_sync_cowork。
/// Code 标签：&lt;数据目录&gt;\claude-code-sessions\&lt;账号&gt;\&lt;组织&gt;\local_&lt;id&gt;.json 只是列表项，对话记录在 ~/.claude/projects 里两边共用，
///   所以只补缺的、不覆盖，目标标记了 deleted_&lt;id&gt; 的不补。
/// Cowork 标签：&lt;数据目录&gt;\local-agent-mode-sessions\&lt;账号&gt;\&lt;组织&gt;\ 下每个会话一个 local_&lt;id&gt;.json 加一个同名目录，记录不共享，
///   整份复制并把里面指向原位置的绝对路径（以及按路径命名的 .claude\projects 目录）改成新位置；audit.jsonl 带签名，原样保留。
///   两份复制后各自往下走，所以用 ~/.claude/claude-mode-cowork-sync 记下每个会话上次同步时的 lastActivityAt：
///   只有一边比它新就用那边覆盖另一边（旧的挪进备份），两边都新了算冲突、不动；记录里有但某一边没了，当作在那边删掉了，不再补回去。
/// 应该在桌面应用退出后调用：开着的时候会话文件可能正写到一半。
/// </summary>
public sealed partial class DesktopSessions(ClaudeDesktopPaths dp, AppPaths paths, Action<string> say)
{
    string Ledger => Path.Combine(paths.ClaudeHome, "claude-mode-cowork-sync");

    (string Account, string Org) OAuthIds()
    {
        try
        {
            var o = JsonFile.ReadObject(paths.ClaudeGlobalState)["oauthAccount"];
            return (JsonFile.String(o?["accountUuid"]) ?? "", JsonFile.String(o?["organizationUuid"]) ?? "");
        }
        catch (SwitchException) { return ("", ""); }
    }

    // ---------- Code 标签的会话列表 ----------
    /// <summary>该模式的 Code 会话记录目录；指定的账号 / 组织目录不在就取第一个账号下会话最多的组织。找不到返回 null。</summary>
    public static string? CodeDir(string dataDir, string account = "", string org = "")
    {
        var root = Path.Combine(dataDir, "claude-code-sessions");
        if (!Directory.Exists(root)) return null;
        if (account.Length == 0 || !Directory.Exists(Path.Combine(root, account)))
            account = Directory.GetDirectories(root).Select(Path.GetFileName).Where(n => Uuid().IsMatch(n!))
                .OrderBy(n => n, StringComparer.Ordinal).FirstOrDefault() ?? "";
        if (account.Length == 0) return null;
        var acct = Path.Combine(root, account);
        if (org.Length > 0 && Directory.Exists(Path.Combine(acct, org))) return Path.Combine(acct, org);
        return MostSessions(Directory.GetDirectories(acct));
    }

    public void SyncCode()
    {
        var (account, org) = OAuthIds();
        var a = CodeDir(dp.AccountDir, account, org);
        var b = CodeDir(dp.GatewayDir);
        if (a is null || b is null)
        {
            say("会话列表暂时没法同步（" + (b is null ? "网关模式还没初始化过数据目录，第一次进入网关模式后再切一次即可" : "账号模式的会话目录没找到") + "）。");
            return;
        }
        var n = 0;
        foreach (var (src, dst) in new[] { (a, b), (b, a) })
            foreach (var f in Directory.GetFiles(src, "local_*.json"))
            {
                var name = Path.GetFileName(f);
                var id = name["local_".Length..^".json".Length];
                if (File.Exists(Path.Combine(dst, name)) || Path.Exists(Path.Combine(dst, "deleted_" + id))) continue;
                try { CopyFile(f, Path.Combine(dst, name)); n++; }
                catch (IOException) { } catch (UnauthorizedAccessException) { }
            }
        try { SyncTrusted(); } catch (SwitchException) { } catch (IOException) { }
        say($"会话列表已同步（补齐 {n} 条）。");
    }

    /// <summary>Cowork 信任过的文件夹（preferences.localAgentModeTrustedFolders）两边取并集，免得切过去又要重新授权。</summary>
    internal int SyncTrusted()
    {
        var files = new[] { Path.Combine(dp.AccountDir, "claude_desktop_config.json"), Path.Combine(dp.GatewayDir, "claude_desktop_config.json") };
        var objs = files.Select(JsonFile.ReadObject).ToArray();
        var all = new List<string>();
        foreach (var o in objs)
            if (o["preferences"]?["localAgentModeTrustedFolders"] is JsonArray arr)
                foreach (var d in arr) if (JsonFile.String(d) is { } s && !all.Contains(s)) all.Add(s);
        var changed = 0;
        for (var i = 0; i < objs.Length; i++)
        {
            var cur = objs[i]["preferences"]?["localAgentModeTrustedFolders"] as JsonArray;
            if ((cur?.Count ?? 0) == all.Count) continue;
            if (objs[i]["preferences"] is not JsonObject prefs) objs[i]["preferences"] = prefs = [];
            prefs["localAgentModeTrustedFolders"] = new JsonArray([.. all.Select(s => (JsonNode)s)]);
            JsonFile.Write(files[i], objs[i]);
            changed++;
        }
        return changed;
    }

    // ---------- Cowork ----------
    /// <summary>该模式的 Cowork 会话目录：指定的账号 / 组织目录在就用它，否则取会话最多的那个（网关模式是 &lt;账号前 8 位&gt;\&lt;组织前 8 位&gt;）。</summary>
    public static string? CoworkDir(string dataDir, string account = "", string org = "")
    {
        var root = Path.Combine(dataDir, "local-agent-mode-sessions");
        if (!Directory.Exists(root)) return null;
        if (account.Length > 0 && org.Length > 0 && Directory.Exists(Path.Combine(root, account, org))) return Path.Combine(root, account, org);
        return MostSessions(Directory.GetDirectories(root)
            .Where(d => Path.GetFileName(d) != "skills-plugin")
            .SelectMany(Directory.GetDirectories));
    }

    public sealed record PlanItem(string Action, string Name, long New, long? Old);

    /// <summary>名字 → lastActivityAt。</summary>
    public static Dictionary<string, long> CoworkSessions(string dir)
    {
        var out_ = new Dictionary<string, long>(StringComparer.Ordinal);
        foreach (var f in Directory.GetFiles(dir, "local_*.json"))
        {
            var m = SessionFile().Match(Path.GetFileName(f));
            if (!m.Success) continue;
            long last = 0;
            try
            {
                var node = JsonNode.Parse(File.ReadAllText(f, Encoding.UTF8))?["lastActivityAt"];
                if (node is JsonValue v) last = v.TryGetValue<long>(out var l) ? l : v.TryGetValue<double>(out var d) ? (long)d : 0;
            }
            catch (Exception e) when (e is JsonException or IOException or InvalidOperationException or FormatException) { }
            out_[m.Groups[1].Value] = last;
        }
        return out_;
    }

    public static Dictionary<string, long> ReadLedger(string file)
    {
        var led = new Dictionary<string, long>(StringComparer.Ordinal);
        if (!File.Exists(file)) return led;
        foreach (var line in File.ReadAllLines(file))
        {
            var parts = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length == 0) continue;
            led[parts[0]] = parts.Length > 1 && long.TryParse(parts[1], out var v) ? v : 0;
        }
        return led;
    }

    /// <summary>动作：a2b / b2a 复制，keep 两边一样，conflict 两边都改过，gone 同步过但某一边删掉了。</summary>
    public static List<PlanItem> Plan(Dictionary<string, long> a, Dictionary<string, long> b, Dictionary<string, long> led)
    {
        var plan = new List<PlanItem>();
        foreach (var n in a.Keys.Concat(b.Keys).Concat(led.Keys).Distinct().OrderBy(n => n, StringComparer.Ordinal))
        {
            bool inA = a.TryGetValue(n, out var va), inB = b.TryGetValue(n, out var vb), has = led.TryGetValue(n, out var l);
            long? old = has ? l : null;
            if (!inA && !inB) continue;                                   // 两边都没了，记录也不要了
            if (inA != inB)
            {
                if (has) plan.Add(new("gone", n, l, old));                // 同步过、某一边删掉了：不补回去
                else plan.Add(new(inA ? "a2b" : "b2a", n, inA ? va : vb, null));
                continue;
            }
            if (va == vb) { plan.Add(new("keep", n, va, old)); continue; }
            bool newA = !has || va > l, newB = !has || vb > l;
            if (has && newA && newB) plan.Add(new("conflict", n, l, old));
            else if (has ? newA : va > vb) plan.Add(new("a2b", n, va, old));
            else plan.Add(new("b2a", n, vb, old));
        }
        return plan;
    }

    /// <summary>两个模式的 Cowork 会话互相同步。bk 是这次操作的备份目录，被覆盖的旧会话挪到 bk\cowork\&lt;组织目录名&gt;\ 下。</summary>
    public void SyncCowork(string bk)
    {
        if (!Directory.Exists(Path.Combine(dp.AccountDir, "local-agent-mode-sessions")) &&
            !Directory.Exists(Path.Combine(dp.GatewayDir, "local-agent-mode-sessions"))) return;   // 没用过 Cowork
        var (account, org) = OAuthIds();
        var a = CoworkDir(dp.AccountDir, account, org);
        var b = CoworkDir(dp.GatewayDir);
        if (a is null || b is null)
        {
            say("Cowork 会话暂时没法同步（" + (b is null ? "网关模式还没初始化过 Cowork，在网关模式下打开一次 Cowork 标签后再切一次即可" : "账号模式的 Cowork 目录没找到") + "）。");
            return;
        }
        List<PlanItem> plan;
        try { plan = Plan(CoworkSessions(a), CoworkSessions(b), ReadLedger(Ledger)); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { say("读取 Cowork 会话列表失败，这次没有同步。"); return; }

        int n = 0, c = 0, f = 0;
        var led = new StringBuilder();
        foreach (var p in plan)
        {
            switch (p.Action)
            {
                case "a2b" or "b2a":
                    var ok = p.Action == "a2b" ? Copy(a, b, p.Name, bk) : Copy(b, a, p.Name, bk);
                    if (ok) { n++; led.Append($"{p.Name} {p.New}\n"); }
                    else { f++; if (p.Old is { } o) led.Append($"{p.Name} {o}\n"); }
                    break;
                case "conflict": c++; led.Append($"{p.Name} {p.Old}\n"); break;
                default: led.Append($"{p.Name} {p.New}\n"); break;
            }
        }
        AtomicFile.WriteAllText(Ledger, led.ToString());
        say($"Cowork 会话已同步（更新 {n} 条）。");
        if (c > 0) say($"有 {c} 条 Cowork 会话在两种模式下都继续聊过，没法合并，两边各自保留。");
        if (f > 0) say($"有 {f} 条 Cowork 会话复制失败，下次切换时再试。");
    }

    /// <summary>复制到目标的临时名下改好路径再换进去，目标原有的一份挪进备份。失败返回 false，目标不动。</summary>
    internal bool Copy(string src, string dst, string name, string bk)
    {
        var tmp = Path.Combine(dst, ".aa-switch-" + name);
        var tmpJson = tmp + ".json";
        try
        {
            Remove(tmp); Remove(tmpJson);
            if (Directory.Exists(Path.Combine(src, name))) CopyDir(Path.Combine(src, name), tmp);
            Rewrite(src, dst, tmp, Path.Combine(src, name + ".json"), tmpJson);
            var dstDir = Path.Combine(dst, name);
            var dstJson = Path.Combine(dst, name + ".json");
            if (Path.Exists(dstDir) || File.Exists(dstJson))
            {
                var keep = Path.Combine(bk, "cowork", Path.GetFileName(dst));
                Directory.CreateDirectory(keep);
                if (Directory.Exists(dstDir)) MoveDir(dstDir, Path.Combine(keep, name));
                if (File.Exists(dstJson)) File.Move(dstJson, Path.Combine(keep, name + ".json"), overwrite: true);
            }
            if (Directory.Exists(tmp)) Directory.Move(tmp, dstDir);
            File.Move(tmpJson, dstJson);
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or SwitchException)
        {
            try { Remove(tmp); Remove(tmpJson); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            return false;
        }
    }

    /// <summary>把 tmp（src 里那份会话的副本）里指向 src 的绝对路径改成 dst，会话信息改好后写到 dstJson。
    /// 记录里的旧位置以会话自己的 cwd（&lt;目录&gt;\&lt;local_id&gt;\outputs）为准，它不一定是现在所在的目录；
    /// 新位置同理用目标里已有会话的 cwd 推出应用自己眼里的路径（应用商店版有重定向），没有就按重定向规则换算。</summary>
    internal void Rewrite(string src, string dst, string tmp, string srcJson, string dstJson)
    {
        var meta = File.ReadAllText(srcJson, Encoding.UTF8);
        var name = Path.GetFileNameWithoutExtension(srcJson);
        var from = RootFromCwd(meta, name) ?? dp.AppView(src);
        var to = DstRoot(dst) ?? dp.AppView(dst);
        var pairs = Pairs(from, to);
        string Fix(string t) => pairs.Aggregate(t, (t, p) => t.Replace(p.From, p.To, StringComparison.Ordinal));

        var cl = Path.Combine(tmp, ".claude");
        if (Directory.Exists(cl))
        {
            var projects = Path.Combine(cl, "projects");
            if (Directory.Exists(projects))
                foreach (var d in Directory.GetDirectories(projects))
                {
                    var fixedName = Fix(Path.GetFileName(d));
                    if (fixedName != Path.GetFileName(d) && !Path.Exists(Path.Combine(projects, fixedName)))
                        Directory.Move(d, Path.Combine(projects, fixedName));
                }
            foreach (var f in Directory.EnumerateFiles(cl, "*", SearchOption.AllDirectories))
            {
                if (!RewriteName().IsMatch(Path.GetFileName(f))) continue;
                var t = File.ReadAllText(f, Encoding.UTF8);
                var ft = Fix(t);
                if (ft != t) WriteLike(f, ft, f);
            }
        }
        var newMeta = Fix(meta);
        JsonNode.Parse(newMeta);   // 会话信息必须还是合法 JSON，否则整个会话不复制
        WriteLike(dstJson, newMeta, srcJson);
    }

    /// <summary>会话 cwd 里 \local_id\ 之前的部分；cwd 没有或不含会话名返回 null。</summary>
    public static string? RootFromCwd(string metaJson, string name)
    {
        try
        {
            var cwd = JsonFile.String(JsonNode.Parse(metaJson)?["cwd"]) ?? "";
            foreach (var sep in new[] { '\\', '/' })
            {
                var i = cwd.IndexOf(sep + name + sep, StringComparison.Ordinal);
                if (i < 0 && cwd.EndsWith(sep + name, StringComparison.Ordinal)) i = cwd.Length - name.Length - 1;
                if (i > 0) return cwd[..i];
            }
        }
        catch (JsonException) { }
        return null;
    }

    /// <summary>目标目录在应用眼里的路径：从目标里已有会话的 cwd 推。</summary>
    string? DstRoot(string dst)
    {
        foreach (var f in Directory.GetFiles(dst, "local_*.json").OrderByDescending(File.GetLastWriteTimeUtc))
        {
            try { if (RootFromCwd(File.ReadAllText(f, Encoding.UTF8), Path.GetFileNameWithoutExtension(f)) is { } r) return r; }
            catch (IOException) { }
        }
        return null;
    }

    /// <summary>要替换的几种写法：JSON 里转义过的反斜杠、原样、正斜杠，以及 Claude Code 给 .claude\projects 下目录起名的规则（非字母数字换成 -）。
    /// 长的先换，免得短的把长的换掉一半。</summary>
    internal static List<(string From, string To)> Pairs(string from, string to)
    {
        var pairs = new List<(string, string)>
        {
            (from.Replace("\\", "\\\\"), to.Replace("\\", "\\\\")),
            (from, to),
            (from.Replace('\\', '/'), to.Replace('\\', '/')),
            (Sanitize(from), Sanitize(to)),
        };
        return [.. pairs.Where(p => p.Item1.Length > 0 && p.Item1 != p.Item2).Distinct()];
    }

    public static string Sanitize(string p) => NonAlnum().Replace(p, "-");

    // ---------- 文件工具 ----------
    static string? MostSessions(IEnumerable<string> dirs)
    {
        string? best = null; var bestN = -1;
        foreach (var d in dirs.OrderBy(d => d, StringComparer.Ordinal))
        {
            var n = Directory.GetFiles(d, "local_*.json").Length;
            if (n > bestN) { best = d; bestN = n; }
        }
        return best;
    }

    /// <summary>写入 text，修改时间照 like（应用可能按修改时间排序）。</summary>
    static void WriteLike(string file, string text, string like)
    {
        var t = File.Exists(like) ? File.GetLastWriteTimeUtc(like) : (DateTime?)null;
        AtomicFile.WriteAllText(file, text);
        if (t is { } time) File.SetLastWriteTimeUtc(file, time);
    }

    static void CopyFile(string src, string dst)
    {
        File.Copy(src, dst, overwrite: false);
        File.SetLastWriteTimeUtc(dst, File.GetLastWriteTimeUtc(src));
    }

    /// <summary>整个目录复制过去，保留文件修改时间。</summary>
    internal static void CopyDir(string src, string dst)
    {
        Directory.CreateDirectory(dst);
        foreach (var f in Directory.GetFiles(src)) File.Copy(f, Path.Combine(dst, Path.GetFileName(f)), overwrite: true);
        foreach (var f in Directory.GetFiles(src)) File.SetLastWriteTimeUtc(Path.Combine(dst, Path.GetFileName(f)), File.GetLastWriteTimeUtc(f));
        foreach (var d in Directory.GetDirectories(src)) CopyDir(d, Path.Combine(dst, Path.GetFileName(d)));
    }

    /// <summary>挪目录；跨盘（备份在别的盘上）时退回复制再删除。</summary>
    static void MoveDir(string src, string dst)
    {
        Remove(dst);
        try { Directory.Move(src, dst); }
        catch (IOException) { CopyDir(src, dst); Directory.Delete(src, recursive: true); }
    }

    static void Remove(string path)
    {
        if (Directory.Exists(path)) Directory.Delete(path, recursive: true);
        else if (File.Exists(path)) File.Delete(path);
    }

    [GeneratedRegex("^[0-9a-f-]{36}$")] private static partial Regex Uuid();
    [GeneratedRegex(@"^(local_[0-9A-Za-z-]+)\.json$")] private static partial Regex SessionFile();
    [GeneratedRegex(@"\.jsonl?$|\.json\.backup")] private static partial Regex RewriteName();
    [GeneratedRegex("[^A-Za-z0-9]")] private static partial Regex NonAlnum();
}
