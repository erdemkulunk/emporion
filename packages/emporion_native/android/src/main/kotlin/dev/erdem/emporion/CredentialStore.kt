package dev.erdem.emporion

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import java.io.File
import java.security.KeyStore
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Device-local provider token storage. Only opaque encrypted envelopes are
 * written to disk; the AES key never leaves AndroidKeyStore.
 */
class CredentialStore(private val context: Context) {
    companion object {
        const val CHANNEL = "dev.erdem.emporion/credentials"
        private const val KEY_ALIAS = "dev.erdem.emporion.provider-secrets.v1"
        private const val ANDROID_KEY_STORE = "AndroidKeyStore"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val VERSION: Byte = 1
        private const val IV_BYTES = 12
        private const val TAG_BITS = 128
        private val ACCOUNT_ID = Regex("^[a-f0-9]{16}$")
    }

    private val directory: File
        get() = File(context.noBackupFilesDir, "provider-secrets").also { dir ->
            check(dir.exists() || dir.mkdirs()) { "Unable to create credential directory" }
        }

    fun put(accountId: String, provider: String, host: String, token: String) {
        require(token.isNotBlank()) { "Token must not be empty" }
        val target = envelope(accountId)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        cipher.updateAAD(aad(provider, host, accountId))
        val ciphertext = cipher.doFinal(token.toByteArray(Charsets.UTF_8))
        val iv = cipher.iv
        check(iv.size == IV_BYTES) { "Unexpected GCM IV size" }
        val temporary = File(directory, ".${target.name}.${System.nanoTime()}.tmp")
        temporary.outputStream().use { output ->
            output.write(byteArrayOf(VERSION))
            output.write(iv)
            output.write(ciphertext)
            output.fd.sync()
        }
        if (!temporary.renameTo(target)) {
            temporary.copyTo(target, overwrite = true)
            check(temporary.delete()) { "Unable to remove temporary credential envelope" }
        }
    }

    fun get(accountId: String, provider: String, host: String): String? {
        val target = envelope(accountId)
        if (!target.isFile) return null
        return try {
            val payload = target.readBytes()
            require(payload.size > 1 + IV_BYTES + TAG_BITS / 8) { "Credential envelope is truncated" }
            require(payload[0] == VERSION) { "Unsupported credential envelope version" }
            val iv = payload.copyOfRange(1, 1 + IV_BYTES)
            val ciphertext = payload.copyOfRange(1 + IV_BYTES, payload.size)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, existingKey(), GCMParameterSpec(TAG_BITS, iv))
            cipher.updateAAD(aad(provider, host, accountId))
            String(cipher.doFinal(ciphertext), Charsets.UTF_8)
        } catch (_: KeyPermanentlyInvalidatedException) {
            target.delete()
            null
        } catch (_: AEADBadTagException) {
            target.delete()
            null
        } catch (_: IllegalStateException) {
            target.delete()
            null
        } catch (_: IllegalArgumentException) {
            target.delete()
            null
        }
    }

    fun contains(accountId: String, provider: String, host: String): Boolean =
        get(accountId, provider, host) != null

    fun delete(accountId: String): Boolean {
        val target = envelope(accountId)
        return !target.exists() || target.delete()
    }

    private fun envelope(accountId: String): File {
        require(ACCOUNT_ID.matches(accountId)) { "Invalid account ID" }
        return File(directory, "$accountId.bin")
    }

    private fun aad(provider: String, host: String, accountId: String): ByteArray {
        val canonicalProvider = provider.trim().lowercase()
        val canonicalHost = host.trim().lowercase().removeSuffix(":443")
        require(canonicalProvider.isNotEmpty() && canonicalHost.isNotEmpty()) {
            "Provider and host are required"
        }
        return "v1|$canonicalProvider|$canonicalHost|$accountId".toByteArray(Charsets.UTF_8)
    }

    private fun getOrCreateKey(): SecretKey {
        existingKeyOrNull()?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEY_STORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .setUserAuthenticationRequired(false)
                .build(),
        )
        return generator.generateKey()
    }

    private fun existingKey(): SecretKey =
        existingKeyOrNull() ?: throw IllegalStateException("Credential key is unavailable")

    private fun existingKeyOrNull(): SecretKey? {
        val keyStore = KeyStore.getInstance(ANDROID_KEY_STORE).apply { load(null) }
        return keyStore.getKey(KEY_ALIAS, null) as? SecretKey
    }
}
