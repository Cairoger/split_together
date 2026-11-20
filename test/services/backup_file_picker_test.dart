import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:split_together/data/ledger_backup.dart';
import 'package:split_together/services/backup_file_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('split_together/backup_file_picker');
  const picker = AndroidBackupFilePicker();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('匯出傳遞建議檔名與原始位元組，開啟時取得使用者所選檔案', () async {
    final bytes = Uint8List.fromList([9, 10, 11]);
    const filename = 'SplitTogether-2026-11-21_123456.json';
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'open') return bytes;
      expect(call.arguments['filename'], filename);
      expect(call.arguments['bytes'], orderedEquals(bytes));
      return true;
    });
    expect(await picker.save(filename, bytes), isTrue);
    expect(await picker.open(), orderedEquals(bytes));
    expect(calls, ['save', 'open']);
  });

  test('使用者取消建立或開啟檔案時回傳取消狀態', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'save' ? false : null,
    );
    expect(await picker.save('example.json', Uint8List(1)), isFalse);
    expect(await picker.open(), isNull);
  });

  test('匯出超限時不開啟選擇器，原生讀檔超限也會提示', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      throw PlatformException(code: 'too-large');
    });
    final oversized = Uint8List(LedgerBackup.maxBytes + 1);
    final tooLarge = isA<FormatException>().having(
      (e) => e.message,
      '訊息',
      contains('32 MiB'),
    );
    await expectLater(picker.save('large.json', oversized), throwsA(tooLarge));
    expect(calls, isEmpty);
    await expectLater(picker.open(), throwsA(tooLarge));
    expect(calls, ['open']);
  });

  test('寫檔被拒絕時提示重試，不顯示底層檔案資料', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(
        code: 'file-unavailable',
        message: 'private document URI',
      );
    });
    final cannotWrite = isA<FormatException>().having(
      (e) => e.message,
      '訊息',
      allOf(contains('無法寫入'), isNot(contains('URI'))),
    );
    await expectLater(
      picker.save('example.json', Uint8List(1)),
      throwsA(cannotWrite),
    );
  });

  test('Android 以外的平台不呼叫選擇器橋接', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    expect(picker.isSupported, isFalse);
    await expectLater(picker.open(), throwsFormatException);
    expect(calls, isEmpty);
  });
}
