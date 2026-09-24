using AASwitch.Core;

namespace AASwitch.Tray;

/// <summary>
/// 配置表单：API 地址、额外请求头、API key。保存前规范化地址并用 key 探测网关：401/403 拦下，连不上或 404 可以坚持保存；网关给了原因就一并显示。
/// key 明文显示并回填已保存的，方便核对（与 macOS 版一致）。DialogResult.OK 表示已保存。
/// </summary>
sealed class ConfigureForm : Form
{
    readonly IProduct _p;
    readonly TextBox _url = new(), _headers = new(), _key = new();
    readonly Label _message = new();
    readonly Button _save = new() { Text = "保存" }, _cancel = new() { Text = "取消", DialogResult = DialogResult.Cancel };
    readonly string _hint;
    readonly string _loadedUrl, _loadedKey;   // 打开时回填的地址和 key，用来发现“改了地址、key 还是原地址那个”

    public ConfigureForm(IProduct p)
    {
        _p = p;
        _hint = p.UrlHint + " key 只保存在 Windows 凭据管理器里，按地址域名保存，Codex 和 Claude Code 用同一个网关时共用一个 key。换地址时记得把 key 也换成该地址对应的。";
        Text = $"配置 {p.Name} API";
        Icon = AppInfo.LoadIcon("app.ico", 32);
        Font = SystemFonts.MessageBoxFont ?? Font;
        AutoScaleDimensions = new SizeF(96, 96); AutoScaleMode = AutoScaleMode.Dpi;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = false; ShowInTaskbar = true; TopMost = true;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(520, 298);
        AcceptButton = _save; CancelButton = _cancel;

        _message.SetBounds(16, 12, 488, 112);   // 网关原因加上换地址的提醒，最长五六行 _message.Text = _hint;
        Controls.Add(_message);
        AddRow("API 地址", _url, 132, p.UrlPlaceholder);
        AddRow("额外请求头", _headers, 168, "名称=值，多个用逗号分隔；通常留空");
        AddRow("API key", _key, 204, "sk-…");
        _save.SetBounds(316, 252, 90, 30); _cancel.SetBounds(414, 252, 90, 30);
        Controls.Add(_save); Controls.Add(_cancel);
        _save.Click += async (_, _) => await SaveAsync();

        var (url, headers) = p.LoadConfig();
        _url.Text = url; _headers.Text = headers;
        if (url.Length > 0) _key.Text = p.FindKey(url);
        _loadedUrl = url; _loadedKey = _key.Text;
    }

    void AddRow(string title, TextBox box, int y, string placeholder)
    {
        Controls.Add(new Label { Text = title, TextAlign = ContentAlignment.MiddleRight, Bounds = new Rectangle(16, y, 92, 24) });
        box.SetBounds(116, y, 388, 24); box.PlaceholderText = placeholder;
        Controls.Add(box);
    }

    internal void ShowError(string text) { _message.ForeColor = Color.FromArgb(180, 40, 30); _message.Text = text; Log.Write($"{_p.Name} 配置表单提示：{text}"); }

    async Task SaveAsync()
    {
        var headers = _headers.Text.Trim();
        var key = Gateway.CleanKey(_key.Text);
        var (url, urlError) = TrayView.NormalizeUrl(_url.Text, _p);
        _url.Text = url;
        if (urlError is not null) { ShowError(urlError); return; }
        try { Gateway.ParseHeaderPairs(headers); } catch (SwitchException e) { ShowError(e.Message); return; }
        if (key.Any(c => c > 0x7f)) { ShowError("API key 里有中文或全角字符，可能把 key 前后的文字一起复制进来了，请只粘贴 key 本身。"); return; }

        // key 留空时看这个地址有没有存过（Codex 还会认当前正在用的那个）
        var keyForProbe = key.Length > 0 ? key : _p.FindKey(url);
        if (keyForProbe.Length == 0) { ShowError("这个地址还没有保存过 key，请填写 API key。"); return; }

        _save.Enabled = false; _message.ForeColor = SystemColors.ControlText; _message.Text = "正在用 key 校验地址…";
        var endpoint = _p.ModelsEndpoint(url);
        var (status, reason) = await Gateway.ProbeWithReasonAsync(endpoint, keyForProbe, headers);
        Log.Write($"{_p.Name} 配置校验 {endpoint} → " + (status == 0 ? "连不上" : $"HTTP {status}") + (reason is null ? "" : $"，网关：{reason}"));
        var check = TrayView.ClassifyProbe(status, endpoint, url, reason);
        _save.Enabled = true;
        if (!check.Ok)
        {
            if (check.Blocking)
            {
                // 最常见的情况：改了地址，但 key 框里还是原地址回填的那个
                var oldHost = Gateway.UrlHost(_loadedUrl);
                var keptOld = _loadedKey.Length > 0 && key == Gateway.CleanKey(_loadedKey) && Gateway.UrlHost(url) != oldHost;
                ShowError(check.Message + (keptOld ? $"\n你改了地址，但 API key 还是原来 {oldHost} 的那个，请换成新地址对应的 key。" : ""));
                return;
            }
            var answer = MessageBox.Show(this, check.Message + "\n\n点“是”仍然保存，点“否”返回修改。", "地址校验没有通过", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2);
            if (answer != DialogResult.Yes) { _message.ForeColor = SystemColors.ControlText; _message.Text = _hint; return; }
            Log.Write($"{_p.Name} 配置校验没通过，用户选择仍然保存");
        }
        try { _p.Configure(url, headers, key.Length > 0 ? key : null); }
        catch (SwitchException e) { ShowError(e.Message); return; }
        Log.Write($"{_p.Name} 配置已保存：{url}");
        DialogResult = DialogResult.OK;
    }
}
