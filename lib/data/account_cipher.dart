import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Only encrypted account numbers reach SQLite. Keys are read on demand,
/// and a missing key is created only for an installation with no ciphertext.
class AccountCipher {
  AccountCipher({Future<SecretKey> Function(bool create)? loadKey})
    : _loadKey = loadKey ?? _deviceKey;

  static final _aes = AesGcm.with256bits();
  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.unlocked_this_device,
    ),
  );
  static const _keyName = 'friend_accounts_aes256_v1';
  final Future<SecretKey> Function(bool create) _loadKey;

  static Future<SecretKey> _deviceKey(bool create) async {
    final existing = await _storage.read(key: _keyName);
    if (existing != null) {
      final raw = base64Decode(existing);
      if (raw.length != 32) throw const FormatException('無法讀取裝置金鑰');
      return SecretKey(raw);
    }
    if (!create) throw StateError('裝置金鑰不存在');
    final key = await _aes.newSecretKey();
    final encoded = base64Encode(await key.extractBytes());
    await _storage.write(key: _keyName, value: encoded);
    if (await _storage.read(key: _keyName) != encoded) {
      throw StateError('無法儲存裝置金鑰');
    }
    return key;
  }

  Future<Uint8List> encrypt(
    String id,
    String code,
    String number, {
    required bool canCreateKey,
  }) async {
    try {
      final box = await _aes.encrypt(
        utf8.encode(number),
        secretKey: await _loadKey(canCreateKey),
        aad: utf8.encode('$id:$code'),
      );
      return Uint8List.fromList(box.concatenation());
    } catch (_) {
      throw const FormatException('無法加密收款帳號，請確認裝置已解鎖後重試');
    }
  }

  Future<String> decrypt(String id, String code, Uint8List encrypted) async {
    try {
      final box = SecretBox.fromConcatenation(
        encrypted,
        nonceLength: _aes.nonceLength,
        macLength: _aes.macAlgorithm.macLength,
      );
      final clear = await _aes.decrypt(
        box,
        secretKey: await _loadKey(false),
        aad: utf8.encode('$id:$code'),
      );
      return utf8.decode(clear);
    } catch (_) {
      throw const FormatException('無法解密收款帳號，請確認裝置已解鎖後重試');
    }
  }
}
