AA Switch 3.0.2 同步发布 macOS 与 Windows，补齐 Windows 的 Claude 账号切换修复和近期菜单体验。

- Windows 同步修复 Claude 账号入口被旧网关配置隐藏的问题；已有网关但模式值缺失、或账号入口被禁用时，按 Claude 实际行为识别模式。
- Windows 切回账号时解除本地禁止账号登录的开关，保留网关地址、密钥及会话；退出应用后再写入配置。安装包版和 Microsoft Store 版均传递明确的账号登录启动参数。
- Windows 增加“更新最新模型列表…”：展示模型变化，确认后应用；账号模式下保存供下次使用，网关模式下应用并按需重启。命令行支持 `aaswitch claude desktop models --dry-run`。
- Windows 主窗口增加独立“关闭窗口”，关闭后继续在托盘运行，“退出”单独放在右侧；地址与切换说明收进“更多”，操作图标保持一致。
- macOS 保留 v3.0.1 的账号切换修复，与 Windows 统一升级至 v3.0.2。Claude 环境检测仍仅在 macOS 提供。

macOS 安装包使用 Developer ID 签名及 Apple 公证。Windows 为自带运行时的 64 位单文件程序。官网、GitHub Release 与应用内更新使用同批构建产物，源码提交及 SHA256 见随包清单。
