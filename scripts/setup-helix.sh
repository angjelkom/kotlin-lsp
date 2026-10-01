#!/usr/bin/env bash
# setup-helix.sh — patch a Homebrew-cask kotlin-lsp install for Helix and other
# non-IntelliJ LSP clients.
#
# What it does, in order:
#   1. Locates the active /opt/homebrew/Caskroom/kotlin-lsp/<version>/kotlin-server-<version>/
#      install (apple silicon path; falls back to /usr/local for intel).
#   2. Removes the macOS Gatekeeper quarantine attribute from every file in the
#      install — without this, the bundled native libraries (libfilewatcher_jni
#      etc.) refuse to load.
#   3. Fetches `kotlinc` if it isn't already on PATH.
#   4. Compiles the two patched sources from scripts/cask-src/ against the
#      cask's bundled classpath (so the bytecode stays binary-compatible with
#      closed-source jars in the same install). Those are CASK-PINNED copies of
#      the repo sources: the live repo files track upstream HEAD, which gains
#      APIs ahead of cask releases (e.g. LSP-1097's languageVersion) and then
#      no longer compiles against the released jars. See cask-src/*.kt headers.
#   5. Backs up the affected jars to `<jar>.orig.bak` (only on the first run —
#      subsequent runs preserve the original backup) and swaps the recompiled
#      classes in place.
#
# Idempotent. Safe to re-run after every `brew upgrade --cask kotlin-lsp` —
# upgrades reinstall pristine jars and re-quarantine the install, and this
# script puts the patches back.
#
# Usage: ./scripts/setup-helix.sh [--dry-run]
#
# Until the source-level fixes in this branch ship in a release, you'll need
# to keep running this. After they ship, this script is no longer needed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_RUN=0

for arg in "$@"; do
    case "$arg" in
        --dry-run|-n) DRY_RUN=1 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# //; s/^#$//'
            exit 0
            ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

step() { printf '\n\033[1;34m▸\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$*"; }
die()  { printf '  \033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }
run()  {
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '  \033[2m[dry-run] %s\033[0m\n' "$*"
    else
        eval "$@"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. Locate the cask install
# ─────────────────────────────────────────────────────────────────────────────
step "Locating kotlin-lsp cask install…"

CASK_ROOT=""
for prefix in /opt/homebrew/Caskroom /usr/local/Caskroom; do
    [[ -d "$prefix/kotlin-lsp" ]] && CASK_ROOT="$prefix/kotlin-lsp" && break
done
[[ -n "$CASK_ROOT" ]] || die "kotlin-lsp cask not found. Run: brew install --cask kotlin-lsp"

VERSION="$(/bin/ls -1 "$CASK_ROOT" | grep -E '^[0-9]+\.[0-9]+' | sort -V | tail -1)"
[[ -n "$VERSION" ]] || die "no version subdir under $CASK_ROOT"

INSTALL_DIR="$CASK_ROOT/$VERSION/kotlin-server-$VERSION"
[[ -d "$INSTALL_DIR" ]] || die "missing $INSTALL_DIR"

ok "found kotlin-lsp $VERSION at $INSTALL_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# 2. Clear Gatekeeper quarantine
# ─────────────────────────────────────────────────────────────────────────────
step "Clearing macOS quarantine attributes…"

QUAR_BEFORE="$(find "$CASK_ROOT" -exec xattr {} \; 2>/dev/null | grep -c 'com.apple.quarantine' || true)"
if [[ "$QUAR_BEFORE" -gt 0 ]]; then
    run "xattr -dr com.apple.quarantine '$CASK_ROOT'"
    ok "cleared quarantine on $QUAR_BEFORE files"
else
    ok "no quarantined files"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. Make sure kotlinc is available
# ─────────────────────────────────────────────────────────────────────────────
step "Checking kotlinc availability…"

if ! command -v kotlinc >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
        warn "kotlinc not found; installing via Homebrew"
        run "brew install kotlin"
    else
        die "kotlinc not on PATH and Homebrew not available — install kotlin manually"
    fi
fi
ok "$(kotlinc -version 2>&1 | head -1)"

# ─────────────────────────────────────────────────────────────────────────────
# 4. Compile the patched sources against the cask's classpath
# ─────────────────────────────────────────────────────────────────────────────
step "Compiling patched sources…"

POSITION_KT="$REPO_ROOT/scripts/cask-src/position.kt"
PROJECT_MAPPER_KT="$REPO_ROOT/scripts/cask-src/IdeaProjectMapper.kt"
[[ -f "$POSITION_KT" ]] || die "missing $POSITION_KT (run from a checkout of the repo)"
[[ -f "$PROJECT_MAPPER_KT" ]] || die "missing $PROJECT_MAPPER_KT"

WORKSPACE_IMPORT_JAR="$INSTALL_DIR/plugins/kotlin.lsp/lib/modules/language-server.workspace-import.jar"
COMMON_JAR="$INSTALL_DIR/lib/language-server.api.features.impl.common.jar"
[[ -f "$WORKSPACE_IMPORT_JAR" ]] || die "missing $WORKSPACE_IMPORT_JAR"
[[ -f "$COMMON_JAR" ]] || die "missing $COMMON_JAR"

OUT_DIR="$(mktemp -d -t kotlin-lsp-setup)"
trap 'rm -rf "$OUT_DIR"' EXIT

CP="$(find "$INSTALL_DIR/lib" "$INSTALL_DIR/plugins" -name '*.jar' 2>/dev/null | paste -sd ':' -)"
FRIEND_JAR="$WORKSPACE_IMPORT_JAR"

# IdeaProjectMapper references internal symbols in its own module, so we use
# -Xfriend-paths so kotlinc accepts them.
run "kotlinc -classpath '$CP' \
    -Xfriend-paths='$FRIEND_JAR' \
    -d '$OUT_DIR' \
    -nowarn -jvm-target 17 -Xskip-prerelease-check \
    '$PROJECT_MAPPER_KT' '$POSITION_KT'"
ok "compiled to $OUT_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# 5. Swap classes into the bundled jars (preserving backups)
# ─────────────────────────────────────────────────────────────────────────────
step "Patching bundled jars…"

backup_once() {
    local jar="$1"
    local bak="$jar.orig.bak"
    if [[ -f "$bak" ]]; then
        ok "backup already exists: $(basename "$bak")"
    else
        run "cp '$jar' '$bak'"
        ok "backed up $(basename "$jar") → $(basename "$bak")"
    fi
}

# IdeaProjectMapper: only swap the outer class; inner KotlinCompilerSettings has
# kotlinx-serialization-generated companion classes that recompiling without
# the serialization plugin would invalidate.
backup_once "$WORKSPACE_IMPORT_JAR"
(
    cd "$OUT_DIR"
    run "jar uf '$WORKSPACE_IMPORT_JAR' \
        com/jetbrains/ls/imports/gradle/IdeaProjectMapper.class \
        'com/jetbrains/ls/imports/gradle/IdeaProjectMapper\$calculateKotlinSettings\$SourceSetInfo.class'"
)
ok "patched $(basename "$WORKSPACE_IMPORT_JAR")"

backup_once "$COMMON_JAR"
(
    cd "$OUT_DIR"
    run "jar uf '$COMMON_JAR' \
        com/jetbrains/ls/api/features/impl/common/utils/PositionKt.class"
)
ok "patched $(basename "$COMMON_JAR")"

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────
step "Setup complete"
cat <<EOF

  kotlin-lsp $VERSION at $INSTALL_DIR is ready for non-IntelliJ LSP clients.

  Restart any open Helix/Neovim/etc. sessions so they pick up the patched server.
  Wipe the per-project cache once after upgrading to force a clean reimport:

      rm -rf ~/.cache/kotlin-lsp-workspaces/<project>
      rm -rf ~/Library/Caches/JetBrains/analyzer

  Re-run this script after every \`brew upgrade --cask kotlin-lsp\`.

EOF
