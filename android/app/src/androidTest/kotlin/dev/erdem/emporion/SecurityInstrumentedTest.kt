package dev.erdem.emporion

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.os.Build
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.fdroid.index.v1.IndexV1Verifier
import java.security.MessageDigest
import java.io.File
import java.util.jar.JarFile
import java.util.jar.JarOutputStream
import java.util.zip.ZipEntry

@RunWith(AndroidJUnit4::class)
class SecurityInstrumentedTest {
    private val context: Context = ApplicationProvider.getApplicationContext()

    @Test
    fun installedPackageSignerIsAvailableAndNormalized() {
        @Suppress("DEPRECATION")
        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            context.packageManager.getPackageInfo(
                context.packageName,
                PackageManager.GET_SIGNING_CERTIFICATES,
            )
        } else {
            context.packageManager.getPackageInfo(
                context.packageName,
                PackageManager.GET_SIGNATURES,
            )
        }

        val digests = ArtifactVerifierBridge.signerDigests(info)
        assertTrue(digests.getValue("current").isNotEmpty())
        assertTrue(digests.getValue("lineage").isNotEmpty())
        assertTrue(
            digests.values.flatten().all {
                it.matches(Regex("^[A-F0-9]{64}$"))
            },
        )
    }

    @Test
    fun api26SignerFallbackHashesLegacySignatures() {
        @Suppress("DEPRECATION")
        val info = PackageInfo().apply {
            signatures = arrayOf(Signature(byteArrayOf(1, 2, 3, 4)))
        }
        val expected = MessageDigest.getInstance("SHA-256")
            .digest(byteArrayOf(1, 2, 3, 4))
            .joinToString("") { "%02X".format(it.toInt() and 0xff) }

        val digests = ArtifactVerifierBridge.signerDigests(info, 26)

        assertEquals(listOf(expected), digests["current"])
        assertEquals(listOf(expected), digests["lineage"])
    }

    @Test
    fun fdroidRepositoryAndIndexPathsRejectUnsafeInput() {
        assertEquals(
            "https://example.org/fdroid/repo",
            FdroidIndexBridge
                .canonicalRepositoryUri("https://EXAMPLE.org/fdroid/repo/")
                .toString(),
        )
        assertEquals(
            "diff/42.json",
            FdroidIndexBridge.safeIndexName("diff/42.json"),
        )
        assertThrows(IllegalArgumentException::class.java) {
            FdroidIndexBridge.canonicalRepositoryUri("http://example.org/repo")
        }
        assertThrows(IllegalArgumentException::class.java) {
            FdroidIndexBridge.canonicalRepositoryUri("https://token@example.org/repo")
        }
        assertThrows(IllegalArgumentException::class.java) {
            FdroidIndexBridge.canonicalRepositoryUri("https://example.org/repo?key=value")
        }
        assertThrows(IllegalArgumentException::class.java) {
            FdroidIndexBridge.safeIndexName("../index-v2.json")
        }
        assertThrows(IllegalArgumentException::class.java) {
            FdroidIndexBridge.safeIndexName("diff\\..\\secrets")
        }
    }

    @Test
    fun fdroidV1FixtureAcceptsPinnedSignerAndRejectsWrongOrMissingSignatures() {
        val signed = testAsset("index-v1.jar")
        val fingerprint =
            "682ab7f0a26a568e557611da612739286d6dc68cb248031c3ead690cd5111dc5"

        val payload = IndexV1Verifier(signed, null, fingerprint)
            .getStreamAndVerify { stream -> stream.bufferedReader().use { it.readText() } }
            .second
        assertTrue(payload.contains("Emporion Fixture"))

        assertThrows(Exception::class.java) {
            IndexV1Verifier(signed, null, "00".repeat(32))
                .getStreamAndVerify { stream -> stream.readBytes() }
        }

        val unsigned = File(context.cacheDir, "unsigned-index-v1.jar")
        JarFile(signed).use { source ->
            JarOutputStream(unsigned.outputStream()).use { output ->
                val entry = source.getJarEntry("index-v1.json")
                output.putNextEntry(ZipEntry(entry.name))
                source.getInputStream(entry).use { it.copyTo(output) }
                output.closeEntry()
            }
        }
        assertThrows(Exception::class.java) {
            IndexV1Verifier(unsigned, null, fingerprint)
                .getStreamAndVerify { stream -> stream.readBytes() }
        }
    }

    @Test
    fun credentialEnvelopeRoundTripsWithoutPlaintextAndBindsMetadata() {
        val store = CredentialStore(context)
        val accountId = "abcdef0123456789"
        val token = "fixture-token-never-plaintext"
        store.delete(accountId)

        store.put(accountId, "github", "github.com", token)

        assertEquals(token, store.get(accountId, "github", "github.com:443"))
        val envelope = context.noBackupFilesDir
            .resolve("provider-secrets/$accountId.bin")
        assertTrue(envelope.isFile)
        assertFalse(envelope.readText(Charsets.ISO_8859_1).contains(token))
        assertNotEquals(token.toByteArray().toList(), envelope.readBytes().toList())

        assertEquals(null, store.get(accountId, "github", "gitlab.com"))
        assertFalse(envelope.exists())
    }
    @Test
    fun AndroidBackupAdmitsOnlyPortableConfigurationFile() {
        @Suppress("DEPRECATION")
        val applicationInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.packageManager.getApplicationInfo(
                context.packageName,
                PackageManager.ApplicationInfoFlags.of(0),
            )
        } else {
            context.packageManager.getApplicationInfo(context.packageName, 0)
        }
        assertTrue(applicationInfo.flags and ApplicationInfo.FLAG_ALLOW_BACKUP != 0)
        assertEquals(
            setOf(Triple("file", "backup/emporion.json", "include")),
            backupEntries(R.xml.backup_rules),
        )
        assertEquals(
            setOf(Triple("file", "backup/emporion.json", "include")),
            backupEntries(R.xml.data_extraction_rules),
        )
    }

    private fun testAsset(name: String): File {
        val output = File(context.cacheDir, name)
        InstrumentationRegistry.getInstrumentation().context.assets
            .open(name)
            .use { input -> output.outputStream().use(input::copyTo) }
        return output
    }

    private fun backupEntries(resourceId: Int): Set<Triple<String, String, String>> {
        val parser = context.resources.getXml(resourceId)
        val entries = mutableSetOf<Triple<String, String, String>>()
        while (parser.eventType != org.xmlpull.v1.XmlPullParser.END_DOCUMENT) {
            if (parser.eventType == org.xmlpull.v1.XmlPullParser.START_TAG &&
                (parser.name == "include" || parser.name == "exclude")
            ) {
                entries += Triple(
                    parser.getAttributeValue(null, "domain"),
                    parser.getAttributeValue(null, "path"),
                    parser.name,
                )
            }
            parser.next()
        }
        parser.close()
        return entries
    }
}
