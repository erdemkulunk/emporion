package dev.erdem.emporion

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.serialization.json.JsonObject
import org.fdroid.index.IndexParser
import org.fdroid.index.parseEntry
import org.fdroid.index.v1.IndexV1StreamProcessor
import org.fdroid.index.v1.IndexV1StreamReceiver
import org.fdroid.index.v1.IndexV1Verifier
import org.fdroid.index.v2.AntiFeatureV2
import org.fdroid.index.v2.CategoryV2
import org.fdroid.index.v2.EntryFileV2
import org.fdroid.index.v2.EntryVerifier
import org.fdroid.index.v2.IndexV2DiffStreamProcessor
import org.fdroid.index.v2.IndexV2DiffStreamReceiver
import org.fdroid.index.v2.IndexV2FullStreamProcessor
import org.fdroid.index.v2.IndexV2StreamReceiver
import org.fdroid.index.v2.MetadataV2
import org.fdroid.index.v2.PackageV2
import org.fdroid.index.v2.PackageVersionV2
import org.fdroid.index.v2.ReleaseChannelV2
import org.fdroid.index.v2.RepoV2
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.security.MessageDigest
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

class FdroidIndexBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    companion object {
        const val CHANNEL = "dev.erdem.emporion/fdroid_index"
        private const val MAX_REDIRECTS = 5
        private const val BATCH_SIZE = 100

        fun canonicalRepositoryUri(value: String): URI {
            val uri = URI(value).normalize()
            require(uri.scheme.equals("https", ignoreCase = true)) {
                "F-Droid repository must use HTTPS"
            }
            require(
                uri.host != null &&
                    uri.userInfo == null &&
                    uri.query == null &&
                    uri.fragment == null,
            ) {
                "Invalid F-Droid repository URL"
            }
            return URI(
                "https",
                null,
                uri.host.lowercase(Locale.ROOT),
                effectivePort(uri),
                uri.path.trimEnd('/'),
                null,
                null,
            )
        }

        fun safeIndexName(name: String): String {
            val normalized = name.replace('\\', '/')
            require(!normalized.contains('\u0000')) { "Index path contains NUL" }
            val segments = normalized.split('/').filter { it.isNotEmpty() }
            require(
                segments.isNotEmpty() &&
                    segments.none { it == "." || it == ".." },
            ) {
                "Unsafe index path"
            }
            return segments.joinToString("/")
        }

        fun resolveRepositoryFile(base: URI, name: String): URI =
            URI(
                base.scheme,
                null,
                base.host,
                effectivePort(base),
                "${base.path.trimEnd('/')}/${safeIndexName(name)}",
                null,
                null,
            )

        private fun effectivePort(uri: URI): Int = when {
            uri.port >= 0 -> uri.port
            uri.scheme.equals("https", true) -> -1
            else -> uri.port
        }

        fun verifyIndexFile(file: File, expected: EntryFileV2) {
            if (file.length() != expected.size) {
                throw SecurityException("Index size mismatch")
            }
            val actual = FileInputStream(file).use { input ->
                val digest = MessageDigest.getInstance("SHA-256")
                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    digest.update(buffer, 0, read)
                }
                digest.digest().joinToString("") { "%02x".format(it) }
            }
            if (!actual.equals(expected.sha256, ignoreCase = true)) {
                throw SecurityException("Index SHA-256 mismatch")
            }
        }

        fun normalizeFingerprint(value: String): String {
            val normalized =
                value.filter { it.isLetterOrDigit() }.lowercase(Locale.ROOT)
            require(normalized.matches(Regex("[0-9a-f]{64}"))) {
                "Fingerprint must be a SHA-256 value"
            }
            return normalized
        }
    }

    private val channel = MethodChannel(messenger, CHANNEL)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()

    init {
        channel.setMethodCallHandler(::handle)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "sync") {
            result.notImplemented()
            return
        }
        val repositoryId = call.argument<String>("repositoryId")
        val repositoryUrl = call.argument<String>("repositoryUrl")
        val fingerprint = call.argument<String>("fingerprint")
        val locale = call.argument<String>("locale") ?: "en-US"
        val generation = call.argument<String>("generation")
        val lastTimestamp = call.argument<Number>("lastTimestamp")?.toLong() ?: 0L
        val allowDiff = call.argument<Boolean>("allowDiff") == true
        if (repositoryId.isNullOrBlank() || repositoryUrl.isNullOrBlank() || fingerprint.isNullOrBlank() || generation.isNullOrBlank()) {
            result.error("invalid_arguments", "Repository ID, URL, fingerprint, and generation are required", null)
            return
        }
        executor.execute {
            try {
                val value = sync(
                    repositoryId = repositoryId,
                    repositoryUrl = repositoryUrl,
                    expectedFingerprint = normalizeFingerprint(fingerprint),
                    locale = locale,
                    generation = generation,
                    lastTimestamp = lastTimestamp,
                    allowDiff = allowDiff,
                )
                mainHandler.post { result.success(value) }
            } catch (error: Throwable) {
                val message = error.message ?: error.javaClass.simpleName
                mainHandler.post { result.error("fdroid_verification_failed", message, null) }
            }
        }
    }

    private fun sync(
        repositoryId: String,
        repositoryUrl: String,
        expectedFingerprint: String,
        locale: String,
        generation: String,
        lastTimestamp: Long,
        allowDiff: Boolean,
    ): Map<String, Any?> {
        val base = canonicalRepositoryUri(repositoryUrl)
        val workDir = File(context.cacheDir, "fdroid-index/$repositoryId/$generation").apply { mkdirs() }
        try {
            val entryJar = File(workDir, "entry.jar")
            val hasV2 = try {
                downloadSameOrigin(base.resolve("${base.path.trimEnd('/')}/entry.jar"), entryJar)
                true
            } catch (error: HttpStatusException) {
                if (error.statusCode == HttpURLConnection.HTTP_NOT_FOUND) false else throw error
            }
            return if (hasV2) {
                syncV2(base, entryJar, workDir, repositoryId, expectedFingerprint, locale, generation, lastTimestamp, allowDiff)
            } else {
                syncV1(base, workDir, repositoryId, expectedFingerprint, locale, generation, lastTimestamp)
            }
        } finally {
            workDir.deleteRecursively()
        }
    }

    private fun syncV2(
        base: URI,
        entryJar: File,
        workDir: File,
        repositoryId: String,
        expectedFingerprint: String,
        locale: String,
        generation: String,
        lastTimestamp: Long,
        allowDiff: Boolean,
    ): Map<String, Any?> {
        val verified = EntryVerifier(entryJar, null, expectedFingerprint).getStreamAndVerify { stream ->
            IndexParser.parseEntry(stream)
        }
        val certificate = verified.first
        val entry = verified.second
        if (entry.timestamp < lastTimestamp) throw SecurityException("Index timestamp is older than the last accepted generation")
        val diff = if (allowDiff && lastTimestamp > 0L) entry.getDiff(lastTimestamp) else null
        val selected = diff ?: entry.index
        val indexFile = File(workDir, safeIndexName(selected.name))
        downloadSameOrigin(resolveIndex(base, selected), indexFile)
        verifyIndexFile(indexFile, selected)

        val repo = AtomicReference<Map<String, Any?>?>(null)
        if (diff == null) {
            val receiver = V2Receiver(repositoryId, base, locale, generation, entry.timestamp, repo)
            FileInputStream(indexFile).use { input ->
                IndexV2FullStreamProcessor(receiver).process(entry.version, input) { }
            }
            receiver.flush()
        } else {
            val receiver = DiffReceiver(repositoryId, generation, entry.timestamp, repo)
            FileInputStream(indexFile).use { input ->
                IndexV2DiffStreamProcessor(receiver).process(entry.version, input) { }
            }
            receiver.flush()
        }
        return mapOf(
            "format" to if (diff == null) "v2-full" else "v2-diff",
            "timestamp" to entry.timestamp,
            "version" to entry.version,
            "certificate" to certificate.uppercase(Locale.ROOT),
            "fingerprint" to fingerprintOfCertificate(certificate),
            "repository" to repo.get(),
        )
    }

    private fun syncV1(
        base: URI,
        workDir: File,
        repositoryId: String,
        expectedFingerprint: String,
        locale: String,
        generation: String,
        lastTimestamp: Long,
    ): Map<String, Any?> {
        val jar = File(workDir, "index-v1.jar")
        downloadSameOrigin(base.resolve("${base.path.trimEnd('/')}/index-v1.jar"), jar)
        val receiver = V1Receiver(repositoryId, base, locale, generation)
        val verified = IndexV1Verifier(jar, null, expectedFingerprint).getStreamAndVerify { stream ->
            IndexV1StreamProcessor(receiver, lastTimestamp, locale).process(stream)
        }
        receiver.flush()
        return mapOf(
            "format" to "v1",
            "timestamp" to receiver.timestamp,
            "version" to receiver.version,
            "certificate" to verified.first.uppercase(Locale.ROOT),
            "fingerprint" to fingerprintOfCertificate(verified.first),
            "repository" to receiver.repository,
        )
    }

    private inner class V2Receiver(
        private val repositoryId: String,
        private val base: URI,
        private val locale: String,
        private val generation: String,
        private val timestamp: Long,
        private val repository: AtomicReference<Map<String, Any?>?>,
    ) : IndexV2StreamReceiver {
        private val batch = ArrayList<Map<String, Any?>>(BATCH_SIZE)

        override fun receive(repo: RepoV2, version: Long) {
            repository.set(normalizeRepository(repo, version))
        }

        override fun receive(packageName: String, p: PackageV2) {
            batch.addAll(normalizePackage(repositoryId, base, locale, generation, timestamp, packageName, p.metadata, p.versions))
            if (batch.size >= BATCH_SIZE) flush()
        }

        override fun onStreamEnded() = flush()

        fun flush() {
            while (batch.isNotEmpty()) {
                val count = minOf(BATCH_SIZE, batch.size)
                val outgoing = ArrayList(batch.subList(0, count))
                batch.subList(0, count).clear()
                invokeDartBlocking("fdroidBatch", mapOf("repositoryId" to repositoryId, "generation" to generation, "packages" to outgoing))
            }
        }
    }

    private inner class V1Receiver(
        private val repositoryId: String,
        private val base: URI,
        private val locale: String,
        private val generation: String,
    ) : IndexV1StreamReceiver {
        private val metadata = LinkedHashMap<String, MetadataV2>()
        private val versions = LinkedHashMap<String, Map<String, PackageVersionV2>>()
        var repository: Map<String, Any?>? = null
            private set
        var timestamp: Long = 0L
            private set
        var version: Long = 1L
            private set

        override fun receive(repo: RepoV2, version: Long) {
            this.timestamp = repo.timestamp
            this.version = version
            repository = normalizeRepository(repo, version)
        }

        override fun receive(packageName: String, m: MetadataV2) {
            metadata[packageName] = m
        }

        override fun receive(packageName: String, v: Map<String, PackageVersionV2>) {
            versions[packageName] = v
        }

        override fun updateRepo(
            antiFeatures: Map<String, AntiFeatureV2>,
            categories: Map<String, CategoryV2>,
            releaseChannels: Map<String, ReleaseChannelV2>,
        ) = Unit

        override fun updateAppMetadata(packageName: String, preferredSigner: String?) = Unit

        fun flush() {
            val batch = ArrayList<Map<String, Any?>>(BATCH_SIZE)
            metadata.forEach { (packageName, packageMetadata) ->
                batch.addAll(normalizePackage(repositoryId, base, locale, generation, timestamp, packageName, packageMetadata, versions[packageName].orEmpty()))
                while (batch.size >= BATCH_SIZE) {
                    val outgoing = ArrayList(batch.subList(0, BATCH_SIZE))
                    batch.subList(0, BATCH_SIZE).clear()
                    invokeDartBlocking("fdroidBatch", mapOf("repositoryId" to repositoryId, "generation" to generation, "packages" to outgoing))
                }
            }
            if (batch.isNotEmpty()) invokeDartBlocking("fdroidBatch", mapOf("repositoryId" to repositoryId, "generation" to generation, "packages" to batch))
        }
    }

    private inner class DiffReceiver(
        private val repositoryId: String,
        private val generation: String,
        private val timestamp: Long,
        private val repository: AtomicReference<Map<String, Any?>?>,
    ) : IndexV2DiffStreamReceiver {
        private val operations = ArrayList<Map<String, Any?>>(BATCH_SIZE)

        override fun receiveRepoDiff(version: Long, repoJsonObject: JsonObject) {
            repository.set(mapOf("version" to version, "diff" to repoJsonObject.toString()))
        }

        override fun receivePackageMetadataDiff(packageName: String, packageJsonObject: JsonObject?) {
            operations.add(mapOf("packageName" to packageName, "metadata" to packageJsonObject?.toString()))
            if (operations.size >= BATCH_SIZE) flush()
        }

        override fun receiveVersionsDiff(packageName: String, versionsDiffMap: Map<String, JsonObject?>?) {
            operations.add(mapOf("packageName" to packageName, "versions" to versionsDiffMap?.mapValues { it.value?.toString() }))
            if (operations.size >= BATCH_SIZE) flush()
        }

        override fun onStreamEnded() = flush()

        fun flush() {
            while (operations.isNotEmpty()) {
                val count = minOf(BATCH_SIZE, operations.size)
                val outgoing = ArrayList(operations.subList(0, count))
                operations.subList(0, count).clear()
                invokeDartBlocking("fdroidDiffBatch", mapOf("repositoryId" to repositoryId, "generation" to generation, "timestamp" to timestamp, "operations" to outgoing))
            }
        }
    }

    private fun normalizePackage(
        repositoryId: String,
        base: URI,
        locale: String,
        generation: String,
        timestamp: Long,
        packageName: String,
        metadata: MetadataV2,
        versions: Map<String, PackageVersionV2>,
    ): List<Map<String, Any?>> {
        val grouped = versions.values.groupBy { version ->
            version.signer?.sha256?.firstOrNull()?.uppercase(Locale.ROOT)
                ?: metadata.preferredSigner?.uppercase(Locale.ROOT)
                ?: "UNKNOWN"
        }
        return grouped.map { (signer, signerVersions) ->
            val normalizedVersions = signerVersions.map { version ->
                mapOf(
                    "repositoryId" to repositoryId,
                    "packageName" to packageName,
                    "versionName" to version.versionName,
                    "versionCode" to version.versionCode,
                    "apkUrl" to resolveAsset(base, version.file.name).toString(),
                    "sha256" to version.file.sha256.uppercase(Locale.ROOT),
                    "size" to (version.file.size ?: 0L),
                    "signerSha256" to signer,
                    "minSdk" to version.manifest.minSdkVersion,
                    "maxSdk" to version.manifest.maxSdkVersion,
                    "abis" to version.manifest.nativecode,
                    "densities" to emptyList<String>(),
                    "languages" to emptyList<String>(),
                    "releaseChannel" to (version.releaseChannels.firstOrNull() ?: "stable"),
                    "addedAt" to version.added,
                )
            }.sortedByDescending { (it["versionCode"] as Long) }
            val antiFeatures = signerVersions.flatMap { it.antiFeatures.keys }.distinct()
            mapOf(
                "repositoryId" to repositoryId,
                "packageName" to packageName,
                "signerSha256" to signer,
                "name" to localized(metadata.name, locale, packageName),
                "summary" to localizedOrNull(metadata.summary, locale),
                "description" to localizedOrNull(metadata.description, locale),
                "categories" to metadata.categories,
                "license" to metadata.license,
                "antiFeatures" to antiFeatures,
                "sourceCodeUrl" to metadata.sourceCode,
                "issueTrackerUrl" to metadata.issueTracker,
                "iconUrl" to localizedFile(metadata.icon, locale)?.let { resolveAsset(base, it) }?.toString(),
                "screenshots" to metadata.screenshots?.phone?.let { files -> localizedFileList(files, locale).map { resolveAsset(base, it).toString() } }.orEmpty(),
                "versions" to normalizedVersions,
                "observedAt" to timestamp,
                "generation" to generation,
            )
        }
    }

    private fun normalizeRepository(repo: RepoV2, version: Long): Map<String, Any?> = mapOf(
        "name" to localized(repo.name, "en-US", "F-Droid repository"),
        "address" to repo.address,
        "mirrors" to repo.mirrors.map { it.url },
        "timestamp" to repo.timestamp,
        "version" to version,
    )

    private fun localized(values: Map<String, String>?, locale: String, fallback: String): String =
        localizedOrNull(values, locale) ?: fallback

    private fun localizedOrNull(values: Map<String, String>?, locale: String): String? {
        if (values.isNullOrEmpty()) return null
        val language = locale.substringBefore('-').substringBefore('_')
        return values[locale] ?: values[locale.replace('_', '-')] ?: values[language] ?: values["en-US"] ?: values["en"] ?: values.values.firstOrNull()
    }

    private fun localizedFile(values: Map<String, org.fdroid.index.v2.FileV2>?, locale: String): String? {
        if (values.isNullOrEmpty()) return null
        val language = locale.substringBefore('-').substringBefore('_')
        return (values[locale] ?: values[language] ?: values["en-US"] ?: values["en"] ?: values.values.firstOrNull())?.name
    }

    private fun localizedFileList(values: Map<String, List<org.fdroid.index.v2.FileV2>>, locale: String): List<String> {
        val language = locale.substringBefore('-').substringBefore('_')
        return (values[locale] ?: values[language] ?: values["en-US"] ?: values["en"] ?: values.values.firstOrNull()).orEmpty().map { it.name }
    }

    private fun invokeDartBlocking(method: String, arguments: Map<String, Any?>) {
        val latch = CountDownLatch(1)
        val failure = AtomicReference<String?>(null)
        mainHandler.post {
            channel.invokeMethod(method, arguments, object : MethodChannel.Result {
                override fun success(result: Any?) = latch.countDown()
                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                    failure.set("$errorCode: ${errorMessage ?: "Dart rejected index batch"}")
                    latch.countDown()
                }
                override fun notImplemented() {
                    failure.set("Dart index batch handler is not implemented")
                    latch.countDown()
                }
            })
        }
        if (!latch.await(60, TimeUnit.SECONDS)) throw IOException("Timed out waiting for index batch persistence")
        failure.get()?.let { throw IOException(it) }
    }


    private fun resolveIndex(base: URI, file: EntryFileV2): URI = resolveRepositoryFile(base, file.name)

    private fun resolveAsset(base: URI, name: String): URI = resolveRepositoryFile(base, name)


    private fun downloadSameOrigin(uri: URI, destination: File) {
        var current = uri
        val origin = origin(uri)
        repeat(MAX_REDIRECTS + 1) { redirectCount ->
            require(current.scheme.equals("https", ignoreCase = true)) { "HTTPS downgrade rejected" }
            require(origin(current) == origin) { "Cross-origin F-Droid redirect rejected" }
            val connection = URL(current.toString()).openConnection() as HttpURLConnection
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 20_000
            connection.readTimeout = 60_000
            connection.setRequestProperty("Accept-Encoding", "identity")
            try {
                val code = connection.responseCode
                if (code in 300..399) {
                    if (redirectCount == MAX_REDIRECTS) throw IOException("Too many redirects")
                    val location = connection.getHeaderField("Location") ?: throw IOException("Redirect missing Location")
                    current = current.resolve(location)
                    return@repeat
                }
                if (code !in 200..299) throw HttpStatusException(code)
                destination.parentFile?.mkdirs()
                FileOutputStream(destination).use { output -> connection.inputStream.use { it.copyTo(output) } }
                return
            } finally {
                connection.disconnect()
            }
        }
        throw IOException("Too many redirects")
    }


    fun close() {
        channel.setMethodCallHandler(null)
        executor.shutdownNow()
    }

    private fun fingerprintOfCertificate(certificateHex: String): String {
        val bytes = certificateHex.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        return MessageDigest.getInstance("SHA-256").digest(bytes).toHex().uppercase(Locale.ROOT)
    }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }


    private fun origin(uri: URI): String = "${uri.scheme.lowercase(Locale.ROOT)}://${uri.host.lowercase(Locale.ROOT)}:${if (uri.port >= 0) uri.port else 443}"

    private class HttpStatusException(val statusCode: Int) : IOException("F-Droid HTTP $statusCode")
}
