# 开发与发布

本文档面向维护者。用户请看 [README](README.md)。

## 命令行

菜单栏 App 只是壳，真正干活的是两个脚本（App 启动时自动安装）：`~/.codex/codex-mode` 管 Codex，`~/.claude/claude-mode` 管 Claude Code。也可以直接在终端用：

```bash
~/.codex/codex-mode api          # 切到 API；首次会要一次 key，可存进钥匙串
~/.codex/codex-mode chatgpt      # 切回 ChatGPT 账号；有存档的登录态会自动恢复
~/.codex/codex-mode status       # 看当前模式，不显示 key
~/.codex/codex-mode configure    # 修改 API 地址、额外请求头或 key
~/.codex/codex-mode codex-path   # 排查“找不到 Codex 命令行”：输出找到的那个，或列出找过的位置

~/.claude/claude-mode api        # Claude Code 切到 API：写 ~/.claude/settings.json 的 env 块，新会话立即生效
~/.claude/claude-mode account    # 切回 Claude 账号：删掉 env 块里的那几项，账号登录态一直都在
~/.claude/claude-mode status
~/.claude/claude-mode configure  # 地址填网关根地址（不带 /v1）；首次运行会沿用 codex-mode 的地址去掉 /v1
~/.claude/claude-mode desktop models   # 问网关要一份模型列表，更新桌面应用里能选的模型（当前就在网关模式时顺带重新应用并重启它）
```

没有签名包时也可以用一行命令安装（curl 下载的文件不带隔离标记，Gatekeeper 不拦）：

```bash
curl -fsSL https://你的托管目录/setup.sh | bash
```

菜单栏工具的日志在 `~/.codex/codex-mode-menubar.log`。

macOS 的 Claude 账号环境检测由 `menubar/ClaudeAccountEnvironment.swift` 提供界面，`menubar/claude-account-environment.sh` 只适配参数、依赖和本地状态目录。14 项检测函数及 STUN 探针从 `menubar/vendor/claude-switcher/` 的固定上游提交原样复用；完整源文件保留作比对，不执行、不打进应用包。构建时仅打入检测函数、探针、来源清单和 MIT 许可，并由发布校验逐字比对。更新上游时同步更新来源清单和原样提取区间，运行 `python3 -m unittest discover -s tests -p test_claude_account_environment.py` 验证来源与隔离行为。

macOS 的 Codex 切换会先正常退出运行中的 ChatGPT / Codex 桌面应用，再向当前用户精确匹配名称的桌面、`codex`、`codex-app-server` 进程发送 TERM，最多等 5 秒后对剩余进程发送 KILL，再等 2 秒；仍有进程时列出名称和 PID，停止切换，配置和会话不动。这样处理的是空闲后台也会阻挡切换的问题。正在执行的 Codex 任务会中断，桌面应用会重新打开，CLI / IDE 会话需用户自行重开。进程退出与恢复的隔离回归测试：`python3 -m unittest discover -s tests -p test_codex_processes.py`；测试替换全部进程操作，不会结束真实进程。

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

4. **本机一条命令构建并上传**（会顺带把 `menubar/dist/AA Switch.dmg` 传到 `/download/AA Switch.dmg`，URL 里写成 `AA%20Switch.dmg`）：

   ```bash
   cd site
   VITE_DOWNLOAD_URL=https://aaswitch.example.com/download/AA%20Switch.dmg \
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

Codex / Claude 的共享功能和修复必须检查并同步 macOS 与 Windows，实现方式允许按系统调整；不能仅因问题先在 Mac 上复现就跳过 Windows。Claude 环境检测目前是明确的平台差异，仅 macOS 提供。发布说明应列出平台差异，两端共享行为有改动时同步构建、验证并更新官网两端安装包。

发布前先提交全部构建输入，并增加根目录 `VERSION`；禁止用同一个版本号替换不同内容的包。Mac 构建还会跑 `tests/` 下的隔离回归测试，Windows 构建会传播测试失败状态。
两个构建脚本都会输出 `release-manifest.json`，记录源码提交、构建输入及产物的 SHA256；Mac 同时校验包内两个脚本与源码逐字一致，Windows 校验两个 exe 的内部文件版本。
`site/deploy.sh` 上传前会校验清单、当前提交、源码和版本；源码改变后必须重新构建，两平台分开发布时请把另一个平台的旧产物移出默认 dist 路径。
线上已有同版本但哈希不同、降级、线上索引读取失败都会停止发布。安装包上传完成后才原子替换 `latest.json`；清单也随包上传到官网，并应作为 GitHub Release 资产保留。
GitHub Release 必须使用同一批已校验的包，tag 指向清单中的提交，不能重新构建另一份。发完从官网和 GitHub 各下载一次核对 SHA256。

```bash
python3 scripts/release_artifacts.py verify mac menubar/dist
python3 scripts/release_artifacts.py verify windows windows/dist
```

```bash
cd menubar
DEFAULT_BASE_URL=https://api.example.com/v1 \
DEFAULT_HEADERS='{ "x-my-header" = "value" }' \
DEFAULT_LEGACY_KEYCHAIN_SERVICE=旧版脚本的钥匙串服务名 \
SIGN_IDENTITY="Developer ID Application: 公司名 (TEAMID)" \
NOTARY_PROFILE=aaswitch \
UPDATE_URL=https://aaswitch.example.com/download/latest.json \
./build.sh
```

产出 `menubar/dist/AA Switch.dmg`（已签名、已公证、已装订）和 `AASwitch.app.tar.gz`。

**冒烟测试。** `build.sh` 第一步会跑仓库根目录的 `smoke-test.sh`（约 7 秒），不通过就不出包；改了脚本也可以随时单独跑 `./smoke-test.sh`。它在一个空的临时家目录里模拟刚装上的新用户，用系统自带的 bash 3.2 把两个脚本的主要路径各跑一遍并检查写出的文件：状态、配置、切到 API、切回账号、key 被拒（401/403）和登录失败时的回滚、备份清理、用户原有配置是否保留、桌面应用的网关模式和会话同步、从网关更新桌面模型列表、找 codex 命令行的几种应用包布局。钥匙串、curl、pgrep、open、codex 命令行都换成假替身，osascript 只放行读写 JSON 的 JavaScript，所以不碰真实配置、不会退出正在用的应用。发出去的每个版本都会通过 `latest.json` 立刻推给所有用户，而自己机器上“备份早就超过 20 份”这类状态会掩盖新用户才遇到的问题（2.2.3–2.2.5 切换必失败就是这么漏出去的），所以新增脚本功能时顺手在这里加一条断言。它测不到菜单和弹窗、真实网关，以及真的 Codex / Claude 对配置的反应。

**版本号与更新提示。** dmg 的文件名固定是 `AA Switch.dmg`（官网 URL 写作 `AA%20Switch.dmg`，浏览器保存时还原成带空格的名字；deploy.sh 另存一份 `AA-Switch.dmg` 兼容旧链接；服务器 Caddy 对这两个路径都下发 `Content-Disposition: attachment; filename="AA Switch.dmg"`，所以从任何入口、任何浏览器下载保存的都是这个名字；GitHub Release 的资产名不允许空格，会显示成 `AA.Switch.dmg`，内容相同），版本号不放文件名里，而是：`site/deploy.sh` 上传时顺带生成 `download/latest.json`（版本、日期、地址、sha256）；官网在下载按钮下显示"当前版本 vX.Y.Z"；App 构建时通过 `UPDATE_URL` 记住这个地址，启动时和之后每 6 小时读一次，发现比自己新就在菜单底部显示"有新版本 X.Y.Z，点击更新…"。点了就是应用内更新：下载 `download/AASwitch.app.tar.gz`（deploy.sh 一并上传），依次校验 sha256（latest.json 里的 `tgz_sha256`）、`codesign --verify --deep --strict`、签名 Team ID 与当前安装一致、版本号更新，全过了才写一个小脚本等本进程退出后替换 `/Applications/AA Switch.app` 并重新打开；任一步失败不动现有安装，弹窗给下载页。ad-hoc 签名的开发版不做 Team ID 比对。老于 2.2.0 的版本没有检查更新的逻辑，只能人工通知一次。App 的版本号取仓库根目录的 `VERSION` 文件（Mac 和 Windows 共用，发版前改这一个地方；也可用 `VERSION=` 覆盖）；GitHub Release 的 tag 用同一个版本号，两个平台的安装包放在同一个 Release 里。把 dmg 放到任何能下载的地方发给同事即可。三个 `DEFAULT_*` 都可不填，不填时首次切换会从已有 `config.toml` 推断地址，推断不到就交互询问。

不设 `SIGN_IDENTITY` 时是 ad-hoc 签名，只能通过方式二的 curl 命令分发（curl 下载的文件不带隔离标记，Gatekeeper 不拦；浏览器或聊天软件下载的会被拦）。

`BUNDLE_ID` 默认 `com.omniapexroute.aaswitch`，可用环境变量改，但发出去之后不要再改：系统的自动化授权、开机自启都挂在它上面。

### 方式二的托管

把 `setup.sh`（顶部 `DEFAULT_*` 填好）、`codex-mode.sh`、`AASwitch.app.tar.gz` 放到同一个可下载目录。

### Windows 版

代码在 `windows/`（C# / .NET 10，说明和进度见 [windows/README.md](windows/README.md)），和 macOS 版互不影响；版本号和 Mac 版共用根目录的 `VERSION`（从 2.3.3 起统一，之前 Windows 是 0.x）。在 macOS 上就能交叉编译（`brew install dotnet`）：

```bash
cd windows
VERSION=0.2.0 UPDATE_URL=https://aaswitch.example.com/download/latest.json ./build.sh    # 产物在 windows/dist/
cd ../site
VITE_DOWNLOAD_URL=https://aaswitch.example.com/download/AA%20Switch.dmg DEPLOY_TARGET=root@服务器IP:/var/www/aaswitch ./deploy.sh
```

`deploy.sh` 发现 `windows/dist/AA Switch.exe` 就上传到 `/download/AA Switch.exe`，并在 `latest.json` 里写 `windows` 段（版本、日期、地址、sha256）；顶层字段仍是 macOS 版的，
老版本的 App 只读顶层，不受影响。两个平台可以分开发布：这次没带上安装包的平台，服务器上已有的文件和 `latest.json` 里它的那部分原样保留
（以线上现有的 `latest.json` 为底合并，rsync 对缺的安装包加 protect）。

Claude 桌面应用的切换（网关模式 / 账号模式、Code 和 Cowork 会话同步）在 Windows 上由 `ClaudeDesktop` / `DesktopSessions` 实现，逻辑照搬 `claude-mode.sh` 的 desktop 部分，
路径差异见 windows/README.md；改 `claude-mode.sh` 的 desktop 逻辑时记得两边一起改。

官网上两个平台的下载按钮并排，访客自己的系统排在前面；顶部导航的“下载”悬停（触屏上点一下）展开下拉框，可选 macOS 版或 Windows 版。
`latest.json` 里还没有 `windows` 段时只有 macOS 按钮，“下载”也只是普通链接。地址加 `?os=windows` / `?os=mac` 可以指定哪个平台排在前面。

Windows 版的应用内更新：启动时和之后每 6 小时读 `latest.json` 的 `windows` 段，比自己新就在菜单底部显示“有新版本，点击更新…”。点了就下载 exe、校验 sha256 和文件头，
把正在运行的自己改名成 `AA Switch.exe.old`（Windows 允许给运行中的 exe 改名），新的放到原位置，启动新版本后退出，`.old` 下次启动时删掉；任一步失败不动现有安装。
Windows 版目前没有代码签名，所以只信 https，且下载地址必须和 `latest.json` 同一个主机；首次运行会被 SmartScreen 拦一下（“更多信息 → 仍要运行”）。

验证靠 GitHub Actions（`.github/workflows/windows.yml`，推送 `windows/**` 时触发）：在 windows-latest 上跑单元测试、真 Claude Code / codex + 本地假网关的端到端、
托盘的切换路径、应用内更新的端到端，再把界面画成 PNG、真实启动一次并截屏，放在 `shots` 产物里。

### 升级

脚本里有 `CODEX_MODE_VERSION` / `CLAUDE_MODE_VERSION`，AA Switch 启动时发现自带的脚本比已装的新，或版本相同但内容不同，就备份并替换；已装脚本版本更高时保留。发新版时增加修改过的脚本版本和根目录应用版本，再重新构建。升级不会主动中断 Claude 会话；要让已有桌面网关配置中的网络放行设置生效，请用“更多 → 重新应用 API 配置并重启 Claude 桌面应用”。

## 原理

- Codex 把每条会话创建时用的 provider 名写进会话，配置里必须有同名 provider 才能继续该会话。
- 脚本把 `config.toml` 的默认 provider 固定为一个名字，两种模式都不改这一行，只改 provider 块里的 `base_url` / `http_headers`：API 模式写地址，账号模式注释掉，走 OpenAI 官方后端。
- 历史上出现过的其他 provider 名（配置里的、数据库里的、会话文件里的）都写成指向同一地址的别名块。指向别处且自带 `env_key` 的 provider 原样保留。
- 内置的 `openai` 不允许被覆盖，记成 `openai` 的会话会把首行 `session_meta` 里的 provider 改成默认名，数据库里对应字段一并更新。会话正文不动。
- 写入前把 `config.toml`、`auth.json`、要改的会话文件和数据库快照复制到 `~/.codex/codex-mode-backups/<时间>/`；写完让 Codex 读一遍新配置（`codex login status`，它会完整加载配置且不联网，比 `codex doctor` 快几秒），读不通或登录失败就整体恢复。
- 切换前若处于 ChatGPT 登录态，把 `auth.json` 存一份到 `~/.codex/codex-mode-auth/chatgpt.json`；切回账号模式时直接恢复，不用重新登录。token 过期时 Codex 会自己提示登录。
- **找 codex 命令行的位置会变，所以按顺序探好几个地方**（`codex-mode codex-path` 输出探到的那一个，探不到就列出找过的位置，诊断信息里也有这一行）。ChatGPT 26.924（2026-09-26 的自动更新）把自带的 CLI 从 `Contents/Resources/codex` 搬进了 `Contents/Resources/codex-cli/`：入口写在同目录 `codex-package.json` 的 `entrypoint`（现在是 `bin/codex`，一个 `exec` 掉 `CodexCLI.app/Contents/MacOS/codex` 的壳），旁边还有 `codex-resources/`、`codex-path/`。只探老路径的版本（2.2.4 及以前）从那天起对所有人都是「切换失败：找不到 Codex 命令行」——`api`、`chatgpt`、`fix-threads` 三条命令开头都要 `need_codex`，只有 `status` 还能跑，所以菜单上一切正常、一点就失败。顺序是：`CODEX_BIN` → 老路径 → `entrypoint`（只接受包内相对路径）→ 已知的新路径 → `CodexCLI.app` 里的真二进制 → `PATH` → `CODEX_MODE_EXTRA_BINS` 里那几个（`~/.local/bin`、Homebrew、`/usr/local/bin`；菜单栏应用继承的 `PATH` 只有 `/usr/bin:/bin:/usr/sbin:/sbin`，自己装的 codex 全不在里面）。`codex login status` 的措辞新版没变，`auth_mode` 照样认得。

### Claude Code（claude-mode.sh）

- Claude Code 的凭据优先级里，环境变量 `ANTHROPIC_AUTH_TOKEN` 排在账号登录之前，且 `~/.claude/settings.json` 的 `env` 块对终端和 IDE 里的每个新会话生效。所以切 API 只是往 `env` 块写 `ANTHROPIC_BASE_URL`、`ANTHROPIC_AUTH_TOKEN`（有额外请求头再写 `ANTHROPIC_CUSTOM_HEADERS`），切回账号只是删掉它们。用 `ANTHROPIC_AUTH_TOKEN` 而不是 `ANTHROPIC_API_KEY`，后者首次使用会弹确认。
- 切 API 时还写 `ANTHROPIC_MODEL`，默认用 1M 上下文：模型名带 `[1m]` 后缀（`opus[1m]`，或者 settings.json 里 `model` 的值加 `[1m]`），Claude Code 就按 1M 窗口算，并带上 `context-1m-2025-08-07` beta 头。不检测网关是否真支持：网关 `/v1/models` 不给上下文长度，超长请求各上游报错也不一样，没法可靠地测。网关不支持时，对话超过 200K 会报错。用户自己写的、不带 `[1m]` 的 `ANTHROPIC_MODEL` 不动；切回账号只删带 `[1m]` 的那份。
- **Claude 桌面应用的 Code 标签不看 settings.json。** 桌面应用启动 Code 会话时设置 `CLAUDE_CODE_ENTRYPOINT=claude-desktop` 并注入 `CLAUDE_CODE_OAUTH_TOKEN`、`ANTHROPIC_BASE_URL`；在这种入口下引擎强制使用注入的 OAuth token，`settings.json` 里的 `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_API_KEY` / `apiKeyHelper`、乃至进程环境里的 `ANTHROPIC_AUTH_TOKEN` 全部被忽略（调试日志里的原话：`keeping the user-supplied CLAUDE_CODE_OAUTH_TOKEN instead of adopting the stored credential`）。
- **让桌面应用走网关只能整个应用切到第三方推理模式**（官方文档 <https://claude.com/docs/third-party/claude-desktop>），`claude-mode desktop gateway|account` 做的就是这件事，菜单里 Claude Code 那行的开关会和命令行一起切：
  - 网关配置写在 `~/Library/Application Support/Claude-3p/configLibrary/<id>.json`（`inferenceProvider: gateway`、`inferenceGatewayBaseUrl`、`inferenceGatewayApiKey`、`inferenceGatewayAuthScheme: bearer`、`inferenceModels`），`_meta.json` 的 `appliedId` 指向当前用的那份；这和应用里 Developer > Configure Third-Party Inference 写的是同一处。
  - macOS 和 Windows 每次写入桌面网关配置时，都设置 `toolSearchEnabled: true`，包括新建和重新应用已有配置。Claude Desktop 网关默认关闭 MCP Tool Search，并向会话注入 `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`；只在用户 settings 中设置 `ENABLE_TOOL_SEARCH=true` 无法覆盖。桌面端专用开关由应用负责选择兼容路径：较新引擎保留其他实验功能的禁用，通过会话内的 managed settings 开启 Tool Search；旧引擎则解除实验功能禁用并设置 `ENABLE_TOOL_SEARCH=true`。因此看到禁用变量仍为 1 不足以断定 Tool Search 未生效，应在新会话中检查 ToolSearch；桌面端 `/context` 的延迟工具统计在右侧 Context 详细区域的 `MCP tools (deferred)` 行，主卡片只显示已用上下文汇总。核对依据：[官方网关文档](https://claude.com/docs/third-party/claude-desktop/gateway#mcp-tool-search)、[Claude Code MCP 文档](https://code.claude.com/docs/en/mcp#configure-tool-search)及本机 Claude Desktop 3.6556.2 的配置 schema 和会话启动逻辑。网关必须支持 `anthropic-beta`（`tool-search-tool-2025-10-19`）、`defer_loading` 和 `tool_reference`；不支持时可能报 HTTP 400。AA Switch 不修改全局 managed settings 或 MCP 服务器作用域。已有用户重新应用 API 配置、重启桌面端后新建会话生效；仅安装新版 AA Switch 不会追改正在运行的会话。
  - macOS 和 Windows 每次写入桌面网关配置时，都设置 `coworkEgressAllowedHosts: ["*"]`，允许 Cowork / Code 工具访问所有外网域名；新配置和已有配置都适用，旧的域名白名单会被替换。Claude 默认只放行推理域名，留空或删除该字段不会解除限制。该字段不控制模型推理或 Web Search；网页抓取仍由 Claude 拦截 localhost 和内网地址。
  - 账号 / 网关的选择写在 `~/Library/Application Support/Claude-3p/claude_desktop_config.json` 的 `deploymentMode`（注意在 `-3p` 目录，应用代码里取路径的函数固定加 `-3p` 后缀，主目录那份不读）（`1p` 账号、`3p` 网关）。已保存网关时，模式值缺失或为空也会进入网关；显式 `1p` 且未禁止 Claude.ai 登录时才走账号（核对 Claude 3.6556.2 启动逻辑）。切换必须先退出应用，再写配置并重新打开，避免退出时的配置写回覆盖新模式。旧网关配置中的 `disableDeploymentModeChooser: true` 会强制第三方模式并隐藏账号入口，切回账号时清为 `false`，写入网关时也清为 `false`。切回账号会用 `--claude-first-party-sign-in` 打开 Claude（即使原来未运行），避免没有桌面登录态时应用自动丢弃 `1p`；`CLAUDE_MODE_NO_REOPEN=1` 可禁止打开。网关切换仍仅在原来运行时重开。隔离回归测试：`python3 -m unittest discover -s tests -p test_claude_desktop_mode.py`，覆盖默认网关识别、账号入口禁用开关、显式登录启动参数及退出时旧配置写回。
  - 网关模式用独立的数据目录 `Claude-3p`，账号登录态留在主目录，两边互不影响，切换不用重新登录。Claude Code 引擎的会话记录仍在 `~/.claude/projects/`，终端里 `--resume` 不受影响。
  - 桌面应用侧边栏的会话列表按数据目录各存一份：`<数据目录>/claude-code-sessions/<账号 uuid>/<组织 uuid>/local_<id>.json`，每个文件记着 `cliSessionId`（对应 `~/.claude/projects` 里的记录）、目录、标题、模型、权限模式；`deleted_<id>` 是删除标记。账号模式的账号 / 组织 uuid 取自 `~/.claude.json` 的 `oauthAccount`，网关模式是一个固定的本地账号（组织 `00000000-0000-4000-8000-000000000001`）。`claude-mode desktop gateway|account|sync` 会把两边互相补齐（只补缺的，不覆盖，尊重删除标记），并把 `preferences.localAgentModeTrustedFolders` 取并集，这和应用自己 Help > Troubleshooting 里的 "Import Claude Code CLI Sessions…" 效果相同。第一次进入网关模式时 `Claude-3p` 里还没有会话目录，要等应用初始化一次后再切一次（或跑 `desktop sync`）才会补齐。
  - **Cowork 会话**也按数据目录各存一份：`<数据目录>/local-agent-mode-sessions/<账号>/<组织>/local_<id>.json` 加同名目录（网关模式下是 `<账号前 8 位>/<组织前 8 位>`，例如 `c0062ea9/00000000`）。和 Code 标签不同，对话记录（目录里的 `.claude/projects/<按 cwd 命名>/<cliSessionId>.jsonl`）、`outputs`、`uploads` 都在这个目录里，不共享，所以 `desktop_sync_cowork` 整份复制（APFS 克隆，不额外占空间），把 `local_<id>.json` 和 `.claude/` 下 json/jsonl 里指向原位置的绝对路径、以及按路径命名的目录改到新位置；`audit.jsonl` 带签名（同目录的 `.audit-key`），原样保留。实测（2026-09-24）：复制过去的会话在网关模式下出现在列表里，能打开，接着聊时模型带着之前的上下文回答。
  - Cowork / Tasks 同步兼容组织目录的完整 UUID 与 8 位短名、外层和 `agent/` 元数据、完整与 8 位短名正文目录、带额外下划线的合法会话 ID。复制短名正文时使用完整目标会话名并同步改写路径；同时间戳的元数据副本若缺正文会重新补齐。macOS 与 Windows 共享该行为；普通 Chat 云端记录不属于这套本地任务同步。
  - 复制后两份各自往下走，所以 `~/.claude/claude-mode-cowork-sync` 记着每个会话上次同步时的 `lastActivityAt`（新版本按源/目标目录对分别保存在 `.pairs/`，`agent/` 使用独立账本，旧文件保留最近快照）：只有一边比它新就用那边覆盖另一边（旧的挪进本次备份的 `cowork/`），两边都新了算冲突、都不动；记录里有但某一边没了，当作在那边删掉了，不补回去。同步在应用退出之后、重新打开之前做；`desktop sync` 手动触发时应用开着就跳过 Cowork。
  - 桌面应用启动时会做一次健康检查，日志（`~/Library/Logs/Claude-3p/main.log`）里 `ConfigHealth` 为 `config_model_rejected` 表示网关对模型请求回了 404（多半是地址多带了 `/v1`，见下一条；也可能真是模型名不对），`auth_failed` / `unreachable` 分别对应 key 和地址问题。
  - 桌面地址默认和 `base_url` 一样，**不带 `/v1`**：官方文档的示例带 `/v1`，但桌面应用把地址原样交给内置的 Claude Code 引擎，引擎自己再加 `/v1/messages`，带了就变成 `/v1/v1/messages`，网关回 404，应用把它报成"模型不存在"（日志里 `Gateway rejected model … (HTTP 404)`、健康检查 `config_model_rejected`）。模型列表默认 `claude-opus-5-5,claude-sonnet-5,claude-haiku-4-5,claude-fable-5-1`，第一个是默认模型；写进 `inferenceModels` 时每个名字后面加 `[1m]`（已经带了的不重复加），桌面应用把选中的名字原样交给 Claude Code，这样网关模式下桌面应用也默认 1M 上下文（实测 2026-09-30：`claude-opus-5-5[1m]` 能选、能聊，窗口是 1M；`~/.claude/settings.json` 的 `ANTHROPIC_MODEL` 对桌面应用不起作用，会被这里选中的模型覆盖）；`claude-mode.conf` 里的 `desktop_base_url`、`desktop_models` 可改。
  - **模型列表可以从网关拉**：菜单里 Claude Code 的“更多 → 更新最新模型列表…”（装了桌面应用才显示），或命令行 `claude-mode desktop models`。脚本请求网关的 `/v1/models`，只留 `claude-*`（有 `supported_endpoint_types` 时必须含 `anthropic`，桌面应用只走 Anthropic 接口），去掉和不带日期的同名模型重复的 `-20YYMMDD` 别名，按 opus → sonnet → haiku → 其余字母序排，同系列版本号大的在前，所以最新的 Opus 是默认模型。菜单里分两步：先用 `CLAUDE_MODE_DRY_RUN=1` 只问不写，把新增 / 不再提供 / 默认模型的变化摆给用户看，确认后再把这份列表用 `CLAUDE_MODE_MODELS=` 传回脚本写进 conf（不再问第二次网关）。当时就在网关模式的话顺带重新应用并重启桌面应用，账号模式只写 conf、下次切过去时生效。
- **切到 API 前 App 先确认配好了**：地址来自 status，key 用 `find-key URL`（Codex 会顺带把当前在用的 key 或旧版钥匙串条目迁移到 `codex-mode:<域名>`，但只对配置里那个网关的域名做迁移）；缺一样就先弹配置表单，保存后接着切，用户取消就不切。表单保存时会规范化地址（去空格和末尾斜杠；Codex 只给域名就补 `/v1`，Claude 去掉 `/v1`）并用 key 请求一次 models 接口：2xx 通过，401/403 判定 key 无效不让存，连不上或 404 弹确认框可"仍然保存"。
- 会话是本地 jsonl 文件，与后端无关；账号登录态在钥匙串里，脚本不碰。所以不用退出重开、不用备份登录态、不用修会话。
- JSON 用系统自带的 `osascript -l JavaScript` 读写，其他键原样保留，写前备份到 `~/.claude/claude-mode-backups/<时间>/`。
- 地址是网关根地址（Claude Code 自己加 `/v1/messages`），与 Codex 的 `/v1` 风格不同；key 的钥匙串条目按域名命名（`codex-mode:<域名>`），两个脚本共用。
- 终端、IDE 插件、桌面版 Code 标签用的是同一个引擎和同一个 `~/.claude`，会话文件互通；前两者跟着 settings.json 切，桌面版跟着 deploymentMode 切。

## 文件

| 路径 | 用途 |
| --- | --- |
| `/Applications/AA Switch.app` 或 `~/Applications/AA Switch.app` | 菜单栏小工具，源码在 `menubar/`，图标在 `menubar/icon/aa-switch.svg` |
| `~/.codex/codex-mode` | 脚本本体（由 App 安装，或 setup.sh 安装） |
| `~/.codex/codex-mode.conf` | 地址、请求头、provider 名（不含 key） |
| macOS 钥匙串 `codex-mode:<域名>` | API key。首次切 API 时依次尝试：这个条目 → Codex 当前正在用的 key → 旧版脚本的钥匙串条目 → 手动输入 |
| `~/.codex/codex-mode-auth/chatgpt.json` | 上次的 ChatGPT 登录态，切回账号模式时恢复 |
| `~/.codex/codex-mode-backups/` | 每次切换的备份（config.toml、auth.json、被改的会话、数据库快照，只留最近 20 次）、旧版脚本（留 3 份） |
| `~/.codex/codex-mode-menubar.log` | 菜单栏工具的日志 |
| `~/.claude/claude-mode` | Claude Code 的切换脚本（由 App 安装，或 setup.sh 安装） |
| `~/.claude/claude-mode.conf` | Claude Code 用的网关地址、请求头（不含 key） |
| `~/.claude/claude-mode-backups/` | 每次改 settings.json 和桌面配置前的备份（只留最近 20 次）、旧版脚本（留 3 份） |
| `~/Library/LaunchAgents/<BUNDLE_ID>.plist` | 开机自启（在菜单里勾选后生成） |

## 环境变量（脚本）

| 变量 | 用途 |
| --- | --- |
| `CODEX_HOME` | Codex 数据目录，默认 `~/.codex` |
| `CODEX_APP_NAME` | 应用名，默认自动找 `ChatGPT` / `Codex` |
| `CODEX_BIN` | Codex 命令行路径，默认按 `codex-path` 那套顺序找 |
| `CODEX_MODE_EXTRA_BINS` | `PATH` 之外再找的几个 codex 路径，冒号分隔；置空表示不找（冒烟测试就这么隔离） |
| `CODEX_MODE_NO_REOPEN=1` | 切换后不自动重开应用 |
| `CODEX_MODE_NONINTERACTIVE=1` | 需要输入时直接报错，供图形界面调用 |
| `CODEX_SETUP_URL` | setup.sh 安装时临时指定托管目录 |
| `CODEX_SETUP_NO_MENUBAR=1` | setup.sh 只装脚本，不装菜单栏工具 |
| `CLAUDE_MODE_MODELS` | `desktop models` 直接用这份列表（逗号分隔），不问网关；菜单确认过之后就这么写回去 |
| `CLAUDE_MODE_DRY_RUN=1` | `desktop models` 只打印 `models=` / `current=` / `desktop=`，什么都不写 |
