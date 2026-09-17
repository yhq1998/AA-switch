// aaswitch — AA Switch Windows 版的命令行入口，逻辑都在 AASwitch.Core，托盘程序调用的是同一套代码。
//   aaswitch claude api          Claude Code 切到自定义 API（缺地址或 key 时先问）
//   aaswitch claude account      切回 Claude 账号
//   aaswitch claude status       查看当前模式（不显示 key）
//   aaswitch claude configure    设置 API 地址、额外请求头和 key
//   aaswitch claude set-key      只更换 key（存入 Windows 凭据管理器）
//   aaswitch claude forget-key   从凭据管理器删除保存的 key
//   aaswitch claude mode         只输出 api / account / absent
//   aaswitch claude config       输出已保存的地址和请求头（不含 key）
//   aaswitch claude has-key URL  凭据管理器里有没有该地址的 key（退出码 0 表示有）
//   aaswitch version
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
    Say("      aaswitch version");
    return 1;
}

try
{
    if (args.Length == 1 && args[0] == "version") { Console.WriteLine(ClaudeMode.Version); return 0; }
    if (args.Length < 2 || args[0] != "claude") return Usage();

    ISecretStore secrets;
    if (OperatingSystem.IsWindows()) secrets = new WindowsCredentialStore();
    else { secrets = new MemorySecretStore(); Say("（非 Windows 系统：key 只存在内存里，仅供开发调试）"); }
    var claude = new ClaudeMode(AppPaths.FromEnvironment(), secrets, Say);

    void Configure()
    {
        var cfg = claude.LoadConfig();
        var url = Ask("请输入 API 地址（网关根地址，不带 /v1，例如 https://api.example.com）", cfg.BaseUrl);
        var hdr = Ask("额外请求头（格式 名称=值，多个用英文逗号分隔；通常留空，输入 - 表示清空）", cfg.Headers);
        if (hdr == "-") hdr = "";
        url = claude.Configure(url, hdr, null);
        var key = AskSecret(claude.HasKey(url) ? "API key（凭据管理器里已有一个，回车沿用）" : "API key（回车跳过，切 API 模式时再输）");
        if (key.Length > 0) claude.SetKey(key);
    }

    switch (args[1])
    {
        case "api":
            if (claude.LoadConfig().BaseUrl.Length == 0) { Say("还没有配置 API 地址，先配置一次："); Configure(); }
            var url = claude.LoadConfig().BaseUrl;
            if (!claude.HasKey(url))
            {
                var key = AskSecret($"请输入 {Gateway.UrlHost(url)} 的 API key");
                if (key.Length == 0) throw new SwitchException("未输入 key，已取消。");
                claude.SetKey(key);
            }
            await claude.SwitchToApiAsync();
            return 0;
        case "account": claude.SwitchToAccount(); return 0;
        case "status": foreach (var line in claude.Status()) Console.WriteLine(line); return 0;
        case "configure": Configure(); return 0;
        case "set-key":
            if (claude.LoadConfig().BaseUrl.Length == 0) throw new SwitchException("请先运行 aaswitch claude configure。");
            claude.SetKey(AskSecret($"请输入 {Gateway.UrlHost(claude.LoadConfig().BaseUrl)} 的 API key")); return 0;
        case "forget-key": claude.ForgetKey(); return 0;
        case "mode": Console.WriteLine(claude.ModeWord()); return 0;
        case "config":
            var c = claude.LoadConfig();
            Console.WriteLine($"base_url={c.BaseUrl}"); Console.WriteLine($"headers={c.Headers}");
            return 0;
        case "has-key":
            if (args.Length != 3 || !Gateway.ValidUrl(args[2])) throw new SwitchException("用法：aaswitch claude has-key URL");
            return claude.HasKey(args[2]) ? 0 : 1;
        default: return Usage();
    }
}
catch (SwitchException e)
{
    Say("错误：" + e.Message);
    return 1;
}
