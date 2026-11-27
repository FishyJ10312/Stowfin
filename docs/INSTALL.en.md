# Installation and permissions

English · [简体中文](INSTALL.zh-CN.md)

For **Stowfin 1.9.0 Beta, build 23**, on Apple Silicon / arm64.

The release uses a local signing certificate. **It has no Developer ID signature and has not been notarized by Apple.** You can download the open-source project from GitHub; macOS may require an explicit first-launch exception. Installation on another Mac with default security settings is still awaiting validation.

## 1. Download and use one installation location

1. Open the [Beta release](https://github.com/FishyJ10312/Stowfin/releases/tag/v1.9.0-beta) and download `Stowfin-1.9.0-beta-arm64.zip`.
2. Extract it and move the app to `~/Applications/轻扫.app`. Create your personal Applications folder if necessary. The display name is **Stowfin** in English and **轻扫** in Simplified Chinese.
3. Launch the same installed copy. When upgrading, quit the old version and replace it at the same path. Keep an older copy elsewhere if you need a rollback.

Avoid alternating between copies in Downloads, extracted folders and backups when granting permissions.

Optional integrity check: download `SHA256SUMS.txt` and run this in the download directory:

```sh
shasum -a 256 Stowfin-1.9.0-beta-arm64.zip
```

Compare the result with the matching file name in the checksum list. Matching hashes establish download consistency, not notarization or freedom from defects.

## 2. First launch

Try opening the installed app. If macOS cannot verify the developer, and you trust the download and have checked its integrity, follow Apple's single-app process:

1. Open **System Settings → Privacy & Security**.
2. Find the block message for the installed app and choose **Open Anyway**.
3. Check the application name and complete macOS's confirmation.

[Apple: Safely open apps on your Mac](https://support.apple.com/en-us/102445). Availability depends on macOS and device-management policy. If macOS reports damage, tampering or detected malware, stop using that file, recheck the download and report the exact message.

The installation does not require globally disabling Gatekeeper, SIP or system security checks. This project does not provide commands to disable those protections or remove download quarantine markers.

## 3. Grant access when needed

**Scan common locations** checks Downloads, caches and logs. The file threshold starts at 1 MB, with known smaller caches included in groups. Use **Analyze all locations** in Storage for broader read-only analysis.

macOS may request access to Downloads, Desktop, Documents or a selected external folder. Authorize the locations you intend to inspect. A denied cleanup scan opens the access assistant with **Choose folder**, **Open System Settings** and **Recheck**. Unread locations are excluded from reported totals and remain marked **Not read yet**. Recheck scans the saved scope again; it does not silently expand the scope.

After a permission change that requires relaunch, Stowfin tests previously denied locations and rescans the saved scope if access has actually recovered. If access is still denied, the issue remains available to resolve. No file is selected or deleted automatically.

Before cleanup, Stowfin checks whether Trash can be read so an interrupted operation can be reconciled. If the app reports that Trash or another required location is unreadable:

1. Choose **Open System Settings** in Stowfin.
2. Open **Privacy & Security → Full Disk Access** and enable the installed app.
3. If absent, use `+` to add the installed app at `~/Applications/轻扫.app`, then enable it.
4. Complete the password or Touch ID step yourself. Quit and reopen the app if macOS requests it.
5. Return to **File access assistant → Recheck**, or **History → Reconcile again** for an interrupted cleanup. Stowfin performs an actual read before updating the result.

[Apple: Change Privacy & Security settings](https://support.apple.com/en-my/guide/mac-help/mchl211c911f/mac). Full Disk Access is broad and controlled by macOS; you can revoke it in the same settings. The app cannot enable it itself and never needs you to send your password to the developer.

Full Disk Access does not make every system location readable or eligible for cleanup. Missing directories, disconnected disks and system restrictions are reported separately.

## 4. Choose a language

The same download contains English and Simplified Chinese. The language menu at the top of the window offers **System default**, **简体中文** and **English**. The choice is saved across launches. Unsupported system languages fall back to English.

Selections, file names, paths and recovery identities are preserved. The language menu is disabled during cleanup review or file operations. Dialogs supplied by macOS follow the system's own language settings.

## 5. Try a disposable folder first

Create a temporary folder containing files you can discard:

1. Scan that folder and try entering a child folder, returning and going up.
2. Confirm that media and projects start unselected. Adding recommendations must leave them unselected.
3. Select test files yourself. In the review, remove an item or an entire group.
4. Complete the second confirmation for **Manual review** content before moving it to Trash.
5. Open **History**, restore the batch, then inspect the original locations and contents.

The operation journal records per-file intent and outcome. After an interruption, the app reconciles known file identities and can reconstruct recovery entries. Unprocessed files are not automatically deleted on restart. A log write failure stops further operations; unresolved files are not guessed from matching names.

## Upgrades and restore

- Keep the installation path stable. A different signing identity, rebuilding from source or a device-policy change may require permission again.
- Keep `~/Library/Application Support/QingSweep/` when upgrading. Recovery logs, history and ignore rules are not disposable scan cache.
- Restore never overwrites existing destination files. Resolve a conflict yourself, then recheck and retry.
- If trash access is unavailable or a disk is disconnected, restore access or reconnect the disk, then choose **Recheck** in History.
- Restore requires the corresponding Trash item to remain available and pass checks. Emptying Trash or changing/moving a file can make recovery unavailable.
- Moving files to Trash does not immediately reclaim their displayed size. Stowfin does not empty Trash for you.

## If something does not work

If **Open Anyway** is missing, first try launching the app and consult Apple's documentation. Managed Macs may prohibit exceptions. Do not repeatedly add different app copies to solve an access problem.

If permission remains denied, verify the installed copy, relaunch if requested and recheck. Report the macOS version, chip, app version and exact message in an [issue](https://github.com/FishyJ10312/Stowfin/issues/new?template=bug_report_en.md).

DaVinci proxies and cache can be reviewed and selected manually. Confirm that original media is available and the project no longer needs the selected files; Stowfin does not read every reference in DaVinci's private project database.
