#!/bin/bash
# Test harness for git-backup.sh. Builds fixture repos in a temp dir, runs the
# backup script against them, and asserts on the results. Self-contained; safe
# to run repeatedly. Exit code 0 = all checks passed.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/git-backup.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export GIT_BACKUP_ROOT="$TMP/projects"
export GIT_BACKUP_DEST="$TMP/dest"
export GIT_BACKUP_LOG="$TMP/test.log"
export GIT_BACKUP_NO_NOTIFY=1
export GIT_BACKUP_CONFIG=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

TODAY=$(date +%Y-%m-%d)
PASS=0
FAIL=0

check() {
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS + 1)); echo "  ok: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
  fi
}

# --- fixtures ----------------------------------------------------------------

mkdir -p "$GIT_BACKUP_ROOT/Professional"

# alpha: normal repo with two branches, a tag, a dirty tracked file, an
# untracked file, an ignored file, and a repo nested inside node_modules.
ALPHA="$GIT_BACKUP_ROOT/Professional/alpha"
git init -q "$ALPHA"
echo "ignored.txt" > "$ALPHA/.gitignore"
echo one > "$ALPHA/file.txt"
git -C "$ALPHA" add -A
git -C "$ALPHA" commit -qm "first"
git -C "$ALPHA" branch feature
git -C "$ALPHA" tag v1
echo two >> "$ALPHA/file.txt"
echo new > "$ALPHA/untracked.txt"
echo sec > "$ALPHA/ignored.txt"
mkdir -p "$ALPHA/node_modules"
git init -q "$ALPHA/node_modules/dep"

# worktree of alpha: has a .git FILE (not dir), must be skipped
git -C "$ALPHA" worktree add -q "$GIT_BACKUP_ROOT/Professional/alpha-wt" feature

# beta: empty repo (no commits, clean tree) — must be skipped gracefully
git init -q "$GIT_BACKUP_ROOT/beta"

# gamma: repo with NO commits but a dirty tree — must be backed up via the
# snapshot ref alone (regression: must not log a false bundle-create failure)
GAMMA="$GIT_BACKUP_ROOT/gamma"
git init -q "$GAMMA"
echo g > "$GAMMA/g.txt"

# --- task 1: discovery + bundling ---------------------------------------------

echo "== run 1: initial backup =="
bash "$SCRIPT"
RUN1_EXIT=$?

check "run 1 exits 0" test "$RUN1_EXIT" -eq 0
check "alpha bundle created at dest/Professional__alpha/TODAY.bundle" \
  test -f "$GIT_BACKUP_DEST/Professional__alpha/$TODAY.bundle"
check "worktree alpha-wt got no backup dir" \
  test ! -e "$GIT_BACKUP_DEST/Professional__alpha-wt"
check "repo inside node_modules got no backup dir" \
  test ! -e "$GIT_BACKUP_DEST/Professional__alpha__node_modules__dep"
check "empty repo beta skipped with log line" \
  grep -q "SKIP (empty repo): beta" "$GIT_BACKUP_LOG"
check "empty repo beta got no bundle" \
  bash -c "! ls '$GIT_BACKUP_DEST/beta/'*.bundle 2>/dev/null"

CLONE="$TMP/clone"
git clone -q "$GIT_BACKUP_DEST/Professional__alpha/$TODAY.bundle" "$CLONE" 2>/dev/null
check "bundle is cloneable with checked-out history" git -C "$CLONE" log --oneline
check "clone has feature branch" git -C "$CLONE" rev-parse --verify origin/feature
check "clone has tag v1" git -C "$CLONE" rev-parse --verify v1

# --- task 2: uncommitted-work snapshot -----------------------------------------

echo "== uncommitted snapshot checks =="
git -C "$CLONE" fetch -q origin '+refs/backups/*:refs/backups/*' 2>/dev/null
check "snapshot ref contains the untracked file" \
  git -C "$CLONE" cat-file -e "refs/backups/uncommitted:untracked.txt"
check "snapshot ref contains dirty tracked content" \
  bash -c "git -C '$CLONE' show refs/backups/uncommitted:file.txt | grep -q two"
check "snapshot ref excludes gitignored file" \
  bash -c "! git -C '$CLONE' cat-file -e refs/backups/uncommitted:ignored.txt 2>/dev/null"
check "snapshot did not touch alpha's real index" \
  bash -c "git -C '$ALPHA' status --porcelain | grep -q '?? untracked.txt'"
GCHECK="$TMP/gamma-check"
git init -q "$GCHECK"
git -C "$GCHECK" fetch -q "$GIT_BACKUP_DEST/gamma/$TODAY.bundle" '+refs/backups/*:refs/backups/*' 2>/dev/null
check "unborn dirty repo got a bundle" \
  test -f "$GIT_BACKUP_DEST/gamma/$TODAY.bundle"
check "unborn dirty repo snapshot contains its file" \
  git -C "$GCHECK" cat-file -e "refs/backups/uncommitted:g.txt"

# --- task 3: skip-if-unchanged ---------------------------------------------------

echo "== run 2: no changes -> skip =="
bash "$SCRIPT"
check "unchanged repo is skipped on rerun" \
  grep -q "SKIP (unchanged): Professional__alpha" "$GIT_BACKUP_LOG"

echo "== run 3: change -> re-backup =="
echo three >> "$ALPHA/file.txt"
LOG_LINES=$(wc -l < "$GIT_BACKUP_LOG")
bash "$SCRIPT"
check "changed repo is re-backed up" \
  bash -c "tail -n +$((LOG_LINES + 1)) '$GIT_BACKUP_LOG' | grep -q 'OK: Professional__alpha'"

# --- task 4: retention / prune ---------------------------------------------------

echo "== run 4: prune old bundles =="
touch "$GIT_BACKUP_DEST/Professional__alpha/2020-01-01.bundle"
touch "$GIT_BACKUP_DEST/Professional__alpha/2020-01-02.bundle"
YESTERDAY=$(date -v-1d +%Y-%m-%d)
touch "$GIT_BACKUP_DEST/Professional__alpha/$YESTERDAY.bundle"
touch "$GIT_BACKUP_DEST/Professional__alpha/manual-backup.bundle"
echo four >> "$ALPHA/file.txt"
bash "$SCRIPT"
check "bundles older than retention are pruned" \
  bash -c "test ! -e '$GIT_BACKUP_DEST/Professional__alpha/2020-01-01.bundle' && test ! -e '$GIT_BACKUP_DEST/Professional__alpha/2020-01-02.bundle'"
check "today's bundle survives prune" \
  test -f "$GIT_BACKUP_DEST/Professional__alpha/$TODAY.bundle"
check "bundle within retention window survives prune" \
  test -f "$GIT_BACKUP_DEST/Professional__alpha/$YESTERDAY.bundle"
check "non-date bundle file is never pruned" \
  test -f "$GIT_BACKUP_DEST/Professional__alpha/manual-backup.bundle"
check "prune was logged" grep -q "PRUNE: " "$GIT_BACKUP_LOG"

# --- task 5: dry run -------------------------------------------------------------

echo "== dry run =="
DELTA="$GIT_BACKUP_ROOT/delta"
git init -q "$DELTA"
echo d > "$DELTA/d.txt"
git -C "$DELTA" add -A
git -C "$DELTA" commit -qm "d"
bash "$SCRIPT" --dry-run
check "dry-run creates no backup dir for new repo" \
  test ! -e "$GIT_BACKUP_DEST/delta"
check "dry-run logs what it would do" \
  grep -q "DRY-RUN (would back up): delta" "$GIT_BACKUP_LOG"

# --- task 6: failure isolation + exit code ---------------------------------------

echo "== run with corrupt repo =="
CORRUPT="$GIT_BACKUP_ROOT/AAA-corrupt"
git init -q "$CORRUPT"
echo x > "$CORRUPT/x.txt"
git -C "$CORRUPT" add -A
git -C "$CORRUPT" commit -qm "x"
rm -rf "$CORRUPT/.git/objects"
mkdir -p "$CORRUPT/.git/objects/info" "$CORRUPT/.git/objects/pack"
echo five >> "$ALPHA/file.txt"
LOG_LINES=$(wc -l < "$GIT_BACKUP_LOG")
bash "$SCRIPT"
CORRUPT_EXIT=$?
check "run with a failing repo exits 1" test "$CORRUPT_EXIT" -eq 1
check "corrupt repo failure is logged" \
  bash -c "tail -n +$((LOG_LINES + 1)) '$GIT_BACKUP_LOG' | grep -q 'FAIL (bundle create): AAA-corrupt'"
check "later repos still back up after an earlier failure" \
  bash -c "tail -n +$((LOG_LINES + 1)) '$GIT_BACKUP_LOG' | grep -q 'OK: Professional__alpha'"

# --- task 7: RESTORE.md ------------------------------------------------------------

check "RESTORE.md is copied into the backup destination" \
  test -f "$GIT_BACKUP_DEST/RESTORE.md"

# --- final hardening -----------------------------------------------------------

echo "== missing scan root =="
GIT_BACKUP_ROOT="$TMP/does-not-exist" bash "$SCRIPT"
check "missing scan root exits 1" test "$?" -eq 1
check "missing scan root logs FATAL" grep -q "FATAL: scan root missing" "$GIT_BACKUP_LOG"

echo "== unsnapshottable dirty repo counts as failure =="
LOCKED="$GIT_BACKUP_ROOT/locked"
git init -q "$LOCKED"
echo a > "$LOCKED/a.txt"
git -C "$LOCKED" add -A
git -C "$LOCKED" commit -qm "a"
echo b > "$LOCKED/b.txt"
git -C "$LOCKED" add -A
chmod -R a-w "$LOCKED/.git/objects"
LOG_LINES=$(wc -l < "$GIT_BACKUP_LOG")
bash "$SCRIPT"
LOCKED_EXIT=$?
chmod -R u+w "$LOCKED/.git/objects"
rm -rf "$LOCKED"
check "unsnapshottable dirty repo exits 1" test "$LOCKED_EXIT" -eq 1
check "unsnapshottable dirty repo logs snapshot failure" \
  bash -c "tail -n +$((LOG_LINES + 1)) '$GIT_BACKUP_LOG' | grep -q 'FAIL (snapshot tree): locked'"

echo "== failed re-run preserves existing good bundle =="
KEEPER="$GIT_BACKUP_ROOT/keeper"
git init -q "$KEEPER"
echo k > "$KEEPER/k.txt"
git -C "$KEEPER" add -A
git -C "$KEEPER" commit -qm "k"
bash "$SCRIPT"
check "keeper got a bundle" test -f "$GIT_BACKUP_DEST/keeper/$TODAY.bundle"
rm -f "$GIT_BACKUP_DEST/keeper/.fingerprint"
rm -rf "$KEEPER/.git/objects"
mkdir -p "$KEEPER/.git/objects/info" "$KEEPER/.git/objects/pack"
bash "$SCRIPT"
check "failed re-run preserves the existing good bundle" \
  test -f "$GIT_BACKUP_DEST/keeper/$TODAY.bundle"
check "failed re-run leaves no tmp file" \
  bash -c "! ls '$GIT_BACKUP_DEST/keeper/'*.tmp 2>/dev/null"
rm -rf "$KEEPER"

# --- config file ----------------------------------------------------------------

echo "== config file =="
CONF_ROOT="$TMP/conf-projects"
CONF_DEST="$TMP/conf-dest"
mkdir -p "$CONF_ROOT"
git init -q "$CONF_ROOT/solo"
echo s > "$CONF_ROOT/solo/s.txt"
git -C "$CONF_ROOT/solo" add -A
git -C "$CONF_ROOT/solo" commit -qm "s"
cat > "$TMP/test-config" <<EOF
GIT_BACKUP_ROOT="$CONF_ROOT"
GIT_BACKUP_DEST="$CONF_DEST"
EOF
GIT_BACKUP_CONFIG="$TMP/test-config" bash "$SCRIPT"
check "config file overrides scan root and destination" \
  test -f "$CONF_DEST/solo/$TODAY.bundle"
check "config-file run left default dest untouched" \
  test ! -e "$GIT_BACKUP_DEST/solo"

# --- summary -------------------------------------------------------------------

echo
echo "passed: $PASS  failed: $FAIL"
test "$FAIL" -eq 0
