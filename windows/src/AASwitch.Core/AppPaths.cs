namespace AASwitch.Core;

/// <summary>各家工具的数据目录。测试时传一个临时目录当 home；正式运行用 FromEnvironment()。</summary>
public sealed class AppPaths
{
    public string Home { get; }
    public string ClaudeHome { get; }
    public string CodexHome { get; }

    public AppPaths(string home, string? claudeHome = null, string? codexHome = null)
    {
        Home = home;
        ClaudeHome = claudeHome ?? Path.Combine(home, ".claude");
        CodexHome = codexHome ?? Path.Combine(home, ".codex");
    }

    public static AppPaths FromEnvironment()
    {
        static string? Env(string name) { var v = Environment.GetEnvironmentVariable(name); return string.IsNullOrWhiteSpace(v) ? null : v; }
        return new AppPaths(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), Env("CLAUDE_CONFIG_DIR"), Env("CODEX_HOME"));
    }

    public string ClaudeSettings => Path.Combine(ClaudeHome, "settings.json");
    public string ClaudeConf => Path.Combine(ClaudeHome, "claude-mode.conf");
    public string ClaudeBackups => Path.Combine(ClaudeHome, "claude-mode-backups");
    public string ClaudeGlobalState => Path.Combine(Home, ".claude.json");
    public string ClaudeCredentialsFile => Path.Combine(ClaudeHome, ".credentials.json");
    public string CodexConf => Path.Combine(CodexHome, "codex-mode.conf");
}
