using System.Net;
using System.Text;
using AASwitch.Core;

namespace AASwitch.Core.Tests;

public sealed class ClaudeModelsTests
{
    [Fact]
    public void Discovery_filters_endpoints_deduplicates_aliases_and_orders_versions()
    {
        var list = ClaudeModels.Parse("""
        {"data":[{"id":"gpt-example"},{"id":"claude-opus-5"},
          {"id":"claude-sonnet-5"},{"id":"claude-opus-5-5","supported_endpoint_types":["anthropic","openai"]},
          {"id":"claude-haiku-4-5-20251001"},{"id":"claude-haiku-4-5"},{"id":"claude-opus-5"},
          {"id":"claude-image-only","supported_endpoint_types":["openai"]},{"id":"claude-fable-5-1"}]}
        """);
        Assert.Equal(new[] { "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5", "claude-fable-5-1" }, list);
    }

    [Theory]
    [InlineData("[\"claude-sonnet-5\",\"claude-opus-5\"]")]
    [InlineData("{\"models\":[{\"id\":\"claude-sonnet-5\"},{\"id\":\"claude-opus-5\"}]}")]
    public void Discovery_accepts_other_gateway_shapes(string json) =>
        Assert.Equal(new[] { "claude-opus-5", "claude-sonnet-5" }, ClaudeModels.Parse(json));

    [Theory]
    [InlineData("{\"data\":[{\"id\":\"gpt-example\"}]}")]
    [InlineData("{\"data\":[{\"id\":\"claude-bad name\"}]}")]
    [InlineData("{}")]
    public void Empty_or_invalid_catalog_is_rejected(string json) =>
        Assert.Throws<SwitchException>(() => ClaudeModels.Parse(json));

    sealed class CatalogHandler(HttpStatusCode code) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Assert.Equal("https://gateway.example.test/v1/models", request.RequestUri!.ToString());
            Assert.Equal("Bearer fixture-key", request.Headers.Authorization!.ToString());
            Assert.Equal("test", request.Headers.GetValues("x-fixture").Single());
            return Task.FromResult(new HttpResponseMessage(code) { Content = new StringContent("{\"data\":[{\"id\":\"claude-opus-5\"}]}", Encoding.UTF8, "application/json") });
        }
    }

    [Theory]
    [InlineData(HttpStatusCode.OK)]
    [InlineData(HttpStatusCode.Unauthorized)]
    [InlineData(HttpStatusCode.InternalServerError)]
    public async Task Fetch_checks_http_status_before_returning_catalog(HttpStatusCode code)
    {
        var fetch = ClaudeModels.FetchAsync("https://gateway.example.test", "fixture-key", "x-fixture=test", new CatalogHandler(code));
        if (code == HttpStatusCode.OK) Assert.Equal(new[] { "claude-opus-5" }, await fetch);
        else await Assert.ThrowsAsync<SwitchException>(() => fetch);
    }
}
