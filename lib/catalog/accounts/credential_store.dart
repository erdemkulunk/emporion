import 'package:flutter/services.dart';
import 'package:obtainium/catalog/models.dart';
import 'package:obtainium/catalog/network/provider_http_client.dart';

class CredentialStore implements CredentialReader {
  static const MethodChannel _channel = MethodChannel(
    'dev.erdem.emporion/credentials',
  );

  const CredentialStore();

  Map<String, Object?> _identity(ProviderAccount account) => {
    'accountId': account.id,
    'provider': account.provider.name,
    'host': canonicalHost(account.apiBaseUrl),
  };

  Future<void> put(ProviderAccount account, String token) async {
    if (token.trim().isEmpty) {
      throw const FormatException('Token must not be empty');
    }
    await _channel.invokeMethod<void>('put', {
      ..._identity(account),
      'token': token,
    });
  }

  @override
  Future<String?> get(ProviderAccount account) =>
      _channel.invokeMethod<String>('get', _identity(account));

  Future<String?> getByIdentity({
    required String accountId,
    required ProviderKind provider,
    required String host,
  }) => _channel.invokeMethod<String>('get', {
    'accountId': accountId,
    'provider': provider.name,
    'host': canonicalHost(host),
  });

  Future<bool> contains(ProviderAccount account) async =>
      await _channel.invokeMethod<bool>('contains', _identity(account)) ??
      false;

  Future<void> delete(String accountId) async {
    await _channel.invokeMethod<bool>('delete', {'accountId': accountId});
  }
}
