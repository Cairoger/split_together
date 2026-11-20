import 'dart:async';
import 'dart:convert';
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../data/ledger_backup.dart';

class DriveBackupFile {
  const DriveBackupFile({required this.id, required this.createdAt});

  final String id;
  final DateTime createdAt;
}

class DriveBackupException implements Exception {
  const DriveBackupException(this.message, {this.needsReconnect = false});

  final String message;
  final bool needsReconnect;

  @override
  String toString() => message;
}

abstract interface class DriveBackupGateway {
  bool get isSupported;
  Future<String?> currentAccount();
  Future<String?> connect();
  Future<void> disconnect();
  Future<DateTime?> lastKnownBackup(String account);
  Future<void> rememberLatest(String account, DateTime? date);
  Future<List<DriveBackupFile>> list(String account);
  Future<DriveBackupFile> upload(String account, Uint8List bytes);
  Future<Uint8List> download(String account, String id);
  Future<void> delete(String account, String id);
}

const _invalidResponse = DriveBackupException('無法辨識 Google Drive 的回應，請稍後再試。');
const _changed = DriveBackupException(
  'Google 帳戶已變更，請重新確認帳戶。',
  needsReconnect: true,
);
const _expired = DriveBackupException(
  'Google 授權已到期，請重新連結帳戶。',
  needsReconnect: true,
);
const _network = DriveBackupException('連線中斷或逾時，請檢查網路後再試。');
const _setup = DriveBackupException(
  '無法使用 Google Drive。請確認已啟用 Drive API，並核對 Android OAuth 用戶端、簽章與測試使用者。',
);
const _tooLarge = DriveBackupException('備份超過 32 MiB，無法處理此份備份。');

class AndroidDriveBackupGateway implements DriveBackupGateway {
  const AndroidDriveBackupGateway({this.clientFactory});

  final http.Client Function()? clientFactory;
  static const _channel = MethodChannel('split_together/drive_backup');

  @override
  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<T?> _native<T>(String method, [Map<String, String?>? args]) async {
    if (!isSupported) {
      throw const DriveBackupException('目前僅 Android 支援 Google Drive 備份。');
    }
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      throw const DriveBackupException('此版本未提供 Android 備份服務。');
    } on PlatformException catch (error) {
      throw switch (error.code) {
        'account-changed' => _changed,
        'expired' => _expired,
        'offline' => _network,
        'setup' => _setup,
        'cancelled' => const DriveBackupException('已取消連結 Google 帳戶。'),
        'busy' => const DriveBackupException('正在處理上一個操作，請稍候。'),
        'play-services' => const DriveBackupException(
          '請確認裝置已安裝並更新 Google Play 服務。',
        ),
        _ => const DriveBackupException(
          'Google 帳戶授權失敗，請確認網路、測試帳戶及 OAuth 設定後再試。',
        ),
      };
    }
  }

  @override
  Future<String?> currentAccount() => _native<String>('currentAccount');
  @override
  Future<String?> connect() => _native<String>('connect');
  @override
  Future<void> disconnect() async => _native<void>('disconnect');
  @override
  Future<DateTime?> lastKnownBackup(String account) async {
    final value = await _native<String>('lastKnownBackup', {
      'account': account,
    });
    return value == null ? null : DateTime.tryParse(value);
  }

  @override
  Future<void> rememberLatest(String account, DateTime? date) async =>
      _native<void>('rememberLatest', {
        'account': account,
        'date': date?.toUtc().toIso8601String(),
      });

  Future<T> _withAccount<T>(
    String account,
    Future<T> Function(_DriveSession) action,
  ) async {
    final credentials = await _native<Map<dynamic, dynamic>>('access', {
      'account': account,
    });
    final token = credentials?['token'];
    final package = credentials?['package'];
    if (token is! String || token.isEmpty) throw _expired;
    if (package is! String || !RegExp(r'^[a-zA-Z0-9_.]+$').hasMatch(package)) {
      throw _setup;
    }
    final client = clientFactory?.call() ?? http.Client();
    Future<void> checkAccount() async {
      if (await currentAccount() != account) throw _changed;
    }

    try {
      final result = await action(
        _DriveSession(client, token, package, checkAccount),
      );
      await checkAccount();
      return result;
    } on DriveBackupException catch (error) {
      if (identical(error, _expired)) {
        try {
          await _native<void>('expired', {'account': account, 'token': token});
        } on DriveBackupException {
          // The account may have changed while the old request was in flight.
        }
      }
      rethrow;
    } on TimeoutException {
      throw _network;
    } on http.ClientException {
      throw _network;
    } on FormatException {
      throw _invalidResponse;
    } finally {
      client.close();
    }
  }

  @override
  Future<List<DriveBackupFile>> list(String account) =>
      _withAccount(account, (session) => session.list());

  @override
  Future<DriveBackupFile> upload(String account, Uint8List bytes) =>
      _withAccount(account, (session) => session.upload(bytes));

  @override
  Future<Uint8List> download(String account, String id) =>
      _withAccount(account, (session) => session.download(id));

  @override
  Future<void> delete(String account, String id) =>
      _withAccount(account, (session) => session.delete(id));
}

class _DriveSession {
  _DriveSession(this.client, this.token, this.package, this.checkAccount);

  final http.Client client;
  final String token;
  final String package;
  final Future<void> Function() checkAccount;
  static const host = 'www.googleapis.com';
  static const filesPath = '/drive/v3/files';
  static const uploadPath = '/upload/drive/v3/files';
  static const marker = 'splitTogetherLedger';

  Future<http.StreamedResponse> _send(http.Request request) async {
    await checkAccount();
    request.followRedirects = false;
    request.headers['Authorization'] = 'Bearer $token';
    final response = await client
        .send(request)
        .timeout(const Duration(minutes: 3));
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response;
    }
    if (response.statusCode == 401) throw _expired;
    if (response.statusCode == 403) {
      // Inspect only documented error reasons; raw server messages can contain identifiers.
      final body = utf8.decode(
        await _read(response, limit: 65536),
        allowMalformed: true,
      );
      if (body.contains('"insufficientPermissions"') ||
          body.contains('"ACCESS_TOKEN_SCOPE_INSUFFICIENT"')) {
        throw _expired;
      }
      if (body.contains('"accessNotConfigured"') ||
          body.contains('"SERVICE_DISABLED"')) {
        throw _setup;
      }
      throw const DriveBackupException('Google Drive 拒絕操作。請檢查可用空間、使用限制與帳戶權限。');
    }
    if (response.statusCode == 404) {
      throw const DriveBackupException('找不到該份備份，請重新整理清單。');
    }
    if (response.statusCode == 429 || response.statusCode >= 500) {
      throw const DriveBackupException('Google Drive 暫時無法處理，請稍後重試。');
    }
    throw _invalidResponse;
  }

  Future<Uint8List> _read(
    http.StreamedResponse response, {
    int limit = 1024 * 1024,
  }) async {
    if ((response.contentLength ?? 0) > limit) throw _tooLarge;
    final bytes = BytesBuilder(copy: false);
    await for (final part in response.stream.timeout(
      const Duration(seconds: 45),
    )) {
      if (bytes.length + part.length > limit) throw _tooLarge;
      bytes.add(part);
    }
    return bytes.takeBytes();
  }

  Future<Map<String, dynamic>> _metadata(http.StreamedResponse response) async {
    final value = jsonDecode(utf8.decode(await _read(response)));
    if (value is! Map<String, dynamic>) throw _invalidResponse;
    return value;
  }

  DriveBackupFile _file(Object? value) {
    if (value is! Map ||
        value['id'] is! String ||
        value['createdTime'] is! String) {
      throw _invalidResponse;
    }
    final id = value['id'] as String;
    final time = DateTime.tryParse(value['createdTime'] as String);
    if (!_validId(id) || time == null || !time.isUtc) throw _invalidResponse;
    return DriveBackupFile(id: id, createdAt: time);
  }

  bool _validId(String id) => RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id);

  Future<List<DriveBackupFile>> list() async {
    final result = <DriveBackupFile>[];
    final visited = <String>{};
    String? next;
    do {
      final uri = Uri.https(host, filesPath, {
        'spaces': 'appDataFolder',
        'q':
            "trashed = false and appProperties has { key='$marker' and value='$package' }",
        'fields': 'nextPageToken,incompleteSearch,files(id,createdTime)',
        'orderBy': 'createdTime desc',
        'pageSize': '100',
        'pageToken': ?next,
      });
      final page = await _metadata(await _send(http.Request('GET', uri)));
      final files = page['files'];
      final pageToken = page['nextPageToken'];
      if (page['incompleteSearch'] == true ||
          files is! List ||
          (pageToken != null && pageToken is! String)) {
        throw _invalidResponse;
      }
      result.addAll(files.map(_file));
      next = pageToken as String?;
      if (next != null && !visited.add(next)) throw _invalidResponse;
    } while (next != null);
    return result;
  }

  Future<DriveBackupFile> upload(Uint8List bytes) async {
    if (bytes.length > LedgerBackup.maxBytes) throw _tooLarge;
    final uri = Uri.https(host, uploadPath, {
      'uploadType': 'resumable',
      'fields': 'id,createdTime',
    });
    final start = http.Request('POST', uri)
      ..headers.addAll({
        'Content-Type': 'application/json; charset=UTF-8',
        'X-Upload-Content-Type': 'application/json',
        'X-Upload-Content-Length': bytes.length.toString(),
      })
      ..bodyBytes = utf8.encode(
        jsonEncode({
          'name': 'SplitTogether-ledger.json',
          'mimeType': 'application/json',
          'parents': ['appDataFolder'],
          'appProperties': {marker: package},
        }),
      );
    final response = await _send(start);
    final location = Uri.tryParse(response.headers['location'] ?? '');
    await _read(response);
    if (location == null ||
        location.scheme != 'https' ||
        location.host != host ||
        location.port != 443 ||
        location.userInfo.isNotEmpty ||
        location.path != uploadPath) {
      throw _invalidResponse;
    }
    final upload = http.Request('PUT', location)
      ..headers['Content-Type'] = 'application/json'
      ..bodyBytes = bytes;
    return _file(await _metadata(await _send(upload)));
  }

  Future<void> _checkFile(String id) async {
    if (!_validId(id)) throw _invalidResponse;
    final uri = Uri.https(host, '$filesPath/$id', {
      'fields': 'spaces,appProperties,trashed',
    });
    final value = await _metadata(await _send(http.Request('GET', uri)));
    final spaces = value['spaces'];
    final properties = value['appProperties'];
    if (spaces is! List ||
        !spaces.contains('appDataFolder') ||
        value['trashed'] == true ||
        properties is! Map ||
        properties[marker] != package) {
      throw const DriveBackupException('這份備份不屬於目前的 App 版本。');
    }
  }

  Future<Uint8List> download(String id) async {
    await _checkFile(id);
    final uri = Uri.https(host, '$filesPath/$id', {'alt': 'media'});
    return _read(
      await _send(http.Request('GET', uri)),
      limit: LedgerBackup.maxBytes,
    );
  }

  Future<void> delete(String id) async {
    await _checkFile(id);
    final response = await _send(
      http.Request('DELETE', Uri.https(host, '$filesPath/$id')),
    );
    await _read(response);
  }
}
