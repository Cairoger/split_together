import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:split_together/app.dart';
import 'package:split_together/data/memory_repository.dart';
import 'package:split_together/domain.dart';
import 'package:split_together/screens/quick_meal_result_screen.dart';

QuickMeal dinner(
  String id,
  DateTime localDate,
  int total, {
  bool selfPaid = false,
}) {
  final guest = quickMealGuestId(id, 1);
  return QuickMeal(
    id: id,
    createdAt: localDate,
    total: total,
    payerId: selfPaid ? quickMealSelfId : guest,
    people: {quickMealSelfId: '我', guest: '小林'},
  );
}

void main() {
  test('以聚餐當地日期歸入月份，跨年、月底最後一分與下月第一筆皆落在正確月份', () async {
    final repo = MemorySplitRepository();
    final dec = dinner(
      'dec',
      DateTime(2026, 12, 31, 23, 59, 59, 999, 999),
      200,
    );
    final janFirst = dinner('jan-first', DateTime(2027), 60000, selfPaid: true);
    final janLast = dinner(
      'jan-last',
      DateTime(2027, 1, 31, 23, 59, 59, 999, 999),
      1200,
    );
    final feb = dinner('feb', DateTime(2027, 2), 40000);
    final omitted = dinner('omitted', DateTime(2027, 1, 14), 50000);
    for (final meal in [feb, dec, janLast, janFirst, omitted]) {
      await repo.saveQuickMeal(meal);
    }
    for (final meal in [janLast, feb, janFirst, dec]) {
      await repo.setQuickMealPersonalExpense(meal.id, true);
    }
    final data = await repo.load();
    final january = data.personalExpenses(DateTime(2027, 1, 15).toUtc());
    expect(january.monthTotal, 30600);
    expect(january.meals.map((m) => m.id), [
      'feb',
      'jan-last',
      'jan-first',
      'dec',
    ]);
    expect(data.personalExpenses(DateTime(2026, 12, 1)).monthTotal, 100);
    expect(data.personalExpenses(DateTime(2027, 2, 1)).monthTotal, 20000);
  });

  testWidgets('支出入口顯示本月總額、依聚餐日期列出明細；點明細可回原餐取消記帳', (tester) async {
    final now = DateTime.now();
    final repo = MemorySplitRepository();
    final current = dinner('current', DateTime(now.year, now.month, 1), 60000);
    final previous = dinner(
      'previous',
      DateTime(now.year, now.month, 0),
      25000,
    );
    for (final meal in [current, previous]) {
      await repo.saveQuickMeal(meal);
      await repo.setQuickMealPersonalExpense(meal.id, true);
    }
    await tester.pumpWidget(SplitTogetherApp(repository: repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的支出'));
    await tester.pumpAndSettle();
    final header = find.widgetWithText(
      Card,
      '本月總額 · ${now.year} 年 ${now.month} 月',
    );
    expect(
      find.descendant(of: header, matching: find.text(r'NT$300')),
      findsOneWidget,
    );
    expect(find.text('全部支出明細'), findsOneWidget);
    final currentTile = find.byKey(const ValueKey('personal-expense-current'));
    final previousTile = find.byKey(
      const ValueKey('personal-expense-previous'),
    );
    expect(
      tester.getTopLeft(currentTile).dy,
      lessThan(tester.getTopLeft(previousTile).dy),
    );
    for (final (tile, meal, amount) in [
      (currentTile, current, r'NT$300'),
      (previousTile, previous, r'NT$125'),
    ]) {
      expect(
        find.descendant(of: tile, matching: find.text('快速聚餐')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: tile,
          matching: find.text('${shortDate(meal.createdAt)} · 餐飲'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: tile, matching: find.text(amount)),
        findsOneWidget,
      );
    }

    await tester.tap(currentTile);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<QuickMealResultScreen>(find.byType(QuickMealResultScreen))
          .meal
          .id,
      current.id,
    );
    expect(find.text(r'你要轉給小林 NT$300'), findsOneWidget);
    await tester.ensureVisible(find.text('取消記帳'));
    await tester.tap(find.text('取消記帳'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(currentTile, findsNothing);
    expect(previousTile, findsOneWidget);
    expect(
      find.descendant(of: header, matching: find.text(r'NT$0')),
      findsOneWidget,
    );
    expect((await repo.load()).quickMeals, hasLength(2));
  });

  testWidgets('深色模式、320 dp 與放大字體可開啟空白支出並閱讀引導', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 700);
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final repo = MemorySplitRepository();
    await repo.setAppearance(AppAppearance.dark);
    await tester.pumpWidget(SplitTogetherApp(repository: repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的支出'));
    await tester.pumpAndSettle();
    expect(find.text(r'NT$0'), findsOneWidget);
    expect(find.text('在聚餐結果點『記入我的支出』，就會出現在這裡'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
