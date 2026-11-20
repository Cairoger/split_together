import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:split_together/app.dart';
import 'package:split_together/data/memory_repository.dart';

Future<void> openAbout(WidgetTester tester) async {
  await tester.tap(find.text('設定'));
  await tester.pumpAndSettle();
  final list = find.descendant(
    of: find.byType(ListView),
    matching: find.byType(Scrollable),
  );
  await tester.scrollUntilVisible(find.text('關於帳本'), 220, scrollable: list);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('關於帳本顯示安裝版本與組建，讀取失敗時不顯示舊版本', (tester) async {
    const channel = MethodChannel('dev.fluttercommunity.plus/package_info');
    final messenger = tester.binding.defaultBinaryMessenger;
    var available = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getAll');
      if (!available) throw PlatformException(code: 'unavailable');
      return {'version': '1.1.0', 'buildNumber': '2'};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      SplitTogetherApp(repository: MemorySplitRepository()),
    );
    await tester.pumpAndSettle();
    await openAbout(tester);
    expect(find.textContaining('無法取得版本資訊'), findsOneWidget);
    expect(find.textContaining('1.0.0'), findsNothing);
    expect(find.textContaining('1.1.0'), findsNothing);

    await tester.tap(find.text('首頁'));
    await tester.pumpAndSettle();
    available = true;
    await openAbout(tester);
    expect(find.text('SplitTogether · 版本 1.1.0（組建 2）'), findsOneWidget);

    await tester.tap(find.text('首頁'));
    await tester.pumpAndSettle();
    PackageInfo.setMockInitialValues(
      appName: 'SplitTogether',
      packageName: 'com.example.split_together',
      version: '2.3.4',
      buildNumber: '17',
      buildSignature: '',
    );
    await openAbout(tester);
    expect(find.text('SplitTogether · 版本 2.3.4（組建 17）'), findsOneWidget);
  });
}
