import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:split_together/data/ledger_backup.dart';
import 'package:split_together/services/drive_backup_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('split_together/drive_backup');
  const production = 'com.example.split_together';
  const preview = 'com.example.split_together.preview';
  const accountA = 'a@example.invalid';
  const accountB = 'b@example.invalid';
  const stamp = '2026-11-18T01:23:45.000Z';
  late String? linked;
  late String package;
  late List<String> nativeCalls;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    linked = accountA;
    package = production;
    nativeCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          nativeCalls.add(call.method);
          if (call.method == 'currentAccount') return linked;
          if (call.arguments['account'] != linked) {
            throw PlatformException(code: 'account-changed');
          }
          if (call.method == 'access') {
            return {'token': 'test-fixture', 'package': package};
          }
          if (call.method == 'expired') {
            linked = null;
            return null;
          }
          throw StateError('未預期的呼叫');
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  AndroidDriveBackupGateway gateway(MockClientHandler handler) =>
      AndroidDriveBackupGateway(clientFactory: () => MockClient(handler));

  test('列出所有分頁，全程限該版本的 appDataFolder', () async {
    package = preview;
    final pages = <String?>[];
    final drive = gateway((req) async {
      final params = req.url.queryParameters;
      expect(req.method, 'GET');
      expect(req.url.host, 'www.googleapis.com');
      expect(req.url.path, '/drive/v3/files');
      expect(params['spaces'], 'appDataFolder');
      expect(
        params['q'],
        "trashed = false and appProperties has { key='splitTogetherLedger' and value='$preview' }",
      );
      expect(req.headers['Authorization'], 'Bearer test-fixture');
      final page = params['pageToken'];
      pages.add(page);
      return http.Response(
        jsonEncode({
          if (page == null) 'nextPageToken': 'next',
          'files': [
            {'id': page == null ? 'file1' : 'file2', 'createdTime': stamp},
          ],
        }),
        200,
      );
    });
    expect((await drive.list(accountA)).map((f) => f.id), ['file1', 'file2']);
    expect(pages, [null, 'next']);
  });

  test('上傳先建立版本專屬工作階段，傳完原始位元組才取得成功日期', () async {
    final sent = <String>[];
    final bytes = Uint8List.fromList(utf8.encode('虛構備份'));
    final drive = gateway((req) async {
      sent.add(req.method);
      expect(req.url.scheme, 'https');
      if (req.method == 'POST') {
        final metadata = jsonDecode(req.body);
        expect(req.url.queryParameters['uploadType'], 'resumable');
        expect(metadata['parents'], ['appDataFolder']);
        expect(metadata['appProperties'], {'splitTogetherLedger': production});
        expect(req.headers['X-Upload-Content-Length'], bytes.length.toString());
        return http.Response(
          '',
          200,
          headers: {
            'location': 'https://www.googleapis.com/upload/drive/v3/files?upload_id=example',
          },
        );
      }
      expect(req.url.queryParameters['upload_id'], 'example');
      expect(req.bodyBytes, bytes);
      return http.Response(
        jsonEncode({'id': 'saved', 'createdTime': stamp}),
        201,
      );
    });
    final saved = await drive.upload(accountA, bytes);
    expect(saved.id, 'saved');
    expect(saved.createdAt, DateTime.parse(stamp));
    expect(sent, ['POST', 'PUT']);
  });

  test('不把權杖或內容傳到外部上傳網址', () async {
    var calls = 0;
    final drive = gateway((req) async {
      calls++;
      expect(req.url.host, 'www.googleapis.com');
      return http.Response(
        '',
        200,
        headers: {'location': 'https://other.invalid/upload/drive/v3/files'},
      );
    });
    await expectLater(
      drive.upload(accountA, Uint8List(2)),
      throwsA(isA<DriveBackupException>()),
    );
    expect(calls, 1);
  });

  test('跨版本的檔案 ID 無法下載內容或刪除', () async {
    final methods = <String>[];
    final drive = gateway((req) async {
      methods.add(req.method);
      expect(req.url.queryParameters.containsKey('alt'), isFalse);
      return http.Response(
        jsonEncode({
          'spaces': ['appDataFolder'],
          'appProperties': {'splitTogetherLedger': preview},
        }),
        200,
      );
    });
    await expectLater(
      drive.download(accountA, 'other'),
      throwsA(isA<DriveBackupException>()),
    );
    await expectLater(
      drive.delete(accountA, 'other'),
      throwsA(isA<DriveBackupException>()),
    );
    expect(methods, ['GET', 'GET']);
  });

  test('授權失效清除本機連結並使用固定錯誤提示', () async {
    final drive = gateway(
      (req) async => http.Response('EXAMPLE_SENSITIVE_SERVER_DETAILS', 401),
    );
    await expectLater(
      drive.list(accountA),
      throwsA(
        isA<DriveBackupException>()
            .having((e) => e.needsReconnect, '需重新連結', true)
            .having((e) => e.message, '不回傳伺服器原文', isNot(contains('SENSITIVE'))),
      ),
    );
    expect(linked, isNull);
    expect(nativeCalls, contains('expired'));
  });

  test('傳輸中換帳戶，不回傳上一個帳戶的清單', () async {
    final drive = gateway((req) async {
      linked = accountB;
      return http.Response(
        jsonEncode({
          'files': [
            {'id': 'only-a', 'createdTime': stamp},
          ],
        }),
        200,
      );
    });
    await expectLater(
      drive.list(accountA),
      throwsA(
        isA<DriveBackupException>().having(
          (e) => e.needsReconnect,
          '重新確認帳戶',
          true,
        ),
      ),
    );
    expect(await drive.currentAccount(), accountB);
  });

  test('還原下載驗證版本並讀取原始位元組', () async {
    final drive = gateway((req) async {
      if (req.url.queryParameters['alt'] == 'media') {
        return http.Response.bytes([9, 2, 7], 200);
      }
      return http.Response(
        jsonEncode({
          'spaces': ['appDataFolder'],
          'appProperties': {'splitTogetherLedger': production},
        }),
        200,
      );
    });
    expect(await drive.download(accountA, 'mine'), [9, 2, 7]);
  });

  test('在上傳前拒絕超出快照大小上限的資料', () async {
    var requests = 0;
    final drive = gateway((req) async {
      requests++;
      return http.Response('', 500);
    });
    await expectLater(
      drive.upload(accountA, Uint8List(LedgerBackup.maxBytes + 1)),
      throwsA(isA<DriveBackupException>()),
    );
    expect(requests, 0);
  });

  test('其他平台不呼叫 Android Google 授權', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    const drive = AndroidDriveBackupGateway();
    expect(drive.isSupported, isFalse);
    await expectLater(drive.connect(), throwsA(isA<DriveBackupException>()));
    expect(nativeCalls, isEmpty);
  });
}
