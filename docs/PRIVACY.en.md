# Privacy and local data

English · [简体中文](PRIVACY.zh-CN.md)

Applies to Stowfin 1.9.0 Beta distributed by this repository.

## Processing

Stowfin reads your selected folders and authorized locations locally for storage totals, classification, search, duplicate checks, archiving and cleanup. The app does not upload file contents, paths, scan indexes or cleanup history. It has no application-sent telemetry, advertising or account login.

## Update check

Stowfin makes one kind of network request: a check for a newer release. It runs only when you choose "Check for Updates", or once a day if you turn on "Check for updates daily" (off by default). The check is an anonymous GET of the public release list at `api.github.com/repos/FishyJ10312/Stowfin/releases`. No file names, paths, scan results, hardware details or identifiers are sent, and no cookies are kept. GitHub receives the request like any other web request, including your IP address. Stowfin never downloads or installs an update; a newer version opens its release page in your browser.

File operations and verification read actual files. Duplicate checks, archive verification and recovery may calculate SHA-256 content hashes. Media information is inspected locally. Scan contents are not sent to a cloud model.

## Local storage

Data is saved under `~/Library/Application Support/QingSweep/`, including:

- Scan scope and time, names and paths, capacity, classification, ownership and access state.
- Rebuildable storage and cleanup-candidate indexes.
- Ignore rules, cleanup history, batch receipts and per-file operation logs.
- Identity metadata, content checksums and original-media associations explicitly confirmed by the user.
- Tool-task history, growth snapshots and related settings.

Language choice is saved separately in macOS-managed local application preferences. It changes presentation, not the stored identities of scanned or recoverable files.

Storage indexes can be rebuilt. Recovery logs and history are not ordinary scan cache: deleting them can remove in-app recovery information and does not restore files already moved to Trash.

## Permissions and links

macOS manages folder permissions and Full Disk Access. You grant and revoke them in System Settings. Permission and cleanup eligibility are separate checks; granting access never automatically selects media or projects.

Documentation and rule-source links may open in your browser. GitHub, Apple and other destination sites handle those browser requests. macOS's own diagnostics and privacy mechanisms are outside Stowfin's control.

## Public feedback

GitHub Issues are public. Share only the needed app/macOS version, chip, reproduction steps and redacted screenshots. Do not attach entire scan databases, cleanup history, creative assets, projects, signing keys or passwords. Paths may contain personal information.
