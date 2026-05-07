#!/usr/bin/env bash
set -Eeuo pipefail

TARGET_DIR="${1:-target-repository}"

log() {
  printf '[target-tests] %s\n' "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

[[ -d "$TARGET_DIR" ]] || fail "Target directory does not exist: ${TARGET_DIR}"
cd "$TARGET_DIR"

log "Testing repository at $(pwd)"
log "Current commit: $(git rev-parse --short HEAD)"

if [[ -f package.json ]]; then
  log "Node.js project detected"

  node --version
  npm --version

  if [[ -f package-lock.json ]]; then
    log "Installing dependencies with npm ci"
    npm ci
  else
    log "Installing dependencies with npm install"
    npm install
  fi

  log "Checking JavaScript syntax"
  find . \
    -path './node_modules' -prune -o \
    -name '*.mjs' -print -o \
    -name '*.js' -print \
    | while read -r file; do
        log "Syntax check: ${file}"
        node --check "$file"
      done

  if npm run | grep -qE '^  test$|^    test$| test$'; then
    log "Running npm test"
    npm test
  else
    log "No npm test script found; skipping npm test"
  fi
else
  log "No package.json found; running generic repository checks"
fi

log "Checking markdown files exist"
markdown_count=$(find . -name '*.md' -not -path './node_modules/*' | wc -l | tr -d ' ')
[[ "$markdown_count" -gt 0 ]] || fail "No markdown files found"

log "Listing repository files"
find . -maxdepth 3 -type f -not -path './.git/*' -not -path './node_modules/*' | sort

log "Target repository checks completed successfully"
