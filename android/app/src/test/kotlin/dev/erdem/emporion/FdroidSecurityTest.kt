package dev.erdem.emporion

import kotlinx.serialization.json.JsonObject
import org.fdroid.index.IndexParser
import org.fdroid.index.parseEntry
import org.fdroid.index.v2.EntryVerifier
import org.fdroid.index.v2.IndexV2DiffStreamProcessor
import org.fdroid.index.v2.IndexV2DiffStreamReceiver
import org.fdroid.index.v2.IndexV2FullStreamProcessor
import org.fdroid.index.v2.IndexV2StreamReceiver
import org.fdroid.index.v2.PackageV2
import org.fdroid.index.v2.RepoV2
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.net.URI

class FdroidSecurityTest {
    private val fixtureFingerprint =
        "682ab7f0a26a568e557611da612739286d6dc68cb248031c3ead690cd5111dc5"


    @Test
    fun v2EntryFullAndDiffFixturesVerifySizeHashAndStreamShape() {
        val verified =
            EntryVerifier(fixture("entry.jar"), null, fixtureFingerprint)
                .getStreamAndVerify(IndexParser::parseEntry)
        val entry = verified.second
        assertEquals(20002, entry.version)
        assertEquals(1700000000000, entry.timestamp)

        val full = fixture("index-v2.json")
        FdroidIndexBridge.verifyIndexFile(full, entry.index)
        var fullEnded = false
        IndexV2FullStreamProcessor(
            object : IndexV2StreamReceiver {
                override fun receive(repo: RepoV2, version: Long) = Unit

                override fun receive(
                    packageName: String,
                    p: PackageV2,
                ) = Unit

                override fun onStreamEnded() {
                    fullEnded = true
                }
            },
        ).process(entry.version, full.inputStream()) {}
        assertTrue(fullEnded)

        val diffEntry = entry.getDiff(1690000000000)
            ?: error("Expected deterministic diff entry")
        val diff = fixture("index-v2-diff.json")
        FdroidIndexBridge.verifyIndexFile(diff, diffEntry)
        var diffEnded = false
        IndexV2DiffStreamProcessor(
            object : IndexV2DiffStreamReceiver {
                override fun receiveRepoDiff(
                    version: Long,
                    repoJsonObject: JsonObject,
                ) = Unit

                override fun receivePackageMetadataDiff(
                    packageName: String,
                    packageJsonObject: JsonObject?,
                ) = Unit

                override fun receiveVersionsDiff(
                    packageName: String,
                    versionsDiffMap: Map<String, JsonObject?>?,
                ) = Unit

                override fun onStreamEnded() {
                    diffEnded = true
                }
            },
        ).process(entry.version, diff.inputStream()) {}
        assertTrue(diffEnded)

        val wrongSize = fixture("index-v2.json").apply { appendText("x") }
        assertThrows(SecurityException::class.java) {
            FdroidIndexBridge.verifyIndexFile(wrongSize, entry.index)
        }
        val wrongHash = fixture("index-v2.json").apply {
            val bytes = readBytes()
            bytes[0] = (bytes[0].toInt() xor 1).toByte()
            writeBytes(bytes)
        }
        assertThrows(SecurityException::class.java) {
            FdroidIndexBridge.verifyIndexFile(wrongHash, entry.index)
        }
    }

    @Test
    fun canonicalRepositoryRequiresCredentialFreeHttpsOrigin() {
        assertEquals(
            "https://repo.example/fdroid/repo",
            FdroidIndexBridge
                .canonicalRepositoryUri("https://REPO.example/fdroid/repo/")
                .toString(),
        )
        listOf(
            "http://repo.example/fdroid/repo",
            "https://user:token@repo.example/fdroid/repo",
            "https://repo.example/fdroid/repo?token=secret",
            "https://repo.example/fdroid/repo#fragment",
        ).forEach { value ->
            assertThrows(IllegalArgumentException::class.java) {
                FdroidIndexBridge.canonicalRepositoryUri(value)
            }
        }
    }

    @Test
    fun repositoryFileNamesAreEncodedAsUriPaths() {
        assertEquals(
            "https://repo.example/fdroid/repo/com.example/en-US/API%20Keys%20Tab.jpg",
            FdroidIndexBridge.resolveRepositoryFile(
                URI("https://repo.example/fdroid/repo"),
                "com.example/en-US/API Keys Tab.jpg",
            ).toString(),
        )
    }

    @Test
    fun indexNamesCannotTraverseArchiveBoundaries() {
        assertEquals(
            "diff/1700000000.json",
            FdroidIndexBridge.safeIndexName("diff/1700000000.json"),
        )
        listOf(
            "../index-v2.json",
            "diff/../../index-v2.json",
            "diff\\..\\secret",
            ".",
            "",
            "bad\u0000name",
        ).forEach { value ->
            assertThrows(IllegalArgumentException::class.java) {
                FdroidIndexBridge.safeIndexName(value)
            }
        }
    }

    private fun fixture(name: String): File {
        val file = kotlin.io.path.createTempFile("emporion-", "-$name").toFile()
        javaClass.classLoader!!.getResourceAsStream(name)!!.use { input ->
            file.outputStream().use(input::copyTo)
        }
        return file
    }

}
