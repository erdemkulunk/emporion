package dev.erdem.emporion

import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest
import java.util.Locale

class ArtifactVerifierBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    companion object {
        const val CHANNEL = "dev.erdem.emporion/artifact_verifier"

        @Suppress("DEPRECATION")
        fun signerDigests(
            info: PackageInfo,
            sdkInt: Int = Build.VERSION.SDK_INT,
        ): Map<String, List<String>> {
            val current = if (sdkInt >= Build.VERSION_CODES.P) {
                info.signingInfo?.apkContentsSigners?.toList().orEmpty()
            } else {
                info.signatures?.toList().orEmpty()
            }
            val lineage = if (sdkInt >= Build.VERSION_CODES.P) {
                val signingInfo = info.signingInfo
                if (signingInfo?.hasMultipleSigners() == true) {
                    signingInfo.apkContentsSigners?.toList().orEmpty()
                } else {
                    signingInfo?.signingCertificateHistory?.toList().orEmpty()
                }
            } else {
                info.signatures?.toList().orEmpty()
            }
            return mapOf(
                "current" to current.map(::sha256),
                "lineage" to lineage.map(::sha256),
            )
        }

        private fun sha256(signature: Signature): String = MessageDigest
            .getInstance("SHA-256")
            .digest(signature.toByteArray())
            .joinToString("") { byte ->
                "%02X".format(Locale.ROOT, byte.toInt() and 0xff)
            }
    }

    private val channel = MethodChannel(messenger, CHANNEL)

    init {
        channel.setMethodCallHandler { call, result ->
            try {
                val info = when (call.method) {
                    "archiveSigners" -> {
                        val path = call.argument<String>("path")
                            ?: throw IllegalArgumentException("Missing path")
                        archiveInfo(path)
                    }
                    "installedSigners" -> {
                        val packageName = call.argument<String>("packageName")
                            ?: throw IllegalArgumentException("Missing packageName")
                        installedInfo(packageName)
                    }
                    else -> {
                        result.notImplemented()
                        return@setMethodCallHandler
                    }
                } ?: throw SecurityException("Package signing metadata is unavailable")
                result.success(signerDigests(info))
            } catch (error: IllegalArgumentException) {
                result.error("BAD_ARGS", error.message, null)
            } catch (error: Exception) {
                result.error("VERIFY_FAILED", error.message, null)
            }
        }
    }

    fun close() {
        channel.setMethodCallHandler(null)
    }

    @Suppress("DEPRECATION")
    private fun archiveInfo(path: String): PackageInfo? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            context.packageManager.getPackageArchiveInfo(
                path,
                PackageManager.GET_SIGNING_CERTIFICATES,
            )
        } else {
            context.packageManager.getPackageArchiveInfo(path, PackageManager.GET_SIGNATURES)
        }

    @Suppress("DEPRECATION")
    private fun installedInfo(packageName: String): PackageInfo? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            context.packageManager.getPackageInfo(
                packageName,
                PackageManager.GET_SIGNING_CERTIFICATES,
            )
        } else {
            context.packageManager.getPackageInfo(packageName, PackageManager.GET_SIGNATURES)
        }

}
