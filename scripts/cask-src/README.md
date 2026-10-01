# cask-src

Sources that `scripts/setup-helix.sh` compiles against the Homebrew `kotlin-lsp`
cask and swaps into its jars. They are **pinned to the cask release**
(`PINNED_VERSION` in the script, currently `263.4702.0`), not to this branch's
HEAD: upstream HEAD gains APIs and behaviour ahead of releases, and a class
compiled from HEAD would either fail against the cask's closed-source jars or
silently replace the release's logic with unreleased code.

Each file is the upstream source at tag `kotlin-lsp/v<PINNED_VERSION>` plus this
branch's fix:

| File | Jar | Fix |
|---|---|---|
| `IdeaProjectMapper.kt` | `language-server.workspace-import.jar` | `targetPlatform` derived from Gradle `jvmTarget` |
| `jarUri.kt` (new) | `language-server.api.features.jar` | `jar://` → `file://` URI rewriting |
| `LSDefinition.kt`, `LSTypeDefinition.kt`, `LSImplementation.kt`, `LSReferences.kt` | `language-server.api.features.jar` | call `withJarUrisRewritten()` on provider results |

## Regenerating for a new cask release

```sh
V=<new version>   # brew info --cask kotlin-lsp
git fetch upstream --tags
git show "kotlin-lsp/v$V:workspace-import/src/com/jetbrains/ls/imports/gradle/IdeaProjectMapper.kt" > scripts/cask-src/IdeaProjectMapper.kt
# re-apply the branch's targetPlatform fix, then for each api.features file:
#   start from the tag's version and re-apply the one-line withJarUrisRewritten() change
# jarUri.kt: copy api.features/src/com/jetbrains/ls/api/features/utils/jarUri.kt
```

Then bump `PINNED_VERSION` and run the script. If the release already contains
these fixes, delete this directory and the script instead.
