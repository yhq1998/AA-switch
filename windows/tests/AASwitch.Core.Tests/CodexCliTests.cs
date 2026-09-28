using AASwitch.Core;

namespace AASwitch.Core.Tests;

/// <summary>找 codex 的顺序和“找过哪些位置”。改环境变量是进程级的，每个用例自己还原。
/// Windows 上还会另外读当前用户 / 本机那两份环境变量（注册表），那部分只能在 Windows 上验——
/// 所以断言“找过哪些位置”时只看这个用例自己的临时目录，runner 上注册表里的 PATH 会多出别的目录。</summary>
public sealed class CodexCliTests : IDisposable
{
    static readonly string[] Vars = ["PATH", "CODEX_BIN", "LOCALAPPDATA", "APPDATA", "USERPROFILE"];
    readonly string _dir = Directory.CreateTempSubdirectory("aaswitch-codexcli-").FullName;
    readonly Dictionary<string, string?> _old = Vars.ToDictionary(v => v, Environment.GetEnvironmentVariable);

    /// <summary>用户目录都指到临时目录里（先不建），免得这台机器上真装的 codex 掺进来。</summary>
    public CodexCliTests()
    {
        Environment.SetEnvironmentVariable("LOCALAPPDATA", Path.Combine(_dir, "local"));
        Environment.SetEnvironmentVariable("APPDATA", Path.Combine(_dir, "roaming"));
        Environment.SetEnvironmentVariable("USERPROFILE", Path.Combine(_dir, "home"));
    }

    public void Dispose()
    {
        foreach (var (k, v) in _old) Environment.SetEnvironmentVariable(k, v);
        Directory.Delete(_dir, recursive: true);
    }

    static string CodexName => OperatingSystem.IsWindows() ? "codex.cmd" : "codex";

    /// <summary>在 dir 下放一个假的 codex，返回它的路径。</summary>
    string MakeCodex(string sub, string name)
    {
        var dir = Path.Combine(_dir, sub);
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, name);
        File.WriteAllText(path, "");
        return path;
    }

    /// <summary>只让 PATH 里有这些目录，环境变量 CODEX_BIN 清掉。</summary>
    static void OnlyPath(params string[] dirs)
    {
        Environment.SetEnvironmentVariable("CODEX_BIN", null);
        Environment.SetEnvironmentVariable("PATH", string.Join(Path.PathSeparator, dirs));
    }

    [Fact]
    public void FindsCodexOnPath()
    {
        var codex = MakeCodex("bin", CodexName);
        OnlyPath(Path.Combine(_dir, "empty"), Path.Combine(_dir, "bin"));
        Assert.Equal(codex, CodexCli.Locate().Path);
    }

    [Fact]
    public void ConfiguredPathWins()
    {
        var onPath = MakeCodex("bin", CodexName);
        var picked = MakeCodex("elsewhere", CodexName);
        OnlyPath(Path.Combine(_dir, "bin"));
        Environment.SetEnvironmentVariable("CODEX_BIN", onPath);
        Assert.Equal(picked, CodexCli.Locate(picked).Path);
    }

    [Fact]
    public void EnvBeatsPath()
    {
        MakeCodex("bin", CodexName);
        var env = MakeCodex("elsewhere", CodexName);
        OnlyPath(Path.Combine(_dir, "bin"));
        Environment.SetEnvironmentVariable("CODEX_BIN", env);
        Assert.Equal(env, CodexCli.Locate().Path);
    }

    /// <summary>指定的位置文件没了不该卡死：接着按 PATH 找，并把这件事记进 Tried。</summary>
    [Fact]
    public void MissingConfiguredFallsBackAndIsReported()
    {
        var codex = MakeCodex("bin", CodexName);
        OnlyPath(Path.Combine(_dir, "bin"));
        var gone = Path.Combine(_dir, "gone", CodexName);

        var found = CodexCli.Locate(gone);
        Assert.Equal(codex, found.Path);
        Assert.Contains(found.Tried, t => t.Contains(gone) && t.Contains("不在了"));
    }

    [Fact]
    public void MissingEnvFallsBackAndIsReported()
    {
        var codex = MakeCodex("bin", CodexName);
        OnlyPath(Path.Combine(_dir, "bin"));
        var gone = Path.Combine(_dir, "gone", CodexName);
        Environment.SetEnvironmentVariable("CODEX_BIN", gone);

        var found = CodexCli.Locate();
        Assert.Equal(codex, found.Path);
        Assert.Contains(found.Tried, t => t.Contains("CODEX_BIN") && t.Contains(gone));
    }

    /// <summary>没找到时 Tried 要列出每个找过的目录，重复的只算一次——弹窗和诊断文件就靠它。</summary>
    [Fact]
    public void ReportsEveryDirectoryOnceWhenNotFound()
    {
        var a = Path.Combine(_dir, "a");
        var b = Path.Combine(_dir, "b");
        Directory.CreateDirectory(a); Directory.CreateDirectory(b);
        OnlyPath(a, b, a);

        var found = CodexCli.Locate();
        Assert.Null(found.Path);
        // 只看 a、b 这两条：注册表里的 PATH 常写成 %LOCALAPPDATA%\…，展开时用的是上面指到临时目录的那个，也会落在 _dir 下
        Assert.Equal([$"PATH 里的 {a}", $"PATH 里的 {b}"], found.Tried.Where(t => t == $"PATH 里的 {a}" || t == $"PATH 里的 {b}"));
        // 桌面应用和常见安装位置也要列出来，没找到时用户才知道还能怎么办
        Assert.Contains(found.Tried, t => t.Contains(Path.Combine(_dir, "local", "OpenAI", "Codex", "bin")) && t.Contains("先打开它一次"));
        Assert.Contains(found.Tried, t => t.Contains(Path.Combine(_dir, "roaming", "npm")));
    }

    /// <summary>PATH 里的引号和非法字符不能让整个查找炸掉，也不能挡住后面的目录。</summary>
    [Fact]
    public void SurvivesJunkOnPath()
    {
        var codex = MakeCodex("bin", CodexName);
        OnlyPath("\"C:\\bad<>|dir\"", Path.Combine(_dir, "bin"));
        Assert.Equal(codex, CodexCli.Locate().Path);
    }

    /// <summary>只装了 Codex 桌面应用：应用把 codex.exe 复制到 %LOCALAPPDATA%\OpenAI\Codex\bin\<运行时 ID>\，不在 PATH 里。
    /// 有几份取最新的；排在 PATH 前面，和应用用同一个版本。</summary>
    [Fact]
    public void FindsCodexDesktopAppCopyBeforePath()
    {
        var old = MakeCodex(Path.Combine("local", "OpenAI", "Codex", "bin", "rt-old"), "codex.exe");
        var fresh = MakeCodex(Path.Combine("local", "OpenAI", "Codex", "bin", "rt-new"), "codex.exe");
        File.SetLastWriteTimeUtc(old, DateTime.UtcNow.AddDays(-3));
        File.SetLastWriteTimeUtc(fresh, DateTime.UtcNow.AddMinutes(-1));
        MakeCodex("bin", CodexName);
        OnlyPath(Path.Combine(_dir, "bin"));
        Assert.Equal(fresh, CodexCli.Locate().Path);
    }

    [Fact]
    public void FindsCodexDesktopAppCopyDirectlyInBin()
    {
        var codex = MakeCodex(Path.Combine("local", "OpenAI", "Codex", "bin"), "codex.exe");
        OnlyPath(Path.Combine(_dir, "empty"));
        Assert.Equal(codex, CodexCli.Locate().Path);
    }

    /// <summary>npm 装了但 %APPDATA%\npm 没进 PATH（或者进了但程序启动时还没有）。</summary>
    [Fact]
    public void FindsNpmGlobalWhenNotOnPath()
    {
        var codex = MakeCodex(Path.Combine("roaming", "npm"), CodexName);
        OnlyPath(Path.Combine(_dir, "empty"));
        Assert.Equal(codex, CodexCli.Locate().Path);
    }

    [Fact]
    public void FindsWingetAndScoop()
    {
        var winget = MakeCodex(Path.Combine("local", "Microsoft", "WinGet", "Links"), CodexName);
        OnlyPath(Path.Combine(_dir, "empty"));
        Assert.Equal(winget, CodexCli.Locate().Path);
        File.Delete(winget);
        var scoop = MakeCodex(Path.Combine("home", "scoop", "shims"), CodexName);
        Assert.Equal(scoop, CodexCli.Locate().Path);
    }

    /// <summary>PATH 指进应用商店的安装目录（…\WindowsApps\OpenAI.Codex_…\app\resources）：那里的 codex.exe 运行会“拒绝访问”，要跳过。
    /// %LOCALAPPDATA%\Microsoft\WindowsApps（应用执行别名）不算。</summary>
    [Fact]
    public void SkipsStorePackageDirOnPath()
    {
        MakeCodex(Path.Combine("WindowsApps", "OpenAI.Codex_26.924.0.0_x64__2p2nqsd0c76g0", "app", "resources"), CodexName);
        var alias = MakeCodex(Path.Combine("local", "Microsoft", "WindowsApps"), CodexName);
        OnlyPath(Path.Combine(_dir, "WindowsApps", "OpenAI.Codex_26.924.0.0_x64__2p2nqsd0c76g0", "app", "resources"), Path.Combine(_dir, "local", "Microsoft", "WindowsApps"));

        var found = CodexCli.Locate();
        Assert.Equal(alias, found.Path);
        Assert.Contains(found.Tried, t => t.Contains("OpenAI.Codex_26.924") && t.Contains("应用商店"));
    }
}
