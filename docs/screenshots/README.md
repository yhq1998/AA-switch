README 里的截图。Windows 的三张由 CI 生成：`.github/workflows/windows.yml` 里 `"AA Switch.exe" --render <目录> --demo` 用固定的演示数据把界面画成 PNG，
在 `shots` 产物的 `demo/` 下（`gh run download <运行号> -n shots`）。界面改了之后取新的覆盖这里即可：
`menu.png → windows-menu.png`，`configure-codex.png → windows-configure.png`，`onboarding.png → windows-onboarding.png`。
