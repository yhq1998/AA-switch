using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AASwitch.Core;

/// <summary>读写别的程序的 JSON 配置：只动自己关心的字段，其余内容和字段顺序原样保留。</summary>
public static class JsonFile
{
    static readonly JsonSerializerOptions WriteOptions = new()
    {
        WriteIndented = true, NewLine = "\n", Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    /// <summary>文件不存在或为空返回空对象；不是合法 JSON 或顶层不是对象抛 SwitchException。</summary>
    public static JsonObject ReadObject(string path)
    {
        if (!File.Exists(path)) return [];
        var text = File.ReadAllText(path, Encoding.UTF8);
        if (string.IsNullOrWhiteSpace(text)) return [];
        try
        {
            return JsonNode.Parse(text) as JsonObject ?? throw new SwitchException($"{path} 的顶层不是对象。");
        }
        catch (JsonException)
        {
            throw new SwitchException($"读取 {path} 失败（文件不是合法的 JSON？请修好或删掉它再试）。");
        }
    }

    public static void Write(string path, JsonObject obj) => AtomicFile.WriteAllText(path, obj.ToJsonString(WriteOptions) + "\n");

    public static string? String(JsonNode? node) => node is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;
}
