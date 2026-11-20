import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:split_together/app.dart';
import 'package:split_together/data/memory_repository.dart';
import 'package:split_together/domain.dart';

const launcher = MethodChannel('split_together/bank_launcher');

Future<void> tapLabel(WidgetTester tester, String label) async {
  final target = find.text(label);
  if (target.evaluate().isEmpty) {
    final scrollable = find
        .descendant(
          of: find.byType(ListView).first,
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(target, 180, scrollable: scrollable);
  }
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> start(
  WidgetTester tester,
  MemorySplitRepository repo,
  TargetPlatform platform,
) async {
  debugDefaultTargetPlatformOverride = platform;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  tester.view.physicalSize = const Size(460, 960);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(SplitTogetherApp(repository: repo));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Android 可選取自己的 App，複製帳號和開啟 App 是獨立動作，回來後仍未記錄還款', (tester) async {
    final repo = MemorySplitRepository();
    const fixture = '0000000012';
    final id = await repo.createGroupWithMembers('旅伴', '旅遊', [
      const MemberDraft(
        name: '小禾',
        saveAsFriend: true,
        bankCode: '700',
        accountNumber: fixture,
      ),
    ]);
    final g = (await repo.load()).groups.single;
    final friend = g.members.singleWhere((m) => !m.isSelf);
    final now = DateTime.utc(2026, 1);
    await repo.saveExpense(
      id,
      Expense(
        id: 'e',
        title: '車票',
        amount: 45000,
        payerId: friend.id,
        method: SplitMethod.equal,
        category: '交通',
        spentAt: now,
        note: '',
        createdAt: now,
        updatedAt: now,
        shares: {g.self.id: 45000},
        inputs: const {},
      ),
    );
    final calls = <MethodCall>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(launcher, (call) async {
      calls.add(call);
      return switch (call.method) {
        'pickApp' => {'id': 'test.example.launchable', 'label': '測試 App'},
        'openApp' => true,
        'copyAccount' => null,
        _ => fail('Unexpected action ${call.method}'),
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(launcher, null));
    await start(tester, repo, TargetPlatform.android);
    await tapLabel(tester, '設定');
    await tapLabel(tester, '我的轉帳 App');
    for (final name in ['中國信託行動銀行', '台新行動銀行', '行動郵局']) {
      expect(find.text(name), findsOneWidget);
    }
    await tapLabel(tester, '選擇其他已安裝的 App');
    expect((await repo.load()).bankApp?.id, 'test.example.launchable');
    await tapLabel(tester, '首頁');
    await tapLabel(tester, '旅伴');
    await tapLabel(tester, '智慧結算');
    String? sharedList;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        sharedList = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tapLabel(tester, '複製還款清單');
    expect(sharedList, '旅伴｜建議還款清單\n我 → 小禾　NT\$450');
    await tapLabel(tester, '我 → 小禾');
    expect(find.textContaining('末四碼 0012'), findsOneWidget);
    expect(find.textContaining(fixture), findsNothing);
    await tapLabel(tester, '複製收款帳號');
    expect(calls.last.method, 'copyAccount');
    expect(calls.last.arguments, fixture);
    await tapLabel(tester, '開啟測試 App');
    expect(calls.last.method, 'openApp');
    expect(calls.last.arguments, 'test.example.launchable');
    expect((await repo.load()).groups.single.repayments, isEmpty);
  });

  testWidgets('iOS 常用銀行與自訂捷徑使用各自對應的入口', (tester) async {
    final repo = MemorySplitRepository();
    await start(tester, repo, TargetPlatform.iOS);
    await tapLabel(tester, '設定');
    await tapLabel(tester, '我的轉帳 App');
    expect(find.text('選擇其他已安裝的 App'), findsNothing);
    expect(find.text('從 App Store 開啟，或使用自己的捷徑'), findsOneWidget);
    await tapLabel(tester, '使用我的捷徑');
    await tester.enterText(find.byType(TextField), '我的銀行 & 郵局');
    await tester.pumpAndSettle();
    await tapLabel(tester, '使用捷徑');
    expect((await repo.load()).bankApp?.id, 'ios-shortcut:我的銀行 & 郵局');
    await tapLabel(tester, '我的轉帳 App');
    await tapLabel(tester, '清除預設選擇');
    expect((await repo.load()).bankApp, isNull);
  });
}
