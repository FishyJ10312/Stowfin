# Stowfin 1.8.7 Beta · 轻扫

**Apple Silicon · 构建 22 / Build 22 · macOS 14+ · MIT**

**暂未经过 Apple 公证。** Beta 安装包使用本机签名证书，未使用 Apple Developer ID 签名。  
**This Beta ships without Apple notarization or a Developer ID signature.** It uses a local signing certificate.

[下载 Apple 芯片版 / Download for Apple Silicon](https://github.com/FishyJ10312/Stowfin/releases/download/v1.8.7-beta/Stowfin-1.8.7-beta-arm64.zip) · [中文安装与授权](https://github.com/FishyJ10312/Stowfin/blob/v1.8.7-beta/docs/INSTALL.zh-CN.md) · [English installation and permissions](https://github.com/FishyJ10312/Stowfin/blob/v1.8.7-beta/docs/INSTALL.en.md)

**素材和项目默认不勾选。** 可以主动单选、按组选择或全选，二次确认后才会移到废纸篓。  
**Media and projects are unselected by default.** Select them individually, by group or with Select All. Moving them to Trash requires a second confirmation.

## 更新 / What's new

- **更多旧安装包能被识别。** 文件名为「应用名 + 版本号」的 `.dmg` / `.pkg`（例如 `Rectangle0.80.dmg`、`Firefox 131.0.3.dmg`）会与本机已安装、名称完全一致的应用比较版本。版本更旧且至少 7 天未修改时列入推荐清理；同版本或更新版本仍由你自行选择。项目、素材目录和压缩包规则优先，不受影响。  
  **More older installers are recognised.** A `.dmg` or `.pkg` named after an app and its version (for example `Rectangle0.80.dmg` or `Firefox 131.0.3.dmg`) is compared with an installed app of exactly the same name. Older versions untouched for at least 7 days are recommended; the same or newer versions stay manual. Project, creative-folder and archive rules still take precedence.
- **识别 Go 编译缓存。** `~/Library/Caches/go-build` 中符合 Go 缓存结构的文件归为可重建缓存，并在空间分析中归到「Go」。  
  **Go build cache.** Files under `~/Library/Caches/go-build` that match Go's cache structure are treated as a rebuildable cache and grouped under "Go" in Storage.
- **检查脚本更可靠。** `check.sh` 会跑完所有检查组再汇总，失败或中断后只删除本次运行新建的测试夹具。  
  **More reliable checks.** `check.sh` runs every group before summarising and, after a failure or interruption, removes only fixtures created by that run.

界面与 1.8.6 相同，截图和演示见 [1.8.6 更新说明](RELEASE_1.8.6_BETA.md)。  
The interface is unchanged from 1.8.6; see the [1.8.6 notes](RELEASE_1.8.6_BETA.md) for screenshots and demos.

## 验证 / Validation

在 macOS 27.2 的 Apple 芯片 Mac 上完整运行 `check.sh`：23 组 858 项自动检查通过，包含 126 项真实终止进程后的中断恢复检查、34 项范围与复核检查，英文目录验证 834 条词条。所有文件操作只使用临时生成的文件。另一台 Mac 在默认安全设置下的首次启动、macOS 14 实机仍待验证。  
The full `check.sh` suite passed on Apple Silicon running macOS 27.2: 858 automated checks in 23 groups, including 126 crash-recovery checks that really terminate dedicated processes, 34 scope and review checks and English localization of 834 entries. All file operations used generated files. First launch on another Mac under default security settings and actual macOS 14 hardware are still awaiting validation.

[SHA-256 校验值 / Checksums](https://github.com/FishyJ10312/Stowfin/releases/download/v1.8.7-beta/SHA256SUMS.txt) · [验收记录 / Validation record](https://github.com/FishyJ10312/Stowfin/blob/v1.8.7-beta/docs/validation-1.8.7-beta.json)
