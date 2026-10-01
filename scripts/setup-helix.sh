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
#   4. Compiles the patched sources in scripts/cask-src/ against the cask's
#      bundled classpath and JBR (so the bytecode stays binary-compatible with
#      closed-source jars in the same install). Those are copies pinned to the
#      cask's release tag, not the live repo files — see cask-src/README.md.
#      Refuses to run against any other cask version.
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
# Cask release that scripts/cask-src/ was regenerated from (tag kotlin-lsp/v<this>).
PINNED_VERSION="263.4702.0"
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

# The pinned copies replace whole classes; swapping them into a different
# release would silently roll back whatever that release changed in them.
[[ "$VERSION" == "$PINNED_VERSION" ]] || die "scripts/cask-src/ is pinned to $PINNED_VERSION but the cask is $VERSION — regenerate it (see scripts/cask-src/README.md)"

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

CASK_SRC="$REPO_ROOT/scripts/cask-src"
[[ -f "$CASK_SRC/IdeaProjectMapper.kt" ]] || die "missing $CASK_SRC (run from a checkout of the repo)"

WORKSPACE_IMPORT_JAR="$INSTALL_DIR/plugins/kotlin.lsp/lib/modules/language-server.workspace-import.jar"
FEATURES_JAR="$INSTALL_DIR/lib/language-server.api.features.jar"
JBR_HOME="$INSTALL_DIR/jbr/Contents/Home"
[[ -f "$WORKSPACE_IMPORT_JAR" ]] || die "missing $WORKSPACE_IMPORT_JAR"
[[ -f "$FEATURES_JAR" ]] || die "missing $FEATURES_JAR"
[[ -f "$JBR_HOME/release" ]] || die "missing bundled JBR at $JBR_HOME"

# The cask's bytecode targets its bundled JBR; kotlinc refuses to inline it
# into anything older, so match that JVM version.
JVM_TARGET="$(sed -n 's/^JAVA_VERSION="\([0-9]*\).*/\1/p' "$JBR_HOME/release")"

OUT_DIR="$(mktemp -d -t kotlin-lsp-setup)"
trap 'rm -rf "$OUT_DIR"' EXIT

CP="$(find "$INSTALL_DIR/lib" "$INSTALL_DIR/plugins" -name '*.jar' 2>/dev/null | paste -sd ':' -)"

# The patched sources reference internal symbols of their own modules
# (e.g. traceProvider), so -Xfriend-paths lets kotlinc accept them.
run "kotlinc -classpath '$CP' \
    -jdk-home '$JBR_HOME' \
    -Xfriend-paths='$WORKSPACE_IMPORT_JAR,$FEATURES_JAR' \
    -d '$OUT_DIR' \
    -nowarn -jvm-target $JVM_TARGET -Xskip-prerelease-check \
    '$CASK_SRC'/*.kt"
ok "compiled to $OUT_DIR (jvm-target $JVM_TARGET)"

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

# jar:// → file:// rewriting: the new JarUriKt helpers plus the definition,
# typeDefinition, implementation and references handlers that call them.
backup_once "$FEATURES_JAR"
(
    cd "$OUT_DIR"
    run "jar uf '$FEATURES_JAR' \$(find com/jetbrains/ls/api/features -name '*.class')"
)
ok "patched $(basename "$FEATURES_JAR")"

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
