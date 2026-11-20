import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:split_together/bank_launcher.dart';
import 'package:split_together/domain.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('split_together/bank_launcher');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  const selected = BankAppChoice(id: 'example.demo.wallet', label: '測試錢包');

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'listApps' => [
          {'id': selected.id, 'label': selected.label},
          {'id': selected.id, 'label': '重複'},
          {'id': 'no-label'},
        ],
        'isAppAvailable' => true,
        'appIcon' => Uint8List.fromList([1, 2, 3]),
        'openApp' || 'openOfficialPage' => true,
        'copyAccount' => null,
        _ => throw MissingPluginException(),
      };
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('使用自選 Android App 時只傳送套件 ID；帳號僅在使用者複製時交給剪貼簿', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final choice = (await BankLauncher.listAndroidApps()).single;
    expect(choice.label, selected.label);
    expect(await BankLauncher.androidAppIcon(choice.id), [1, 2, 3]);
    expect(await BankLauncher.isAndroidAppAvailable(choice.id), isTrue);
    expect(await BankLauncher.open(choice), isTrue);
    expect(calls.map((call) => call.method), [
      'listApps',
      'appIcon',
      'isAppAvailable',
      'openApp',
    ]);
    expect(
      calls.skip(1).map((call) => call.arguments),
      List.filled(3, choice.id),
    );
    expect(calls.last.arguments, selected.id);

    await BankLauncher.copyAccount('000000000000');
    expect(calls.last.method, 'copyAccount');
    expect(calls.last.arguments, '000000000000');
  });

  test('iOS 行動郵局提供獨立商店入口；捷徑需由使用者選定', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    const postal = BankAppChoice(id: 'tw.gov.post.mpost', label: '行動郵局');
    expect(await BankLauncher.listAndroidApps(), isEmpty);
    expect(await BankLauncher.open(postal), isFalse);
    expect(calls, isEmpty);
    expect(await BankLauncher.openOfficialPage(postal), isTrue);
    expect(calls.single.method, 'openOfficialPage');
    expect(calls.single.arguments, postal.id);

    const shortcut = BankAppChoice(id: 'ios-shortcut:開啟郵局', label: '開啟郵局');
    expect(await BankLauncher.open(shortcut), isTrue);
    expect(calls.last.arguments, shortcut.id);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(await BankLauncher.open(shortcut), isFalse);
    expect(calls, hasLength(2));
  });
}
