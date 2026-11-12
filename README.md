# codex-proxy-fix
「针对Windows 使用代理软件的情况下Codex 重连5次的检测与修复工具」
# Codex 代理修复工具

用于 Windows，帮助排查 Codex 桌面版反复重连的问题。脚本会探测
本地 HTTP 代理端口，并在确认后配置当前用户的代理环境变量。

## 使用方法

1. 启动本地代理软件。
2. 点击 Code → Download ZIP，解压后将两个脚本保存在同一目录。
3. 双击 `Codex代理修复.cmd`，按提示操作。

在命令提示符中，也可以使用以下参数：

- `Codex代理修复.cmd -Status`：查看代理配置并检测连通性。
- `Codex代理修复.cmd -Port 7892`：手动指定端口，请替换成你的实际端口。
- `Codex代理修复.cmd -Rollback`：恢复备份。没有备份时，确认后会清除
  `HTTP_PROXY`、`HTTPS_PROXY` 和 `NO_PROXY`。

这是独立工具，与 OpenAI 无官方关联。
