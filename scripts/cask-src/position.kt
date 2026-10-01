// CASK-PINNED COPY — compiled by scripts/setup-helix.sh against the Homebrew
// kotlin-lsp cask's bundled jars (currently 262.4739.0). See the header in
// cask-src/IdeaProjectMapper.kt for why these copies exist.
//
// Snapshot of features-impl/common/src/.../utils/position.kt as of the cask
// release (upstream later moved these helpers into closed-source core; on the
// branch the fix lives in api.features/src/.../utils/jarUri.kt). Carries this
// branch's fix: jar:// → file:// URI rewriting for goto-def.
// Copyright 2000-2025 JetBrains s.r.o. and contributors. Use of this source code is governed by the Apache 2.0 license.
package com.jetbrains.ls.api.features.impl.common.utils

import com.intellij.openapi.editor.Document
import com.intellij.openapi.util.TextRange
import com.intellij.openapi.vfs.VirtualFile
import com.intellij.openapi.vfs.findDocument
import com.intellij.psi.PsiElement
import com.intellij.psi.PsiNameIdentifierOwner
import com.jetbrains.ls.api.core.util.toLspRange
import com.jetbrains.ls.api.core.util.uri
import com.jetbrains.lsp.protocol.DocumentUri
import com.jetbrains.lsp.protocol.Location
import com.jetbrains.lsp.protocol.URI
import java.io.File
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.zip.ZipFile

internal fun TextRange.toLspLocation(file: VirtualFile, document: Document): Location {
    return Location(DocumentUri(rewriteJarUri(file.uri)), toLspRange(document))
}

/**
 * Returns a `file://` URI that points at the contents of [uri] when [uri] uses the
 * `jar://` scheme; returns [uri] unchanged otherwise.
 *
 * Generic LSP clients (Helix, plain Neovim, Sublime LSP, Zed) drop URIs whose scheme
 * isn't `file://`, so goto-definition into library code silently fails for them.
 * This helper extracts the requested entry into a content-addressed cache so the
 * same response can be served as a regular file. Failures fall through to the
 * original URI.
 *
 * Cache key is SHA-1 of `(jarPath, size, mtime)` — extractions are reused across
 * runs and invalidated when the jar changes.
 */
fun rewriteJarUri(uri: URI): URI {
    val s = uri.uri
    if (!s.startsWith("jar:")) return uri
    return runCatching {
        val raw = s.removePrefix("jar:").removePrefix("//").removePrefix("file://")
        val splitIdx = raw.indexOf("!/")
        if (splitIdx < 0) return@runCatching uri
        val rawJarPath = raw.substring(0, splitIdx)
        val entryPath = raw.substring(splitIdx + 2).removePrefix("/")
        val jarPath = when {
            rawJarPath.startsWith("/") -> rawJarPath
            rawJarPath.startsWith("localhost/") -> "/" + rawJarPath.removePrefix("localhost/")
            else -> "/$rawJarPath"
        }
        val jarFile = File(jarPath)
        if (!jarFile.isFile) return@runCatching uri

        val md = MessageDigest.getInstance("SHA-1").apply {
            update(jarPath.toByteArray())
            update(jarFile.length().toString().toByteArray())
            update(jarFile.lastModified().toString().toByteArray())
        }
        val key = md.digest().joinToString("") { "%02x".format(it) }
        val dest: Path = jarExtractCacheRoot.resolve(key).resolve(jarFile.name).resolve(entryPath)
        if (!Files.exists(dest)) {
            Files.createDirectories(dest.parent)
            ZipFile(jarFile).use { zip ->
                val entry = zip.getEntry(entryPath) ?: return@runCatching uri
                zip.getInputStream(entry).use { input ->
                    Files.copy(input, dest, StandardCopyOption.REPLACE_EXISTING)
                }
            }
        }
        URI(dest.toUri().toString())
    }.getOrDefault(uri)
}

private val jarExtractCacheRoot: Path by lazy {
    Path.of(System.getProperty("user.home"), ".cache", "kotlin-lsp-extracted")
        .also { Files.createDirectories(it) }
}

fun PsiElement.getLspLocation(): Location? {
    val textRange = textRange ?: return null
    val virtualFile = containingFile?.virtualFile ?: return null
    val document = virtualFile.findDocument() ?: return null
    return textRange.toLspLocation(virtualFile, document)
}

fun PsiElement.getLspLocationForDefinition(): Location? {
    val navigationElement = getNavigationElement()
    if (navigationElement != null && navigationElement != this) {
        return navigationElement.getLspLocationForDefinition()
    }
    (this as? PsiNameIdentifierOwner)?.nameIdentifier?.getLspLocation()?.let { return it }
    return getLspLocation()
}