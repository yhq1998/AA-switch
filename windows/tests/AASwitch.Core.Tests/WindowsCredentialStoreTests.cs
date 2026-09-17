using AASwitch.Core;

namespace AASwitch.Core.Tests;

/// <summary>真的读写 Windows 凭据管理器，只在 Windows 上跑（GitHub Actions 的 windows-latest 会跑到）。</summary>
public sealed class WindowsCredentialStoreTests
{
    [Fact]
    public void Roundtrip()
    {
        if (!OperatingSystem.IsWindows()) return;
        var store = new WindowsCredentialStore();
        var name = "codex-mode:aaswitch-test-" + Guid.NewGuid().ToString("N");
        try
        {
            Assert.Null(store.Get(name));
            Assert.False(store.Delete(name));
            store.Set(name, "sk-第一个");
            Assert.Equal("sk-第一个", store.Get(name));
            store.Set(name, "sk-second");   // 覆盖
            Assert.Equal("sk-second", store.Get(name));
            Assert.True(store.Delete(name));
            Assert.Null(store.Get(name));
        }
        finally { try { store.Delete(name); } catch { } }
    }
}
