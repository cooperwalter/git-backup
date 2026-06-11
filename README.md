# git-backup

Daily `git bundle` backups of every git repo under a folder you choose
(default `~/Projects`) to iCloud Drive — or any destination — on macOS. Each
bundle is a complete snapshot: all branches, tags, stashes, plus uncommitted
work captured at `refs/backups/uncommitted`. 30-day retention; the newest
bundle per repo is always kept. Because each day's bundle is an immutable
file, corruption or a bad force-push today can never damage yesterday's
backup. Recovery is plain `git clone` — see `RESTORE.md` (also copied into
the backup folder itself).

No dependencies beyond what ships with macOS (bash 3.2, git, launchd).

## Install

    bash install.sh

Installs a launchd agent (`com.git-backup.agent`) that runs daily at 02:00,
or on next wake if the Mac was asleep.

**One-time setup:** macOS privacy controls (TCC) block launchd-spawned
processes from iCloud Drive, so scheduled runs fail until you grant access.
The installer creates a dedicated bash copy at `bin/git-backup-bash` and the
agent runs through it, so the grant is scoped to this agent only — not every
bash script on the machine. After installing:

1. System Settings → Privacy & Security → Full Disk Access
2. Click `+`, press Cmd-Shift-G, and add `bin/git-backup-bash` from this repo
3. Verify: `launchctl kickstart "gui/$(id -u)/com.git-backup.agent"`, then
   check `~/Library/Logs/git-backup.log` shows `0 failed`.

## Configuration

Defaults work out of the box. To change them:

    mkdir -p ~/.config/git-backup
    cp config.example ~/.config/git-backup/config
    # then uncomment and edit values

| Variable | Default |
|---|---|
| `GIT_BACKUP_ROOT` | `~/Projects` |
| `GIT_BACKUP_DEST` | `~/Library/Mobile Documents/com~apple~CloudDocs/RepoBackups` |
| `GIT_BACKUP_RETENTION_DAYS` | `30` |
| `GIT_BACKUP_LOG` | `~/Library/Logs/git-backup.log` |
| `GIT_BACKUP_NO_NOTIFY` | `0` (set to `1` to disable macOS notifications) |

The same variables can be set as environment variables for one-off runs;
values in the config file take precedence. `GIT_BACKUP_CONFIG` points the
script at an alternative config file.

## Manual runs

    bash git-backup.sh --dry-run   # show what would be backed up
    bash git-backup.sh             # run a backup now

## Tests

    bash test/test-git-backup.sh

## Uninstall

    launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.git-backup.agent.plist
    rm ~/Library/LaunchAgents/com.git-backup.agent.plist

## Known limitations

- Git submodules are not backed up separately: discovery skips them (their
  `.git` is a file), and the parent repo's bundle records only the commit
  SHAs it references. If a submodule's upstream disappears, its history is
  not in these backups.

## Troubleshooting

- Failures post a macOS notification and are detailed in
  `~/Library/Logs/git-backup.log`.
- If the scheduled run produced nothing in `git-backup.log` at all, check
  `~/Library/Logs/git-backup.launchd.log` — errors that occur before the
  script starts (e.g. a wrong script path) only appear there.
- If scheduled runs fail to write to iCloud Drive while manual runs work
  (symptom: every repo logs `FAIL (bundle create)` and the run starts with
  `WARN: could not copy RESTORE.md`), macOS privacy controls (TCC) are
  blocking the background process. Grant Full Disk Access to
  `bin/git-backup-bash` (see Install), then `launchctl kickstart
  gui/$(id -u)/com.git-backup.agent` to retry.
