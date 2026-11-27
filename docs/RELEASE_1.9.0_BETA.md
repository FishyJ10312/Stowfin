# Stowfin 1.9.0 Beta · 轻扫

**Apple Silicon · 构建 23 / Build 23 · macOS 14+ · MIT**

**暂未经过 Apple 公证。** Beta 安装包使用本机签名证书，未使用 Apple Developer ID 签名。  
**This Beta ships without Apple notarization or a Developer ID signature.** It uses a local signing certificate.

[下载 Apple 芯片版 / Download for Apple Silicon](https://github.com/FishyJ10312/Stowfin/releases/download/v1.9.0-beta/Stowfin-1.9.0-beta-arm64.zip) · [中文安装与授权](https://github.com/FishyJ10312/Stowfin/blob/v1.9.0-beta/docs/INSTALL.zh-CN.md) · [English installation and permissions](https://github.com/FishyJ10312/Stowfin/blob/v1.9.0-beta/docs/INSTALL.en.md)

**素材和项目默认不勾选。** 可以主动单选、按组选择或全选，二次确认后才会移到废纸篓。  
**Media and projects are unselected by default.** Select them individually, by group or with Select All. Moving them to Trash requires a second confirmation.

## 更新 / What's new

- **开发工具与常用应用的缓存。** 「扫描常用位置」新增 npm、Cargo、Gradle、iOS 模拟器，以及 Slack、VS Code、Discord 的缓存。每条规则只打开自己的缓存目录，例如 `~/.npm/_cacache`、Slack 的 Cache 文件夹；旁边的配置、凭据、Cookie、本地存储和其他隐藏文件夹仍不读取。文件还必须符合该缓存的已知结构，才能被批量选择；npm、cargo、Gradle 后台进程或模拟器正在运行时，相关缓存会跳过。  
  **Developer and app caches.** "Scan common locations" now covers npm, Cargo, Gradle, iOS Simulator, Slack, VS Code and Discord caches. Each rule opens only its own cache folder, such as `~/.npm/_cacache` or Slack's Cache folder; settings, credentials, cookies, local storage and other hidden folders next to them stay unread. Files must also match the cache's known structure to be batch-selectable, and caches are skipped while npm, cargo, a Gradle daemon or a simulator is running.
- **清理后显示废纸篓占用。** 结果页和侧栏会显示废纸篓目前共占用多少，提醒清空后才会释放空间。轻扫只统计，不会清空废纸篓。  
  **Trash usage after cleanup.** The result screen and sidebar show how much the Trash now holds, since the space is freed only when you empty it. Stowfin only measures the Trash and never empties it.
- **长期未用的大文件。** 新的扫描入口会列出 100 MB 以上、半年以上未修改、未打开、未加入的个人文件；筛选菜单可以改为一年或两年，也可以按「最久未用」排序。这些文件仍需逐项选择和二次确认。  
  **Large files unused for a long time.** A new scan lists personal files of 100 MB or more that have not been modified, opened or added for six months. The filter menu offers one or two years, and files can be ordered by least recent use. They still need individual selection and a second confirmation.
- **检查更新。** 侧栏版本号下方可以手动检查 GitHub 上的新版本；「每天自动检查更新」默认关闭。只读取公开的发布列表，不发送本机或文件信息，也不会自动下载或安装。详见[隐私说明](PRIVACY.zh-CN.md)。  
  **Update check.** Check GitHub for a newer release from below the version number in the sidebar; "Check for updates daily" is off by default. Only the public release list is read, nothing about your Mac or files is sent, and nothing is downloaded or installed automatically. See the [privacy notes](PRIVACY.en.md).

## 验证 / Validation

在 macOS 27.2 的 Apple 芯片 Mac 上完整运行 `check.sh`：25 组 955 项自动检查通过，包含 126 项真实终止进程后的中断恢复检查、62 项缓存白名单检查、35 项废纸篓占用 / 长期未用 / 检查更新检查，英文目录验证 894 条词条。所有文件操作只使用临时生成的文件，验收时没有启动应用。另一台 Mac 在默认安全设置下的首次启动、macOS 14 实机仍待验证。  
The full `check.sh` suite passed on Apple Silicon running macOS 27.2: 955 automated checks in 25 groups, including 126 crash-recovery checks that really terminate dedicated processes, 62 allowlisted-cache checks, 35 checks for Trash usage, unused files and the update check, and English localization of 894 entries. All file operations used generated files, and the app was not launched for validation. First launch on another Mac under default security settings and actual macOS 14 hardware are still awaiting validation.

[SHA-256 校验值 / Checksums](https://github.com/FishyJ10312/Stowfin/releases/download/v1.9.0-beta/SHA256SUMS.txt) · [验收记录 / Validation record](https://github.com/FishyJ10312/Stowfin/blob/v1.9.0-beta/docs/validation-1.9.0-beta.json)
