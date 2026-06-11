# Design: Automatic Git Repo Backups (daily bundles → iCloud Drive)

## Goal

Automatically back up all git repositories under a chosen folder so that
damage to the local working copy **and/or** the hosting provider (corruption,
accidental deletion, bad force-push, account loss) can be recovered easily.
Backups live in a third location independent of both, include
uncommitted/untracked work, and are restorable with plain git commands.

## Why dated bundles instead of a mirror

A live mirror faithfully replicates damage: a corrupted repo or bad
force-push propagates on the next sync. A dated `git bundle` is an immutable
single-file snapshot of the *entire* repo (all refs, full history), so each
day's backup is isolated from whatever happens later — and recovery is just
`git clone <bundle>`, with no third-party tool in the loop.

## Architecture

- **`git-backup.sh`** — one full backup run. Configured via
  `~/.config/git-backup/config` (sourced shell, see `config.example`) or
  `GIT_BACKUP_*` environment variables.
- **`com.git-backup.agent.plist`** + **`install.sh`** — a launchd agent that
  runs the script daily at 02:00. launchd (unlike cron) runs the job after
  wake if the Mac was asleep at the scheduled time. The installer substitutes
  the install path into the plist and creates an ad-hoc-signed copy of bash
  (`bin/git-backup-bash`) so Full Disk Access can be granted to this agent
  alone (TCC blocks launchd-spawned processes from iCloud Drive; the kernel
  kills unsigned copies of system binaries, hence the re-sign).

## Per-repo backup steps

1. **Discover.** Scan the root for `.git` *directories* (worktrees have a
   `.git` file and are skipped — their history lives in the main repo);
   prune `node_modules`. Backup name = path relative to the root with `/`
   replaced by `__`, avoiding collisions between same-named repos.
2. **Snapshot uncommitted work.** If the tree is dirty, stage everything via
   a *temporary* index (`GIT_INDEX_FILE`), `write-tree` + `commit-tree`, and
   point `refs/backups/uncommitted` at the result. The real index, working
   tree, HEAD, and stash are never touched. If the tree can't be
   snapshotted, the repo is counted as failed — never silently skipped.
3. **Bundle.** `git bundle create <dest>/<name>/<YYYY-MM-DD>.bundle --all
   HEAD`, written to a temp name first.
4. **Verify.** `git bundle verify` must pass before the temp file is moved
   into place; a failed re-run can never clobber an existing good bundle,
   and a failed bundle is never recorded as success.
5. **Skip-if-unchanged.** A fingerprint (SHA-256 of the refs listing + dirty
   tree hash) is stored next to the bundles after each verified backup;
   matching fingerprints skip the repo, keeping sync churn near zero for
   dormant repos.
6. **Prune.** Bundles older than the retention window are deleted — except
   the newest bundle per repo, which is always kept. Only date-named
   `*.bundle` files are ever considered for deletion.

## Error handling

- Per-repo failures are logged and don't abort the run.
- A missing scan root or destination aborts with a FATAL log + notification.
- Any failure ⇒ exit 1 and a macOS notification: failures are never silent.

## Testing

`test/test-git-backup.sh` — a self-contained harness (37 checks) covering
discovery edge cases (worktrees, node_modules-nested repos, empty and
unborn-dirty repos), snapshot content and isolation, fingerprint skips,
prune boundaries (retention window, newest-kept, non-date filenames),
dry-run, failure isolation with a corrupted repo, exit codes, config-file
precedence, and the never-clobber-a-good-bundle invariant.
