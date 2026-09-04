package dev.erdem.emporion

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

class EmporionNativePlugin : FlutterPlugin {
    private var credentialChannel: MethodChannel? = null
    private var fdroidIndexBridge: FdroidIndexBridge? = null
    private var artifactVerifierBridge: ArtifactVerifierBridge? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext
        val messenger = binding.binaryMessenger
        val credentialStore = CredentialStore(context)
        credentialChannel = MethodChannel(messenger, CredentialStore.CHANNEL).also { channel ->
            channel.setMethodCallHandler { call, result ->
                try {
                    val accountId = call.argument<String>("accountId")
                        ?: throw IllegalArgumentException("Missing accountId")
                    when (call.method) {
                        "put" -> {
                            val provider = call.argument<String>("provider")
                                ?: throw IllegalArgumentException("Missing provider")
                            val host = call.argument<String>("host")
                                ?: throw IllegalArgumentException("Missing host")
                            val token = call.argument<String>("token")
                                ?: throw IllegalArgumentException("Missing token")
                            credentialStore.put(accountId, provider, host, token)
                            result.success(null)
                        }
                        "get" -> {
                            val provider = call.argument<String>("provider")
                                ?: throw IllegalArgumentException("Missing provider")
                            val host = call.argument<String>("host")
                                ?: throw IllegalArgumentException("Missing host")
                            result.success(credentialStore.get(accountId, provider, host))
                        }
                        "contains" -> {
                            val provider = call.argument<String>("provider")
                                ?: throw IllegalArgumentException("Missing provider")
                            val host = call.argument<String>("host")
                                ?: throw IllegalArgumentException("Missing host")
                            result.success(credentialStore.contains(accountId, provider, host))
                        }
                        "delete" -> result.success(credentialStore.delete(accountId))
                        else -> result.notImplemented()
                    }
                } catch (error: IllegalArgumentException) {
                    result.error("BAD_ARGS", error.message, null)
                } catch (error: Exception) {
                    result.error("CREDENTIAL_FAILED", error.message, null)
                }
            }
        }
        fdroidIndexBridge = FdroidIndexBridge(context, messenger)
        artifactVerifierBridge = ArtifactVerifierBridge(context, messenger)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        credentialChannel?.setMethodCallHandler(null)
        credentialChannel = null
        fdroidIndexBridge?.close()
        fdroidIndexBridge = null
        artifactVerifierBridge?.close()
        artifactVerifierBridge = null
    }
}
