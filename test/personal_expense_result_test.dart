import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:split_together/app.dart';
import 'package:split_together/data/memory_repository.dart';
import 'package:split_together/domain.dart';

class _ControlledRepository extends MemorySplitRepository {
  final writes = <bool>[];
  Completer<void>? pending;
  bool failNext = false;

  @override
  Future<void> setQuickMealPersonalExpense(String mealId, bool recorded) async {
    writes.add(recorded);
    if (failNext) {
      failNext = false;
      throw StateError('模擬寫入失敗');
    }
    await pending?.future;
    await super.setQuickMealPersonalExpense(mealId, recorded);
  }
}

QuickMeal _dinner(bool selfPaid) => QuickMeal(
  id: 'dinner',
  createdAt: DateTime(2026, 11, 1),
  total: 120000,
  payerId: selfPaid ? quickMealSelfId : quickMealGuestId('dinner', 1),
  people: {
    quickMealSelfId: '我',
    quickMealGuestId('dinner', 1): '小林',
    quickMealGuestId('dinner', 2): '小安',
    quickMealGuestId('dinner', 3): '小晴',
  },
);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _openHistory(
  WidgetTester tester,
  MemorySplitRepository repo,
) async {
  await tester.pumpWidget(SplitTogetherApp(repository: repo));
  await tester.pumpAndSettle();
  await _tap(tester, find.text('全部聚餐紀錄'));
}

void main() {
  final record = find.text(r'記入我的支出 · NT$300');
  final recorded = find.text('已記入我的支出');
  final undo = find.text('取消記帳');

  for (final selfPaid in [true, false]) {
    final summary = selfPaid ? r'你應收 NT$900' : r'你要轉給小林 NT$300';
    testWidgets('$summary，歷史結果只記錄自己的三百元，取消後仍可回看', (tester) async {
      final repo = _ControlledRepository();
      await repo.saveQuickMeal(_dinner(selfPaid));
      await _openHistory(tester, repo);
      final entry = find.byKey(const ValueKey('meal-history-dinner'));
      await _tap(tester, entry);
      expect(find.text(summary), findsOneWidget);
      expect(recorded, findsNothing);

      repo.pending = Completer<void>();
      await tester.ensureVisible(record);
      await tester.tap(record);
      await tester.tap(record);
      await tester.pump();
      expect(repo.writes, [true]);
      expect(recorded, findsNothing);
      expect(
        (await repo.load()).quickMeals.single.recordedAsPersonalExpense,
        isFalse,
      );
      repo.pending!.complete();
      await tester.pumpAndSettle();
      expect(recorded, findsOneWidget);
      expect(record, findsNothing);
      await tester.drag(find.byType(ListView).last, const Offset(0, 550));
      await tester.pumpAndSettle();
      expect(find.text(summary), findsOneWidget);
      expect((await repo.load()).quickMeals.single.selfShare, 30000);

      await _tap(tester, find.byType(BackButton));
      await _tap(tester, entry);
      expect(recorded, findsOneWidget);
      await _tap(tester, undo);
      expect(recorded, findsNothing);
      expect(record, findsOneWidget);
      expect(repo.writes, [true, false]);
      final meal = (await repo.load()).quickMeals.single;
      expect(meal.id, 'dinner');
      expect(meal.recordedAsPersonalExpense, isFalse);
      expect(meal.total, 120000);
      await tester.drag(find.byType(ListView).last, const Offset(0, 550));
      await tester.pumpAndSettle();
      expect(find.text(summary), findsOneWidget);
    });
  }

  testWidgets('深色窄畫面的記帳按鈕顯示原餐保存的尾數', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 720);
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final repo = _ControlledRepository();
    await repo.setAppearance(AppAppearance.dark);
    final lin = quickMealGuestId('rounded', 1);
    final chen = quickMealGuestId('rounded', 2);
    await repo.saveQuickMeal(
      QuickMeal.recorded(
        id: 'rounded',
        createdAt: DateTime(2026, 11, 1),
        total: 100000,
        payerId: quickMealSelfId,
        people: {quickMealSelfId: '我', lin: '小林', chen: '小陳'},
        shares: {quickMealSelfId: 33334, lin: 33333, chen: 33333},
      ),
    );

    await _openHistory(tester, repo);
    await _tap(tester, find.byKey(const ValueKey('meal-history-rounded')));
    final exactAmount = find.text(r'記入我的支出 · NT$333.34');
    await _tap(tester, exactAmount);
    expect(recorded, findsOneWidget);
    expect((await repo.load()).quickMeals.single.selfShare, 33334);
    await _tap(tester, undo);
    expect(exactAmount, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('記入或取消寫入失敗會顯示原因提示並保留原狀，可再試一次', (tester) async {
    final repo = _ControlledRepository();
    await repo.saveQuickMeal(_dinner(true));
    await _openHistory(tester, repo);
    await _tap(tester, find.byKey(const ValueKey('meal-history-dinner')));
    repo.failNext = true;
    await _tap(tester, record);
    expect(find.text('無法記入我的支出，請再試一次。'), findsOneWidget);
    expect(record, findsOneWidget);
    expect(recorded, findsNothing);
    expect(
      (await repo.load()).quickMeals.single.recordedAsPersonalExpense,
      isFalse,
    );

    await _tap(tester, record);
    expect(recorded, findsOneWidget);
    repo.failNext = true;
    await _tap(tester, undo);
    expect(find.text('無法取消記帳，請再試一次。'), findsOneWidget);
    expect(recorded, findsOneWidget);
    expect(record, findsNothing);
    expect(
      (await repo.load()).quickMeals.single.recordedAsPersonalExpense,
      isTrue,
    );
    await _tap(tester, undo);
    expect(record, findsOneWidget);
    expect(
      (await repo.load()).quickMeals.single.recordedAsPersonalExpense,
      isFalse,
    );
  });

  testWidgets('沒有本人分攤或本人份額為零的已存聚餐，不提供記帳操作', (tester) async {
    final repo = _ControlledRepository();
    for (final id in ['absent', 'zero']) {
      final other = quickMealGuestId(id, 1);
      final second = id == 'absent' ? quickMealGuestId(id, 2) : quickMealSelfId;
      await repo.saveQuickMeal(
        QuickMeal.recorded(
          id: id,
          createdAt: DateTime(2026, 11, 2),
          total: 1,
          payerId: other,
          people: {other: '阿寬', second: second == quickMealSelfId ? '我' : '小林'},
          shares: {other: 1, second: 0},
        ),
      );
    }
    await _openHistory(tester, repo);
    for (final id in ['absent', 'zero']) {
      await _tap(tester, find.byKey(ValueKey('meal-history-$id')));
      expect(find.text('這餐你不用轉帳'), findsOneWidget);
      expect(find.textContaining('記入我的支出'), findsNothing);
      expect(undo, findsNothing);
      await _tap(tester, find.byType(BackButton));
    }
    expect(repo.writes, isEmpty);
  });

  testWidgets('看完教學範例無法記入個人支出', (tester) async {
    final repo = _ControlledRepository();
    await tester.pumpWidget(SplitTogetherApp(repository: repo));
    await tester.pumpAndSettle();
    await _tap(tester, find.text('用範例試一次'));
    await _tap(tester, find.text('看範例結果'));
    expect(find.text(r'你要轉給小林 NT$300'), findsOneWidget);
    expect(find.textContaining('記入我的支出'), findsNothing);
    expect(undo, findsNothing);
    expect(repo.writes, isEmpty);
    expect((await repo.load()).quickMeals, isEmpty);
  });
}
