# Restoring From These Backups

Each folder here is one repo from the backed-up projects folder (path slashes
replaced by `__`).
Each dated `.bundle` file is a complete, self-contained snapshot of that repo's
full history: all branches, tags, stashes (only restored by a `--mirror`
clone), and — if there was uncommitted work at backup time — a snapshot
commit at `refs/backups/uncommitted`.

## Local repo corrupted or deleted

    git clone /path/to/2026-06-10.bundle MyRepo

That's it — full history and tags restored; other branches are available as
`origin/<branch>` (check out the ones you need).

## GitHub repo damaged (bad force-push, deleted branch) or account lost

    git clone --mirror /path/to/2026-06-10.bundle repo.git
    cd repo.git
    git push --mirror git@github.com:USER/REPO.git

WARNING: `push --mirror` overwrites ALL refs on the remote. Only use it when
the remote is the thing being repaired.

## Recover uncommitted work

`git clone` does not fetch refs outside branches/tags, so fetch the snapshot
ref explicitly:

    git clone /path/to/2026-06-10.bundle MyRepo
    cd MyRepo
    git fetch /path/to/2026-06-10.bundle '+refs/backups/*:refs/backups/*'

Then, to put the uncommitted work back into the working tree exactly as it
was — modified files modified, untracked files untracked (this recreates the
repo as it stood at backup time):

    git restore --source=refs/backups/uncommitted --worktree -- .

Alternatives:

    git checkout refs/backups/uncommitted        # just inspect the snapshot
    git cherry-pick -n refs/backups/uncommitted  # apply onto current branch

Note: gitignored files are never in backups; everything else round-trips
byte-for-byte (verified by a live restore drill).

## Just need one old file

    git clone /path/to/2026-06-10.bundle tmp
    git -C tmp show HEAD:path/to/file.txt              # from the checked-out branch
    git -C tmp show origin/somebranch:path/to/file.txt # from any other branch
