import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:split_together/app.dart';
import 'package:split_together/data/memory_repository.dart';
import 'package:split_together/domain.dart';
import 'package:split_together/screens/quick_meal_result_screen.dart';

const exampleTitle = '用範例試一次';
const exampleDescription = r'兩人平分 NT$600，不會留下紀錄';
const replayTitle = '重看分帳教學';

Future<void> launch(WidgetTester t, MemorySplitRepository repo) async {
  await t.pumpWidget(SplitTogetherApp(repository: repo));
  await t.pumpAndSettle();
}

Future<void> tapLabel(WidgetTester t, String label) async {
  final target = find.text(label);
  if (target.evaluate().isEmpty) {
    final scrollable = find
        .descendant(
          of: find.byType(ListView).first,
          matching: find.byType(Scrollable),
        )
        .first;
    await t.scrollUntilVisible(target, 160, scrollable: scrollable);
  }
  if (target.hitTestable().evaluate().isEmpty) {
    await t.ensureVisible(target);
    await t.pumpAndSettle();
  }
  await t.tap(target);
  await t.pumpAndSettle();
}

Future<void> back(WidgetTester t) async {
  await t.binding.handlePopRoute();
  await t.pumpAndSettle();
}

void expectHomeWithoutExample(WidgetTester t) {
  expect(find.text(exampleTitle), findsNothing);
  expect(find.text(exampleDescription), findsNothing);
  final start = find.widgetWithText(FilledButton, '開始聚餐分帳');
  final recent = find.text('最近聚餐');
  expect(recent.hitTestable(), findsOneWidget);
  // 標題與主按鈕之間只保留標題列本身的垂直置中空間。
  final gap = t.getTopLeft(recent).dy - t.getBottomLeft(start).dy;
  expect(gap, inInclusiveRange(0.0, 20.0));
}

void main() {
  testWidgets('即使已有聚餐，整張範例卡仍可點選；單純返回與略過都不會完成教學', (t) async {
    final repo = MemorySplitRepository();
    await repo.saveQuickMeal(
      QuickMeal(
        id: 'dinner',
        createdAt: DateTime.utc(2026),
        total: 60000,
        payerId: quickMealSelfId,
        people: {quickMealSelfId: '我', quickMealGuestId('dinner', 1): '朋友'},
      ),
    );
    await launch(t, repo);
    final card = find.widgetWithText(Card, exampleDescription);
    expect(
      find.descendant(of: card, matching: find.text(exampleTitle)),
      findsOneWidget,
    );
    final bounds = t.getRect(card);
    final button = find.widgetWithText(FilledButton, '開始聚餐分帳');
    expect(
      bounds.top - t.getBottomLeft(button).dy,
      inInclusiveRange(0.0, 20.0),
    );
    // 點右側留白，避免只有標題文字可以點擊。
    await t.tapAt(Offset(bounds.right - 14, bounds.center.dy));
    await t.pumpAndSettle();
    expect(find.byType(QuickMealExampleScreen), findsOneWidget);
    expect((await repo.load()).hasSeenExampleResult, isFalse);
    await back(t);
    expect(card.hitTestable(), findsOneWidget);
    await tapLabel(t, exampleTitle);
    await tapLabel(t, '略過範例，直接分帳');
    expect(find.byKey(const ValueKey('meal-amount')), findsOneWidget);
    await back(t);
    expect(card.hitTestable(), findsOneWidget);
    final data = await repo.load();
    expect(data.hasSeenExampleResult, isFalse);
    expect(data.quickMeals.map((meal) => meal.id), ['dinner']);
  });

  testWidgets('從首頁看到範例結果便完成，空帳本回首頁與重新啟動都不留入口', (t) async {
    final repo = MemorySplitRepository();
    await launch(t, repo);
    await tapLabel(t, exampleTitle);
    await tapLabel(t, '看範例結果');
    expect(find.text(r'你要轉給小林 NT$300'), findsOneWidget);
    final data = await repo.load();
    expect(data.hasSeenExampleResult, isTrue);
    expect(data.quickMeals, isEmpty);
    await back(t);
    expectHomeWithoutExample(t);
    await t.pumpWidget(const SizedBox.shrink());
    await launch(t, repo);
    expectHomeWithoutExample(t);
  });

  testWidgets('設定可首次完成同一份教學，也能再次重看；兩次都保留空帳本', (t) async {
    final repo = MemorySplitRepository();
    await launch(t, repo);
    for (final previouslySeen in [false, true]) {
      expect((await repo.load()).hasSeenExampleResult, previouslySeen);
      await tapLabel(t, '設定');
      await tapLabel(t, replayTitle);
      expect(find.byType(QuickMealExampleScreen), findsOneWidget);
      expect(find.text('這一餐怎麼分？'), findsOneWidget);
      await tapLabel(t, '看範例結果');
      expect(find.text(r'你要轉給小林 NT$300'), findsOneWidget);
      await back(t);
      expect(find.text(replayTitle), findsOneWidget);
      expect(find.text('查看兩人平分的範例'), findsOneWidget);
      await tapLabel(t, '首頁');
      expectHomeWithoutExample(t);
    }
    final data = await repo.load();
    expect(data.quickMeals, isEmpty);
    expect(data.groups, isEmpty);
    expect(data.friends, isEmpty);
  });

  for (final appearance in AppAppearance.values) {
    testWidgets('320 dp 與 160% 字體的 ${appearance.name} 模式可操作兩處教學入口', (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(320, 700);
      t.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      final repo = MemorySplitRepository();
      await repo.setAppearance(appearance);
      await launch(t, repo);
      expect(find.text(exampleDescription).hitTestable(), findsOneWidget);
      await tapLabel(t, exampleDescription);
      expect(find.byType(QuickMealExampleScreen), findsOneWidget);
      await back(t);
      await tapLabel(t, '設定');
      await tapLabel(t, '查看兩人平分的範例');
      expect(find.byType(QuickMealExampleScreen), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
}
