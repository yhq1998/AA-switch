using System.Net;
using AASwitch.Core;

namespace AASwitch.Core.Tests;

public class GatewayReasonTests
{
    [Theory]
    [InlineData("""{"error":{"message":"Invalid token (request id: 2026abc)","type":"new_api_error"}}""", "Invalid token")]
    [InlineData("""{"error":"quota exhausted"}""", "quota exhausted")]
    [InlineData("""{"message":"该令牌已过期（request id: x1）"}""", "该令牌已过期")]
    [InlineData("""{"error":{"message":"key sk-abc123XYZ is disabled"}}""", "key sk-… is disabled")]
    [InlineData("""<html>502 Bad Gateway</html>""", null)]
    [InlineData("""{"error":{"message":"   "}}""", null)]
    [InlineData("""[1,2]""", null)]
    [InlineData("", null)]
    public void GatewayMessage(string body, string? expected) => Assert.Equal(expected, Gateway.GatewayMessage(body));

    [Fact]
    public void GatewayMessage_is_capped() => Assert.Equal(201, Gateway.GatewayMessage($$"""{"message":"{{new string('a', 500)}}"}""")!.Length);

    [Fact]
    public void CleanKey_drops_whitespace_and_invisible_characters() =>
        Assert.Equal("sk-abc123", Gateway.CleanKey(" sk-abc​12\r\n3﻿\t"));

    sealed class Fixed(HttpStatusCode status, string body) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) =>
            Task.FromResult(new HttpResponseMessage(status) { Content = new StringContent(body) });
    }

    [Fact]
    public async Task ProbeWithReason_returns_the_gateway_reason_on_errors()
    {
        var bad = await Gateway.ProbeWithReasonAsync("https://gw.test/v1/models", "sk-x", "", new Fixed(HttpStatusCode.Unauthorized, """{"error":{"message":"无效的令牌"}}"""));
        Assert.Equal((401, "无效的令牌"), bad);
        var ok = await Gateway.ProbeWithReasonAsync("https://gw.test/v1/models", "sk-x", "", new Fixed(HttpStatusCode.OK, """{"message":"ignored"}"""));
        Assert.Equal((200, (string?)null), ok);
        Assert.Equal(401, await Gateway.ProbeAsync("https://gw.test/v1/models", "sk-x", "", new Fixed(HttpStatusCode.Unauthorized, "")));
    }
}
