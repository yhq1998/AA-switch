using System.Net;
using System.Security.Cryptography;
using AASwitch.Core;

namespace AASwitch.Core.Tests;

public sealed class UpdaterTests : IDisposable
{
    readonly string _dir = Directory.CreateTempSubdirectory("aaswitch-upd-").FullName;
    public void Dispose() => Directory.Delete(_dir, recursive: true);

    sealed class Serve(Func<HttpRequestMessage, HttpResponseMessage> f) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage r, CancellationToken ct) => Task.FromResult(f(r));
    }

    static byte[] FakeExe(byte fill = 7) { var b = new byte[1_200_000]; Array.Fill(b, fill); b[0] = (byte)'M'; b[1] = (byte)'Z'; return b; }
    static string Sha(byte[] b) => Convert.ToHexStringLower(SHA256.HashData(b));
    const string UpdateUrl = "https://aaswitch.example.com/download/latest.json";

    [Theory]
    [InlineData("0.2.0", "0.1.9", true)]
    [InlineData("0.10.0", "0.9.1", true)]
    [InlineData("1.0", "1.0.0", false)]
    [InlineData("1.0.1", "1.0", true)]
    [InlineData("0.1.0", "0.1.0", false)]
    [InlineData("0.1.0", "0.2.0", false)]
    public void IsNewer(string latest, string current, bool newer) => Assert.Equal(newer, Updater.IsNewer(latest, current));

    [Fact]
    public void Parse_reads_windows_section_and_ignores_mac_fields()
    {
        var r = Updater.Parse("""{ "version": "2.3.0", "url": "https://x/AA%20Switch.dmg", "windows": { "version": "0.2.0", "date": "2026-09-17", "url": "https://x/AA%20Switch.exe", "sha256": "ABCD" } }""");
        Assert.Equal(new Updater.Release("0.2.0", "2026-09-17", "https://x/AA%20Switch.exe", "abcd"), r);
        Assert.Null(Updater.Parse("""{ "version": "2.3.0" }"""));   // 还没发布过 Windows 版
        Assert.Throws<SwitchException>(() => Updater.Parse("<html>"));
    }

    [Fact]
    public async Task Check_and_download_happy_path()
    {
        var exe = FakeExe();
        var handler = new Serve(r => r.RequestUri!.AbsolutePath.EndsWith("latest.json")
            ? new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent($$"""{ "windows": { "version": "0.2.0", "url": "https://aaswitch.example.com/download/AA%20Switch.exe", "sha256": "{{Sha(exe)}}" } }""") }
            : new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(exe) });
        var release = await Updater.CheckAsync(UpdateUrl, handler);
        var dest = Path.Combine(_dir, "new.exe");
        await Updater.DownloadAsync(release!, UpdateUrl, dest, handler);
        Assert.Equal(exe, File.ReadAllBytes(dest));
    }

    [Fact]
    public async Task Download_rejects_bad_hash_other_host_plain_http_and_non_exe()
    {
        var exe = FakeExe();
        var ok = new Serve(_ => new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(exe) });
        var dest = Path.Combine(_dir, "new.exe");
        const string good = "https://aaswitch.example.com/download/AA%20Switch.exe";

        var e = await Assert.ThrowsAsync<SwitchException>(() => Updater.DownloadAsync(new("0.2.0", "", good, Sha(FakeExe(9))), UpdateUrl, dest, ok));
        Assert.Contains("校验不通过", e.Message);
        Assert.False(File.Exists(dest));   // 不留下没通过校验的文件

        e = await Assert.ThrowsAsync<SwitchException>(() => Updater.DownloadAsync(new("0.2.0", "", "https://evil.example.net/AA%20Switch.exe", Sha(exe)), UpdateUrl, dest, ok));
        Assert.Contains("不是同一个网站", e.Message);
        await Assert.ThrowsAsync<SwitchException>(() => Updater.DownloadAsync(new("0.2.0", "", "http://aaswitch.example.com/x.exe", Sha(exe)), UpdateUrl, dest, ok));
        await Assert.ThrowsAsync<SwitchException>(() => Updater.DownloadAsync(new("0.2.0", "", good, ""), UpdateUrl, dest, ok));
        await Assert.ThrowsAsync<SwitchException>(() => Updater.CheckAsync("http://aaswitch.example.com/latest.json", ok));

        var html = new byte[1_200_000];
        var notExe = new Serve(_ => new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(html) });
        e = await Assert.ThrowsAsync<SwitchException>(() => Updater.DownloadAsync(new("0.2.0", "", good, Sha(html)), UpdateUrl, dest, notExe));
        Assert.Contains("不是一个 Windows 程序", e.Message);

        var missing = new Serve(_ => new HttpResponseMessage(HttpStatusCode.NotFound));
        e = await Assert.ThrowsAsync<SwitchException>(() => Updater.DownloadAsync(new("0.2.0", "", good, Sha(exe)), UpdateUrl, dest, missing));
        Assert.Contains("HTTP 404", e.Message);
    }
}
