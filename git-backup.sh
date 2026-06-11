#!/bin/bash
# git-backup.sh — daily git bundle backups of every repo under SCAN_ROOT.
# Design: docs/DESIGN.md  Configuration: config.example
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Optional config file (see config.example). Values set there override both
# the built-in defaults and any GIT_BACKUP_* environment variables.
CONFIG_FILE="${GIT_BACKUP_CONFIG:-$HOME/.config/git-backup/config}"
if [ -f "$CONFIG_FILE" ]; then
  . "$CONFIG_FILE"
fi

SCAN_ROOT="${GIT_BACKUP_ROOT:-$HOME/Projects}"
DEST="${GIT_BACKUP_DEST:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/RepoBackups}"
RETENTION_DAYS="${GIT_BACKUP_RETENTION_DAYS:-30}"
LOG_FILE="${GIT_BACKUP_LOG:-$HOME/Library/Logs/git-backup.log}"

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
fi

TODAY=$(date +%Y-%m-%d)
BACKED_UP=0
SKIPPED=0
FAILURES=0

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"
}

notify() {
  [ "${GIT_BACKUP_NO_NOTIFY:-0}" = "1" ] && return 0
  command -v osascript >/dev/null 2>&1 || return 0
  osascript -e "display notification \"$1\" with title \"git-backup\"" >/dev/null 2>&1 || true
}

prune_bundles() {
  local repodest=$1
  local cutoff newest b d
  cutoff=$(date -v-"${RETENTION_DAYS}"d +%Y-%m-%d)
  newest=""
  for b in "$repodest"/*.bundle; do
    [ -e "$b" ] || continue
    case "$(basename "$b" .bundle)" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) newest="$b" ;;
    esac
  done
  for b in "$repodest"/*.bundle; do
    [ -e "$b" ] || continue
    [ "$b" = "$newest" ] && continue
    d=$(basename "$b" .bundle)
    case "$d" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) continue ;;
    esac
    if [[ "$d" < "$cutoff" ]]; then
      rm -f "$b"
      log "PRUNE: $b"
    fi
  done
}

backup_repo() {
  local repo=$1
  local rel=${repo#"$SCAN_ROOT"/}
  local name=${rel//\//__}
  local repodest="$DEST/$name"
  local dirty refs

  dirty=$(git -C "$repo" status --porcelain 2>/dev/null)
  refs=$(git -C "$repo" for-each-ref --format='%(objectname) %(refname)' 2>/dev/null \
         | grep -v ' refs/backups/' || true)

  if [ -z "$refs" ] && [ -z "$dirty" ]; then
    log "SKIP (empty repo): $name"
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi

  local tree=""
  if [ -n "$dirty" ]; then
    local tmpidx
    tmpidx=$(mktemp -u)
    GIT_INDEX_FILE="$tmpidx" git -C "$repo" add --ignore-errors -A 2>/dev/null || true
    tree=$(GIT_INDEX_FILE="$tmpidx" git -C "$repo" write-tree 2>/dev/null)
    rm -f "$tmpidx"
  fi

  if [ -n "$dirty" ] && [ -z "$tree" ]; then
    log "FAIL (snapshot tree): $name"
    FAILURES=$((FAILURES + 1))
    return 1
  fi

  local fingerprint
  fingerprint=$(printf '%s\n%s\n' "$refs" "$tree" | shasum -a 256 | awk '{print $1}')
  if [ -f "$repodest/.fingerprint" ] && [ "$(cat "$repodest/.fingerprint")" = "$fingerprint" ]; then
    log "SKIP (unchanged): $name"
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN (would back up): $name"
    return 0
  fi

  if [ -n "$tree" ] && [ "$tree" != "4b825dc642cb6eb9a060e54bf8d69288fbee4904" ]; then
    local head commit
    if head=$(git -C "$repo" rev-parse -q --verify HEAD); then
      commit=$(git -C "$repo" commit-tree "$tree" -p "$head" -m "backup snapshot $TODAY")
    else
      commit=$(git -C "$repo" commit-tree "$tree" -m "backup snapshot $TODAY")
    fi
    git -C "$repo" update-ref refs/backups/uncommitted "$commit"
  else
    git -C "$repo" update-ref -d refs/backups/uncommitted 2>/dev/null || true
  fi

  mkdir -p "$repodest"
  local bundle="$repodest/$TODAY.bundle"
  local bundle_tmp="$bundle.tmp"
  local ok=0
  if git -C "$repo" rev-parse -q --verify HEAD >/dev/null; then
    git -C "$repo" bundle create "$bundle_tmp" --all HEAD >/dev/null 2>&1 && ok=1
  else
    git -C "$repo" bundle create "$bundle_tmp" --all >/dev/null 2>&1 && ok=1
  fi
  if [ "$ok" -ne 1 ]; then
    log "FAIL (bundle create): $name"
    rm -f "$bundle_tmp"
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  if ! git -C "$repo" bundle verify "$bundle_tmp" >/dev/null 2>&1; then
    log "FAIL (bundle verify): $name"
    rm -f "$bundle_tmp"
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  mv "$bundle_tmp" "$bundle"

  printf '%s' "$fingerprint" > "$repodest/.fingerprint"

  log "OK: $name -> $bundle"
  BACKED_UP=$((BACKED_UP + 1))
  prune_bundles "$repodest"
}

main() {
  if [ ! -d "$SCAN_ROOT" ]; then
    log "FATAL: scan root missing: $SCAN_ROOT"
    notify "Backup FAILED: scan root missing"
    exit 1
  fi
  if [ ! -d "$(dirname "$DEST")" ]; then
    log "FATAL: backup destination parent missing: $(dirname "$DEST")"
    notify "Backup FAILED: destination unavailable"
    exit 1
  fi
  if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$DEST"
    if [ -f "$SELF_DIR/RESTORE.md" ]; then
      cp "$SELF_DIR/RESTORE.md" "$DEST/RESTORE.md" || log "WARN: could not copy RESTORE.md to $DEST"
    fi
  fi

  log "=== backup run start (root: $SCAN_ROOT) ==="
  local gitdir
  while IFS= read -r gitdir; do
    backup_repo "$(dirname "$gitdir")" || true
  done < <(find "$SCAN_ROOT" -maxdepth 6 -name node_modules -prune -o -type d -name .git -print 2>/dev/null | sort)
  log "=== done: $BACKED_UP backed up, $SKIPPED skipped, $FAILURES failed ==="

  if [ "$FAILURES" -gt 0 ]; then
    notify "git-backup: $FAILURES repo(s) failed — check the log"
    exit 1
  fi
}

main
