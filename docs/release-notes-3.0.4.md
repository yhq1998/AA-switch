AA Switch 3.0.4 默认开启 Claude Desktop 网关模式下的 MCP 工具按需加载，减少大量工具定义占用上下文。

- macOS 和 Windows 写入桌面网关配置时统一设置 `toolSearchEnabled: true`，新建配置和重新应用已有配置均生效。
- 使用 Claude Desktop 提供的配置开关，由桌面端处理会话设置；无需个人用户配置组织 managed settings。
- 已有用户升级后，在 Claude Code 的“更多”中选择“重新应用 API 配置并重启 Claude 桌面应用”，再新建会话。桌面端可在右侧 Context 详情底部检查 `MCP tools (deferred)`。
- 网关需支持 `anthropic-beta`、`defer_loading` 和 `tool_reference`，不兼容的网关可能拒绝请求。

本次共享行为覆盖 macOS 与 Windows；macOS 本机手动验证已确认出现 MCP 延迟加载统计。两端配置回归测试及 macOS 冒烟检查通过。macOS 发布包使用 Developer ID 签名和 Apple 公证；Windows 为自带运行时的 64 位单文件程序。
