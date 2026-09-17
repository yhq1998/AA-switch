// aaswitch — AA Switch Windows 版的命令行入口，逻辑都在 AASwitch.Core，托盘程序调用的是同一套代码。
//   aaswitch claude api|account          Claude Code 切到自定义 API / 切回 Claude 账号
//   aaswitch codex api|chatgpt           Codex 切到自定义 API / 切回 ChatGPT 账号（先关掉 Codex 应用、codex 命令行和 IDE 会话）
//   aaswitch codex fix-threads           只做「统一会话 provider」这一步，不改模式
//   以下两边通用（把 <工具> 换成 claude 或 codex）：
//   aaswitch <工具> status               查看当前模式（不显示 key）
//   aaswitch <工具> configure            设置 API 地址、额外请求头和 key
//   aaswitch <工具> set-key              只更换 key（存入 Windows 凭据管理器，两边共用同一个条目 codex-mode:域名）
//   aaswitch <工具> forget-key           从凭据管理器删除保存的 key
//   aaswitch <工具> mode                 只输出一个词：claude 为 api / account / absent，codex 为 api / chatgpt / none
//   aaswitch <工具> config               输出已保存的地址和请求头（不含 key）
//   aaswitch <工具> has-key URL          凭据管理器里有没有该地址的 key（退出码 0 表示有）
//   aaswitch version
// 环境变量：CLAUDE_CONFIG_DIR、CODEX_HOME（数据目录）、CODEX_BIN（codex 命令行路径）、CODEX_MODE_FORCE=1（不检查 Codex 进程，仅测试用）。
using System.Text;
using AASwitch.Core;

Console.OutputEncoding = Encoding.UTF8;
Console.InputEncoding = Encoding.UTF8;

void Say(string s) => Console.Error.WriteLine(s);

string Ask(string prompt, string fallback)
{
    Console.Error.Write(fallback.Length > 0 ? $"{prompt} [{fallback}]: " : $"{prompt}: ");
    var ans = Console.ReadLine() ?? throw new SwitchException("输入已取消。");
    return ans.Length > 0 ? ans : fallback;
}

string AskSecret(string prompt)
{
    Console.Error.Write($"{prompt}（输入不回显）: ");
    if (Console.IsInputRedirected) return Console.ReadLine() ?? "";
    var sb = new StringBuilder();
    while (true)
    {
        var k = Console.ReadKey(intercept: true);
        if (k.Key == ConsoleKey.Enter) break;
        if (k.Key == ConsoleKey.Backspace) { if (sb.Length > 0) sb.Length--; }
        else if (!char.IsControl(k.KeyChar)) sb.Append(k.KeyChar);
    }
    Console.Error.WriteLine();
    return sb.ToString();
}

int Usage()
{
    Say("用法：aaswitch claude api|account|status|configure|set-key|forget-key|mode|config|has-key URL");
    Say("      aaswitch codex  api|chatgpt|fix-threads|status|configure|set-key|forget-key|mode|config|has-key URL");
    Say("      aaswitch version");
    return 1;
}

try
{
    if (args.Length == 1 && args[0] == "version") { Console.WriteLine(ClaudeMode.Version); return 0; }
    if (args.Length < 2 || args[0] is not ("claude" or "codex")) return Usage();

    ISecretStore secrets;
    if (OperatingSystem.IsWindows()) secrets = new WindowsCredentialStore();
    else { secrets = new MemorySecretStore(); Say("（非 Windows 系统：key 只存在内存里，仅供开发调试）"); }
    var paths = AppPaths.FromEnvironment();

    // 两个工具的命令大同小异，差别收在这几个委托里
    Func<(string Url, string Headers)> loadConfig;
    Func<string, string, string> configure;   // (地址, 请求头) → 规范化后的地址
    Func<string, bool> hasKey;
    Action<string> setKey;
    Action forgetKey;
    Func<string> modeWord;
    Func<List<string>> status;
    string urlHint;

    ClaudeMode? claude = null;
    CodexMode? codex = null;
    if (args[0] == "claude")
    {
        claude = new ClaudeMode(paths, secrets, Say);
        loadConfig = () => { var c = claude.LoadConfig(); return (c.BaseUrl, c.Headers); };
        configure = (u, h) => claude.Configure(u, h, null);
        hasKey = claude.HasKey; setKey = claude.SetKey; forgetKey = claude.ForgetKey; modeWord = claude.ModeWord; status = claude.Status;
        urlHint = "请输入 API 地址（网关根地址，不带 /v1，例如 https://api.example.com）";
    }
    else
    {
        var bin = CodexCli.Find();
        var force = Environment.GetEnvironmentVariable("CODEX_MODE_FORCE") == "1";
        codex = new CodexMode(paths, secrets, bin is null ? null : new CodexCli(bin, paths.CodexHome), Say, force ? null : CodexProcesses.Running);
        loadConfig = () => { var c = codex.LoadConfig(); return (c.BaseUrl, c.HeaderPairs); };
        configure = (u, h) => codex.Configure(u, h, null);
        hasKey = codex.HasKey; setKey = codex.SetKey; forgetKey = codex.ForgetKey; modeWord = codex.ModeWord; status = codex.Status;
        urlHint = "请输入 API Base URL（服务商给的完整地址，例如 https://api.example.com/v1）";
    }

    void Configure()
    {
        var (curUrl, curHeaders) = loadConfig();
        var url = Ask(urlHint, curUrl);
        var hdr = Ask("额外请求头（格式 名称=值，多个用英文逗号分隔；通常留空，输入 - 表示清空）", curHeaders);
        if (hdr == "-") hdr = "";
        url = configure(url, hdr);
        var key = AskSecret(hasKey(url) ? "API key（凭据管理器里已有一个，回车沿用）" : "API key（回车跳过，切 API 模式时再输）");
        if (key.Length > 0) setKey(key);
    }

    switch (args[1])
    {
        case "api":
            if (loadConfig().Url.Length == 0) { Say("还没有配置 API 地址，先配置一次："); Configure(); }
            var url = loadConfig().Url;
            if (!(codex is not null ? codex.DiscoverKey(url).Length > 0 : hasKey(url)))
            {
                var key = AskSecret($"请输入 {Gateway.UrlHost(url)} 的 API key");
                if (key.Length == 0) throw new SwitchException("未输入 key，已取消。");
                setKey(key);
            }
            if (claude is not null) await claude.SwitchToApiAsync(); else await codex!.SwitchToApiAsync();
            return 0;
        case "account" when claude is not null: claude.SwitchToAccount(); return 0;
        case "chatgpt" when codex is not null: codex.SwitchToChatGpt(); return 0;
        case "fix-threads" when codex is not null: codex.FixThreads(); return 0;
        case "status": foreach (var line in status()) Console.WriteLine(line); return 0;
        case "configure": Configure(); return 0;
        case "set-key":
            if (loadConfig().Url.Length == 0) throw new SwitchException($"请先运行 aaswitch {args[0]} configure。");
            setKey(AskSecret($"请输入 {Gateway.UrlHost(loadConfig().Url)} 的 API key")); return 0;
        case "forget-key": forgetKey(); return 0;
        case "mode": Console.WriteLine(modeWord()); return 0;
        case "config":
            var (u, h) = loadConfig();
            Console.WriteLine($"base_url={u}"); Console.WriteLine($"headers={h}");
            return 0;
        case "has-key":
            if (args.Length != 3 || !Gateway.ValidUrl(args[2])) throw new SwitchException($"用法：aaswitch {args[0]} has-key URL");
            return hasKey(args[2]) ? 0 : 1;
        default: return Usage();
    }
}
catch (SwitchException e)
{
    Say("错误：" + e.Message);
    return 1;
}
