// Copyright 2000-2025 JetBrains s.r.o. and contributors. Use of this source code is governed by the Apache 2.0 license.
package com.jetbrains.ls.api.features.utils

import com.jetbrains.lsp.protocol.DocumentUri
import com.jetbrains.lsp.protocol.Location
import com.jetbrains.lsp.protocol.URI
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import java.io.File
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.zip.ZipFile

internal fun Flow<Location>.withJarUrisRewritten(): Flow<Location> =
    map { Location(DocumentUri(rewriteJarUri(it.uri.uri)), it.range) }

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
