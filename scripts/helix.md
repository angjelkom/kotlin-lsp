# Helix setup

## Quick start

1. [Install `kotlin-lsp` CLI](../README.md#install-kotlin-lsp-cli) (or via Homebrew: `brew install --cask kotlin-lsp`)
2. Make sure the `kotlin-lsp` binary is on your `$PATH`
3. Add this to your [`~/.config/helix/languages.toml`](https://docs.helix-editor.com/languages.html):

    ```toml
    [language-server.kotlin-lsp]
    command = "kotlin-lsp"
    args = ["--stdio"]
    # First-time Gradle import on a cold cache can take >20s; raise the
    # default initialize timeout so Helix doesn't tear down the channel.
    timeout = 90

    [[language]]
    name = "kotlin"
    language-servers = ["kotlin-lsp"]
    roots = ["settings.gradle.kts", "settings.gradle", "build.gradle.kts", "build.gradle"]
    ```

4. (Recommended) Tell the server which build system to use and which JDK to
   resolve symbols against. Without this, Gradle import doesn't fire for
   non–VS Code clients:

    ```toml
    [language-server.kotlin-lsp.config]
    defaultSdk = "/Users/me/.sdkman/candidates/java/17.0.17-amzn"  # any JDK that exists on disk
    defaultJdk = "/Users/me/.sdkman/candidates/java/17.0.17-amzn"  # legacy alias kept for compat

    [language-server.kotlin-lsp.config.buildTools]
    "file:///Users/me/projects/my-kotlin-project" = "gradle"
    ```

## Patching a Homebrew cask install

Two server-side fixes in this branch are required for Helix (and other
non-IntelliJ LSP clients) to work end-to-end on a Gradle JVM project:

- **`fix(import)`** — Gradle import previously emitted `targetPlatform = null`,
  causing the analyzer to fall back to JVM 1.8 and fail FIR resolution on any
  Kotlin code newer than 1.8. (Affects every Gradle project.)
- **`feat(definition)`** — `jar://` URIs returned by goto-definition were dropped
  by Helix because it only handles `file://`. The patched server extracts each
  jar entry to `~/.cache/kotlin-lsp-extracted/` and rewrites the URI before
  responding. (Affects goto-def into any external library.)

Until these changes ship in a release, run the included setup script against
your cask install:

```sh
git clone https://github.com/Kotlin/kotlin-lsp.git
cd kotlin-lsp
./scripts/setup-helix.sh
```

It locates the active `/opt/homebrew/Caskroom/kotlin-lsp/<version>/` install,
clears the macOS Gatekeeper quarantine, compiles the patched sources against
the cask's bundled classpath, swaps the recompiled classes into the bundled
jars, and keeps `.orig.bak` backups for safe rollback.

The script is idempotent — re-run it after every `brew upgrade --cask kotlin-lsp`.

## Troubleshooting

If goto-definition stops working after a server upgrade or restart, wipe the
per-project workspace cache and the analyzer cache so the server reimports
the project from scratch:

```sh
rm -rf ~/.cache/kotlin-lsp-workspaces/<your-project>
rm -rf ~/Library/Caches/JetBrains/analyzer
```

The kotlin-lsp log lives at:

```
~/.cache/kotlin-lsp-workspaces/<your-project>/system/log/intellij-server.log
```

Look for `[IMPORT STD]: BUILD SUCCESSFUL`, `Initial load of project-level (project=…) libraries. There are <N> libraries to load.`, and `InitializeResult:` to confirm the server imported correctly.
