import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:split_together/app.dart';
import 'package:split_together/data/memory_repository.dart';
import 'package:split_together/domain.dart';

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    final list = find.byType(ListView).first;
    final scrollable = find
        .descendant(of: list, matching: find.byType(Scrollable))
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    position.jumpTo(position.minScrollExtent);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(finder, 240, scrollable: scrollable);
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _reveal(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _tapText(WidgetTester tester, String label) =>
    _tap(tester, find.text(label));

Future<void> _enter(WidgetTester tester, String label, String text) async {
  final field = _field(label);
  await _reveal(tester, field);
  await tester.enterText(field, text);
  await tester.pumpAndSettle();
}

Future<void> _launch(
  WidgetTester tester,
  MemorySplitRepository repo, {
  Size size = const Size(480, 850),
  double scale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(SplitTogetherApp(repository: repo));
  await tester.pumpAndSettle();
}

Future<void> _back(WidgetTester tester) async {
  await tester.tap(find.byType(BackButton));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('T01/T11 create, rename a member, archive and reopen a group', (
    tester,
  ) async {
    final repo = MemorySplitRepository();
    await _launch(tester, repo);
    expect(find.text('建立第一個群組'), findsOneWidget);
    await _tapText(tester, '建立群組');
    await _tapText(tester, '儲存群組');
    expect(find.text('請輸入群組名稱'), findsOneWidget);
    expect((await repo.load()).groups, isEmpty);
    await _enter(tester, '群組名稱', '台南小旅行');
    await _enter(tester, '其他成員（選填）', '小安');
    await _tapText(tester, '儲存群組');
    expect(find.text('尚無消費紀錄'), findsOneWidget);
    await _tapText(tester, '成員管理');
    expect(find.text('我'), findsOneWidget);
    await _tap(tester, find.byTooltip('小安的成員選項'));
    await _tapText(tester, '重新命名');
    await _enter(tester, '名稱', '小晴');
    await _tapText(tester, '儲存');
    expect(find.text('小晴'), findsOneWidget);
    await _back(tester);
    await _tap(tester, find.byTooltip('群組選項'));
    await _tapText(tester, '封存群組');
    await _tapText(tester, '封存');
    expect((await repo.load()).groups.single.archived, isTrue);
    expect(find.text('新增消費'), findsNothing);
    await _back(tester);
    await _tapText(tester, '群組');
    expect(find.text('還沒有群組'), findsOneWidget);
    await _tapText(tester, '已封存');
    await _tapText(tester, '台南小旅行');
    await _tap(tester, find.byTooltip('群組選項'));
    await _tapText(tester, '解除封存群組');
    await _tapText(tester, '解除封存');
    expect(find.text('新增消費'), findsOneWidget);
    final group = (await repo.load()).groups.single;
    expect(group.archived, isFalse);
    expect(group.members.where((member) => member.isSelf), hasLength(1));
    expect(group.members.map((member) => member.name), contains('小晴'));
  });

  testWidgets(
    'T05/T07/T08/T11 edit expense, confirm partial repayment and delete expense',
    (tester) async {
      final repo = MemorySplitRepository();
      await repo.createGroup('週末聚餐', '聚餐', ['小安']);
      await _launch(tester, repo);
      await _tapText(tester, '新增消費');
      await _enter(tester, '項目名稱', '晚餐');
      await _enter(tester, '消費金額', '120.005');
      final save = find.widgetWithText(FilledButton, '儲存消費');
      await _reveal(tester, save);
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      await _enter(tester, '消費金額', '120');
      await _tapText(tester, '指定金額');
      await _enter(tester, '我的分攤金額', '70');
      await _enter(tester, '小安的分攤金額', '49.99');
      await _reveal(tester, save);
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      expect(find.textContaining(r'NT$0.01'), findsOneWidget);
      await _enter(tester, '小安的分攤金額', '50');
      await _tapText(tester, '儲存消費');
      expect(find.text(r'+NT$50'), findsOneWidget);

      await _tapText(tester, '週末聚餐');
      await _tapText(tester, '晚餐');
      await _tapText(tester, '編輯消費');
      await _enter(tester, '消費金額', '140');
      await _enter(tester, '小安的分攤金額', '70');
      await _tapText(tester, '儲存消費');
      expect(find.text(r'NT$140'), findsOneWidget);
      await _back(tester);
      await _tapText(tester, '智慧結算');
      await _tapText(tester, '小安 → 我');
      await _enter(tester, '還款金額', '70.01');
      final record = find.widgetWithText(FilledButton, '儲存還款');
      expect(tester.widget<FilledButton>(record).onPressed, isNull);
      await _enter(tester, '還款金額', '20');
      await _tapText(tester, '儲存還款');
      expect((await repo.load()).groups.single.repayments, isEmpty);
      await _tapText(tester, '確認記錄');
      expect(find.text(r'NT$50'), findsOneWidget);
      await _back(tester);

      await _tapText(tester, '晚餐');
      await _tapText(tester, '刪除消費');
      expect(find.textContaining('既有還款紀錄會保留'), findsOneWidget);
      await _tapText(tester, '取消');
      expect((await repo.load()).groups.single.expenses, hasLength(1));
      await _tapText(tester, '刪除消費');
      await _tapText(tester, '刪除');
      expect(find.text('尚無消費紀錄'), findsOneWidget);
      final group = (await repo.load()).groups.single;
      expect(group.expenses, isEmpty);
      expect(group.repayments.single.amount, 2000);
      await _back(tester);
      expect(find.text(r'−NT$20'), findsOneWidget);
    },
  );

  testWidgets(
    'F11/F12 category totals exclude repayments and clipboard reflects remaining debt',
    (tester) async {
      final repo = MemorySplitRepository();
      final groupId = await repo.createGroup('郊遊', '旅遊', ['小安']);
      final group = (await repo.load()).groups.single;
      final friend = group.members.singleWhere((member) => !member.isSelf);
      final day = DateTime.utc(2026, 3, 4);
      for (final (title, category, amount) in [
        ('午餐', '餐飲', 12125),
        ('點心', '餐飲', 5875),
        ('車票', '交通', 5000),
      ]) {
        await repo.saveExpense(
          groupId,
          Expense(
            id: title,
            title: title,
            amount: amount,
            payerId: group.self.id,
            method: SplitMethod.equal,
            category: category,
            spentAt: day,
            note: '',
            createdAt: day,
            updatedAt: day,
            shares: {friend.id: amount},
            inputs: {},
          ),
        );
      }
      await repo.addRepayment(
        groupId,
        Repayment(
          id: 'p1',
          fromId: friend.id,
          toId: group.self.id,
          amount: 1250,
          paidAt: day,
          note: '',
          createdAt: day,
        ),
      );

      await _launch(tester, repo);
      await _tapText(tester, '統計');
      expect(find.text('各群組消費'), findsOneWidget);
      expect(find.text(r'群組總消費 · NT$230'), findsOneWidget);
      await _tapText(tester, '郊遊');
      for (final (category, total) in [('餐飲', r'NT$180'), ('交通', r'NT$50')]) {
        final tile = find.widgetWithText(ListTile, category);
        expect(
          find.descendant(of: tile, matching: find.text(total)),
          findsOneWidget,
        );
      }

      await _tapText(tester, '首頁');
      await _tapText(tester, '郊遊');
      await _tapText(tester, '智慧結算');
      final messenger = tester.binding.defaultBinaryMessenger;
      String? clipboard;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await _tapText(tester, '複製還款清單');
      expect(clipboard, '郊遊｜建議還款清單\n小安 → 我　NT\$217.50');
    },
  );

  testWidgets('T11 failed writes preserve inputs and allow retry', (
    tester,
  ) async {
    final repo = _FailOnceRepository();
    await repo.createGroup('室友', '生活', ['小安']);
    await _launch(tester, repo);
    await _tapText(tester, '新增消費');
    await _enter(tester, '項目名稱', '晚餐');
    await _enter(tester, '消費金額', '83.25');
    await _tapText(tester, '儲存消費');
    expect(find.text('空間不足，請再試一次'), findsOneWidget);
    expect((await repo.load()).groups.single.expenses, isEmpty);
    await _tapText(tester, '儲存消費');
    final saved = (await repo.load()).groups.single.expenses.single;
    expect(saved.title, '晚餐');
    expect(saved.amount, 8325);
  });

  testWidgets('narrow phone with large text can reach forms and settings', (
    tester,
  ) async {
    final repo = MemorySplitRepository();
    await _launch(tester, repo, size: const Size(320, 640), scale: 1.6);
    await _tapText(tester, '建立群組');
    await _enter(tester, '群組名稱', '旅伴');
    await _tapText(tester, '儲存群組');
    await _tapText(tester, '智慧結算');
    expect(find.text('所有帳目已結清'), findsOneWidget);
    await _back(tester);
    await _back(tester);
    await _tapText(tester, '設定');
    await _tapText(tester, '我的預設名稱');
    await _enter(tester, '名稱', '小禾');
    await _tapText(tester, '儲存');
    expect((await repo.load()).defaultName, '小禾');
    expect(find.text('本機離線儲存'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _FailOnceRepository extends MemorySplitRepository {
  bool fail = true;

  @override
  Future<void> saveExpense(String groupId, Expense expense) async {
    if (fail) {
      fail = false;
      throw const FormatException('空間不足，請再試一次');
    }
    await super.saveExpense(groupId, expense);
  }
}
