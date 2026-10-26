AA Switch 3.0.1 修复 macOS 上 Claude 无法从 API 网关切回账号登录的问题。

- 切回账号时解除本地网关配置中隐藏 Claude.ai 登录入口的旧开关，恢复 Google 和邮箱登录选项，保留网关地址、密钥及会话。
- 按新版 Claude 的实际启动行为识别网关模式：已有网关配置但模式值缺失时，不再误报为账号模式；账号登录被旧开关禁用时也能正确识别。
- 切换桌面模式时先退出 Claude，再写配置，避免退出时的旧配置写回覆盖切换结果。
- 切回账号时使用明确的账号登录启动参数打开 Claude，避免未登录时自动回到网关欢迎页。

macOS 本机试用通过；165 项隔离冒烟检查、37 项自动回归测试通过，其中 13 项覆盖 Claude 桌面模式切换。正式安装包使用 Developer ID 签名及 Apple 公证。

本次仅发布 macOS，Windows 继续使用 [v2.4.4](https://github.com/yhq1998/AA-switch/releases/tag/v2.4.4)。官网和 GitHub Release 使用同一批安装包，源码提交和 SHA256 见附带清单。
