# 开发与发布

本文档面向维护者。用户请看 [README](README.md)。

## 命令行

菜单栏 App 只是壳，真正干活的是 `~/.codex/codex-mode`（App 启动时自动安装）。也可以直接在终端用：

```bash
~/.codex/codex-mode api          # 切到 API；首次会要一次 key，可存进钥匙串
~/.codex/codex-mode chatgpt      # 切回 ChatGPT 账号；有存档的登录态会自动恢复
~/.codex/codex-mode status       # 看当前模式，不显示 key
~/.codex/codex-mode configure    # 修改 API 地址、额外请求头或 key
```

没有签名包时也可以用一行命令安装（curl 下载的文件不带隔离标记，Gatekeeper 不拦）：

```bash
curl -fsSL https://你的托管目录/setup.sh | bash
```

菜单栏工具的日志在 `~/.codex/codex-mode-menubar.log`。

## 官网（site/）

React + Vite + TypeScript + Tailwind，动效用 framer-motion，图标用 lucide-react。构建产物是纯静态文件。

```bash
cd site
npm install
npm run dev      # 本地预览
npm run build    # 产物在 site/dist/
```

文案在 `site/src/sections/` 三个文件里；英雄区和功能区的视频地址在各自文件顶部的常量里。
“下载 macOS 版”按钮的地址由环境变量 `VITE_DOWNLOAD_URL` 决定（见 `site/.env.example`），不设则指向 GitHub Releases。

### 部署到自己的服务器

国内同事访问 GitHub 不稳定，建议官网和 dmg 都放自己的服务器。任何能跑 Caddy 或 Nginx 的 Linux 机器都行；
**大陆机器需要域名备案**，香港、新加坡等不用。

1. **DNS**：加一条 A 记录，例如 `aaswitch.example.com → 服务器 IP`。
2. **服务器装 Caddy**（自动申请 HTTPS 证书）：

   ```bash
   sudo apt install -y caddy          # Debian / Ubuntu；其他系统见 caddyserver.com/docs/install
   sudo mkdir -p /var/www/aaswitch
   ```

3. **Caddyfile**（`/etc/caddy/Caddyfile`）：

   ```caddyfile
   aaswitch.example.com {
       root * /var/www/aaswitch
       encode gzip zstd
       try_files {path} /index.html
       file_server
       header /assets/* Cache-Control "public, max-age=31536000, immutable"
       header /download/* Content-Disposition attachment
   }
   ```

   然后 `sudo systemctl reload caddy`。

4. **本机一条命令构建并上传**（会顺带把 `menubar/dist/AA Switch.dmg` 传到 `/download/AA-Switch.dmg`）：

   ```bash
   cd site
   VITE_DOWNLOAD_URL=https://aaswitch.example.com/download/AA-Switch.dmg \
   DEPLOY_TARGET=root@服务器IP:/var/www/aaswitch \
   ./deploy.sh
   ```

   以后改官网或出新 dmg，重复这一条即可。

用 Nginx 的话，站点配置等价于：

```nginx
server {
    listen 80;
    server_name aaswitch.example.com;
    root /var/www/aaswitch;
    location / { try_files $uri $uri/ /index.html; }
    location /assets/ { add_header Cache-Control "public, max-age=31536000, immutable"; }
    location /download/ { add_header Content-Disposition attachment; }
}
```

再用 certbot 加 HTTPS：`sudo certbot --nginx -d aaswitch.example.com`。

## 发布

### 一次性准备（需要 Apple 开发者账号，只做一次）

1. **Developer ID Application 证书**：Xcode → Settings → Accounts → 选团队 → Manage Certificates → “+” → Developer ID Application。装好后 `security find-identity -v -p codesigning` 能看到类似 `Developer ID Application: 公司名 (TEAMID)` 的一行。
2. **公证凭据**：在 appleid.apple.com 生成一个 App 专用密码，然后运行一次

   ```bash
   xcrun notarytool store-credentials aaswitch
   ```

   按提示填 Apple ID、Team ID、专用密码。以后构建脚本用 `aaswitch` 这个名字提交公证。

### 每次发布

```bash
cd menubar
DEFAULT_BASE_URL=https://api.example.com/v1 \
DEFAULT_HEADERS='{ "x-my-header" = "value" }' \
DEFAULT_LEGACY_KEYCHAIN_SERVICE=旧版脚本的钥匙串服务名 \
SIGN_IDENTITY="Developer ID Application: 公司名 (TEAMID)" \
NOTARY_PROFILE=aaswitch \
./build.sh
```

产出 `menubar/dist/AA Switch.dmg`（已签名、已公证、已装订）和 `AASwitch.app.tar.gz`。把 dmg 放到任何能下载的地方发给同事即可。三个 `DEFAULT_*` 都可不填，不填时首次切换会从已有 `config.toml` 推断地址，推断不到就交互询问。

不设 `SIGN_IDENTITY` 时是 ad-hoc 签名，只能通过方式二的 curl 命令分发（curl 下载的文件不带隔离标记，Gatekeeper 不拦；浏览器或聊天软件下载的会被拦）。

`BUNDLE_ID` 默认 `com.omniapexroute.aaswitch`，可用环境变量改，但发出去之后不要再改：系统的自动化授权、开机自启都挂在它上面。

### 方式二的托管

把 `setup.sh`（顶部 `DEFAULT_*` 填好）、`codex-mode.sh`、`AASwitch.app.tar.gz` 放到同一个可下载目录。

### 升级

脚本里有 `CODEX_MODE_VERSION`，AA Switch 启动时发现自带的脚本比已装的新就自动替换（旧的备份到 `~/.codex/codex-mode-backups/`）。发新版时改这个版本号、重新构建、把新 dmg 发给同事覆盖安装即可。

## 原理

- Codex 把每条会话创建时用的 provider 名写进会话，配置里必须有同名 provider 才能继续该会话。
- 脚本把 `config.toml` 的默认 provider 固定为一个名字，两种模式都不改这一行，只改 provider 块里的 `base_url` / `http_headers`：API 模式写地址，账号模式注释掉，走 OpenAI 官方后端。
- 历史上出现过的其他 provider 名（配置里的、数据库里的、会话文件里的）都写成指向同一地址的别名块。指向别处且自带 `env_key` 的 provider 原样保留。
- 内置的 `openai` 不允许被覆盖，记成 `openai` 的会话会把首行 `session_meta` 里的 provider 改成默认名，数据库里对应字段一并更新。会话正文不动。
- 写入前把 `config.toml`、`auth.json`、要改的会话文件和数据库快照复制到 `~/.codex/codex-mode-backups/<时间>/`；写完让 Codex 读一遍新配置（`codex login status`，它会完整加载配置且不联网，比 `codex doctor` 快几秒），读不通或登录失败就整体恢复。
- 切换前若处于 ChatGPT 登录态，把 `auth.json` 存一份到 `~/.codex/codex-mode-auth/chatgpt.json`；切回账号模式时直接恢复，不用重新登录。token 过期时 Codex 会自己提示登录。

## 文件

| 路径 | 用途 |
| --- | --- |
| `/Applications/AA Switch.app` 或 `~/Applications/AA Switch.app` | 菜单栏小工具，源码在 `menubar/`，图标在 `menubar/icon/aa-switch.svg` |
| `~/.codex/codex-mode` | 脚本本体（由 App 安装，或 setup.sh 安装） |
| `~/.codex/codex-mode.conf` | 地址、请求头、provider 名（不含 key） |
| macOS 钥匙串 `codex-mode:<域名>` | API key。首次切 API 时依次尝试：这个条目 → Codex 当前正在用的 key → 旧版脚本的钥匙串条目 → 手动输入 |
| `~/.codex/codex-mode-auth/chatgpt.json` | 上次的 ChatGPT 登录态，切回账号模式时恢复 |
| `~/.codex/codex-mode-backups/` | 每次切换的备份（config.toml、auth.json、被改的会话、数据库快照）、旧版脚本 |
| `~/.codex/codex-mode-menubar.log` | 菜单栏工具的日志 |
| `~/Library/LaunchAgents/<BUNDLE_ID>.plist` | 开机自启（在菜单里勾选后生成） |

## 环境变量（脚本）

| 变量 | 用途 |
| --- | --- |
| `CODEX_HOME` | Codex 数据目录，默认 `~/.codex` |
| `CODEX_APP_NAME` | 应用名，默认自动找 `ChatGPT` / `Codex` |
| `CODEX_BIN` | Codex 命令行路径，默认用应用内自带的 |
| `CODEX_MODE_NO_REOPEN=1` | 切换后不自动重开应用 |
| `CODEX_MODE_NONINTERACTIVE=1` | 需要输入时直接报错，供图形界面调用 |
| `CODEX_SETUP_URL` | setup.sh 安装时临时指定托管目录 |
| `CODEX_SETUP_NO_MENUBAR=1` | setup.sh 只装脚本，不装菜单栏工具 |
