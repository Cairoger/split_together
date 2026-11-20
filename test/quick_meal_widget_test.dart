import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:split_together/app.dart';
import 'package:split_together/data/memory_repository.dart';
import 'package:split_together/domain.dart';

Finder _key(String value) => find.byKey(ValueKey(value));
Finder _attendee(String id) => _key('meal-attendee-$id');
Finder _payer(String id) => _key('meal-payer-$id');

Future<void> _launch(
  WidgetTester tester,
  MemorySplitRepository repo, {
  Size size = const Size(430, 900),
  double scale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(SplitTogetherApp(repository: repo));
  await tester.pumpAndSettle();
  await _tap(tester, find.text('快速聚餐'));
}

Future<void> _show(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) {
    final scrollable = find
        .descendant(
          of: find.byType(ListView).first,
          matching: find.byType(Scrollable),
        )
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    position.jumpTo(position.minScrollExtent);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(target, 200, scrollable: scrollable);
  }
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  await _show(tester, target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _amount(WidgetTester tester, String value) async {
  final field = _key('meal-amount');
  await _show(tester, field);
  await tester.enterText(field, value);
  await tester.pumpAndSettle();
}

Future<bool> _canSave(WidgetTester tester) async {
  final button = _key('meal-save');
  await _show(tester, button);
  return tester.widget<FilledButton>(button).onPressed != null;
}

Future<void> _saveMeal(
  WidgetTester tester,
  List<String> attendees,
  String payer,
) async {
  for (final id in attendees) {
    await _tap(tester, _attendee(id));
  }
  await _tap(tester, _payer(payer));
  await _amount(tester, '900');
  expect(_key('meal-bank-open'), findsNothing);
  await _tap(tester, _key('meal-save'));
  expect(find.text('聚餐分帳結果'), findsOneWidget);
}

void main() {
  testWidgets('快速聚餐只有本人應付時顯示轉帳入口，設定或取消後返回同一餐', (tester) async {
    final repo = MemorySplitRepository();
    final lin = await repo.createFriend('小林');
    final an = await repo.createFriend('小安');
    const bank = MethodChannel('split_together/bank_launcher');
    final messenger = tester.binding.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(bank, (call) async {
      calls.add(call);
      return switch (call.method) {
        'listApps' => [
          {'id': 'com.chinatrust.mobilebank', 'label': '中國信託行動銀行'},
        ],
        'isAppAvailable' || 'openApp' => true,
        _ => null,
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(bank, null));

    await _launch(tester, repo);
    await _saveMeal(tester, [quickMealSelfId, lin, an], lin);
    final open = _key('meal-bank-open');
    await _show(tester, open);
    expect(open, findsOneWidget);
    expect(find.text(r'你要轉給小林 NT$300'), findsOneWidget);
    expect(find.text('尚未儲存收款帳號'), findsOneWidget);
    expect(_key('meal-bank-copy-account'), findsNothing);
    final saved = (await repo.load()).quickMeals.single;

    await _tap(tester, open);
    expect(find.text('我的轉帳 App'), findsOneWidget);
    await _tap(tester, find.byType(BackButton));
    expect(find.text('聚餐分帳結果'), findsOneWidget);
    expect((await repo.load()).bankApp, isNull);

    await _tap(tester, open);
    await _tap(tester, find.text('中國信託行動銀行'));
    expect(find.text('聚餐分帳結果'), findsOneWidget);
    expect(find.text('開啟中國信託行動銀行'), findsOneWidget);
    expect(calls.any((call) => call.method == 'openApp'), isFalse);
    await _tap(tester, open);
    expect(
      calls
          .where((call) => call.method == 'openApp')
          .map((call) => call.arguments),
      ['com.chinatrust.mobilebank'],
    );
    final data = await repo.load();
    expect(data.quickMeals.single.id, saved.id);
    expect(data.quickMeals.single.shares, saved.shares);
    expect(data.groups, isEmpty);
  });

  testWidgets('本人收款或未出席時不顯示快速聚餐的轉帳入口', (tester) async {
    final repo = MemorySplitRepository();
    final lin = await repo.createFriend('小林');
    final an = await repo.createFriend('小安');
    await _launch(tester, repo);
    await _saveMeal(tester, [quickMealSelfId, lin, an], quickMealSelfId);
    expect(_key('meal-bank-open'), findsNothing);
    expect(_key('meal-bank-copy-account'), findsNothing);

    await _tap(tester, find.byType(BackButton));
    await _tap(tester, find.text('快速聚餐'));
    await _saveMeal(tester, [lin, an], lin);
    expect(_key('meal-bank-open'), findsNothing);
    expect(_key('meal-bank-copy-account'), findsNothing);
    expect((await repo.load()).quickMeals.length, 2);
  });

  testWidgets('快速聚餐收款帳號只遮罩顯示或明確複製，不進分享、不預填', (tester) async {
    final repo = MemorySplitRepository();
    final lin = await repo.createFriend('小林');
    const account = '000123456789';
    const bankChoice = BankAppChoice(
      id: 'tw.com.taishinbank.mobile',
      label: '台新行動銀行',
    );
    await repo.setFriendAccount(lin, '822', account);
    await repo.setBankApp(bankChoice);
    const bank = MethodChannel('split_together/bank_launcher');
    const share = MethodChannel('split_together/meal_share');
    final messenger = tester.binding.defaultBinaryMessenger;
    final bankCalls = <MethodCall>[];
    final sharing = <String>[];
    messenger.setMockMethodCallHandler(bank, (call) async {
      bankCalls.add(call);
      return call.method == 'openApp' ? true : null;
    });
    messenger.setMockMethodCallHandler(share, (call) async {
      sharing.add(call.arguments as String);
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(bank, null);
      messenger.setMockMethodCallHandler(share, null);
    });

    await _launch(tester, repo);
    await _saveMeal(tester, [quickMealSelfId, lin], lin);
    await _show(tester, _key('meal-bank-copy-account'));
    expect(find.text('822 中國信託 · 末四碼 6789'), findsOneWidget);
    expect(find.textContaining(account), findsNothing);
    expect(bankCalls, isEmpty);
    await _tap(tester, find.widgetWithText(FilledButton, '分享清單'));
    expect(sharing.single, contains('我 → 小林'));
    expect(sharing.single, isNot(contains('6789')));
    expect(sharing.single, isNot(contains(account)));
    expect(bankCalls, isEmpty);

    await _tap(tester, _key('meal-bank-open'));
    await _tap(tester, _key('meal-bank-copy-account'));
    expect(bankCalls.map((call) => (call.method, call.arguments)), [
      ('openApp', bankChoice.id),
      ('copyAccount', account),
    ]);
    expect(find.textContaining(account), findsNothing);
    expect((await repo.load()).quickMeals.length, 1);
    expect((await repo.load()).groups, isEmpty);
  });

  testWidgets('空帳本可直接新增朋友，需選滿兩人與付款人，取消付款人後須重新選擇', (tester) async {
    final repo = MemorySplitRepository();
    await _launch(tester, repo);
    expect(
      tester.widget<FilterChip>(_attendee(quickMealSelfId)).selected,
      isFalse,
    );
    await _tap(tester, _key('meal-add-friend'));
    final name = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(name, '小林');
    await _tap(tester, find.widgetWithText(FilledButton, '儲存'));
    final lin = (await repo.load()).friends.single.id;
    expect(tester.widget<FilterChip>(_attendee(lin)).selected, isFalse);
    await _tap(tester, _attendee(lin));
    await _amount(tester, '90');
    expect(await _canSave(tester), isFalse);
    await _tap(tester, _attendee(quickMealSelfId));
    expect(await _canSave(tester), isFalse);
    await _tap(tester, _payer(lin));
    expect(await _canSave(tester), isTrue);
    await _tap(tester, _attendee(lin));
    expect(_payer(lin), findsNothing);
    await _tap(tester, _attendee(lin));
    expect(tester.widget<ChoiceChip>(_payer(lin)).selected, isFalse);
    expect(await _canSave(tester), isFalse);
    await _tap(tester, _payer(quickMealSelfId));
    for (final invalid in ['0', '-1', '1.001', '']) {
      await _amount(tester, invalid);
      expect(await _canSave(tester), isFalse, reason: invalid);
    }
    final data = await repo.load();
    expect(data.quickMeals, isEmpty);
    expect(data.groups, isEmpty);
  });

  testWidgets('四人聚餐可複製及分享，回看同一餐，下一餐從空白開始', (tester) async {
    final repo = MemorySplitRepository();
    final lin = await repo.createFriend('小林');
    final an = await repo.createFriend('小安');
    final qing = await repo.createFriend('小晴');
    const account = '000123456789';
    await repo.setFriendAccount(lin, '822', account);
    const share = MethodChannel('split_together/meal_share');
    final messenger = tester.binding.defaultBinaryMessenger;
    final sent = <String>[], copied = <String>[];
    messenger.setMockMethodCallHandler(share, (call) async {
      expect(call.method, 'shareText');
      sent.add(call.arguments as String);
      return null;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(share, null));
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await _launch(tester, repo);
    for (final id in [quickMealSelfId, lin, an, qing]) {
      await _tap(tester, _attendee(id));
    }
    await _tap(tester, _payer(lin));
    await _amount(tester, '1200');
    for (final id in [quickMealSelfId, lin, an, qing]) {
      final row = _key('meal-share-$id');
      await _show(tester, row);
      expect(
        find.descendant(of: row, matching: find.textContaining(r'NT$300')),
        findsOneWidget,
      );
    }
    for (final id in [quickMealSelfId, an, qing]) {
      final row = _key('meal-transfer-$id');
      await _show(tester, row);
      expect(
        find.descendant(of: row, matching: find.textContaining(r'NT$300')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.textContaining('小林')),
        findsOneWidget,
      );
    }
    expect(_key('meal-transfer-$lin'), findsNothing);
    await _tap(tester, _key('meal-save'));
    expect(find.text('聚餐分帳結果'), findsOneWidget);
    final first = (await repo.load()).quickMeals.single;
    expect(first.shares.values, everyElement(30000));
    expect(first.shares, hasLength(4));
    expect(
      first.transfers.map((t) => t.fromId),
      unorderedEquals([quickMealSelfId, an, qing]),
    );
    expect(
      first.transfers.every((t) => t.toId == lin && t.amount == 30000),
      isTrue,
    );
    expect(sent, isEmpty);
    expect(copied, isEmpty);
    await _tap(tester, find.text('複製清單'));
    expect(sent, isEmpty);
    await _tap(tester, find.text('分享清單'));
    expect(sent.single, copied.single);
    expect(sent.single, first.shareText);
    for (final name in ['小林', '小安', '小晴', '我']) {
      expect(sent.single, contains(name));
    }
    expect(sent.single, isNot(contains(account)));
    expect(sent.single, isNot(contains('6789')));
    expect(sent.single, isNot(contains('822')));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await _launch(tester, repo);
    for (final id in [quickMealSelfId, lin, an, qing]) {
      expect(tester.widget<FilterChip>(_attendee(id)).selected, isFalse);
    }
    expect(
      tester.widget<TextField>(_key('meal-amount')).controller!.text,
      isEmpty,
    );
    await _tap(tester, find.text('聚餐紀錄'));
    await _tap(tester, _key('meal-history-${first.id}'));
    expect(find.text('聚餐分帳結果'), findsOneWidget);
    await _tap(tester, find.byType(BackButton));
    await _tap(tester, find.byType(BackButton));

    for (final id in [an, qing]) {
      await _tap(tester, _attendee(id));
    }
    await _tap(tester, _payer(qing));
    await _amount(tester, '180');
    await _tap(tester, _key('meal-save'));
    final after = await repo.load();
    expect(after.quickMeals, hasLength(2));
    final second = after.quickMeals.firstWhere((meal) => meal.id != first.id);
    expect(second.shares, {an: 9000, qing: 9000});
    expect(second.transfers.single.fromId, an);
    expect(second.transfers.single.toId, qing);
    expect(second.transfers.single.amount, 9000);
    expect(after.groups, isEmpty);
  });

  testWidgets('窄螢幕與大字級可分別勾選同名朋友，三人平分的尾差與勾選順序無關', (tester) async {
    final repo = MemorySplitRepository();
    final lin1 = await repo.createFriend('小林');
    final lin2 = await repo.createFriend('小林');
    final people = (await repo.load()).quickMealPeople;
    expect(people[lin1], isNot(people[lin2]));
    await _launch(tester, repo, size: const Size(320, 640), scale: 1.6);
    for (final id in [lin2, lin1, quickMealSelfId]) {
      await _tap(tester, _attendee(id));
    }
    await _tap(tester, _payer(lin2));
    await _amount(tester, '1000');
    final orderedIds = [quickMealSelfId, lin1, lin2]..sort();
    for (final id in orderedIds) {
      final row = _key('meal-share-$id');
      await _show(tester, row);
      final expected = id == orderedIds.first ? r'NT$333.34' : r'NT$333.33';
      expect(
        find.descendant(of: row, matching: find.text(expected)),
        findsOneWidget,
      );
    }
    await _tap(tester, _attendee(lin1));
    await _tap(tester, _attendee(lin1));
    await _tap(tester, _key('meal-save'));
    final meal = (await repo.load()).quickMeals.single;
    expect(meal.payerId, lin2);
    expect(meal.shares, {
      for (final id in orderedIds) id: id == orderedIds.first ? 33334 : 33333,
    });
    expect(meal.shares.values.fold<int>(0, (n, share) => n + share), 100000);
    expect(tester.takeException(), isNull);
  });

  testWidgets('失敗後保留輸入可重試，連點同一個儲存動作只留下單筆', (tester) async {
    final repo = _RetryRepository();
    final friend = await repo.createFriend('小林');
    await _launch(tester, repo);
    await _tap(tester, _attendee(quickMealSelfId));
    await _tap(tester, _attendee(friend));
    await _tap(tester, _payer(friend));
    await _amount(tester, '701.25');
    final save = _key('meal-save');
    await _tap(tester, save);
    expect(find.textContaining('這次儲存失敗'), findsOneWidget);
    expect((await repo.load()).quickMeals, isEmpty);
    await _show(tester, _key('meal-amount'));
    expect(
      tester.widget<TextField>(_key('meal-amount')).controller!.text,
      '701.25',
    );
    expect(tester.widget<ChoiceChip>(_payer(friend)).selected, isTrue);
    await _show(tester, save);
    await tester.tap(save);
    await tester.tap(save);
    await tester.pump();
    expect(repo.attempts, hasLength(2));
    expect(repo.attempts.toSet(), hasLength(1));
    repo.resume.complete();
    await tester.pumpAndSettle();
    expect((await repo.load()).quickMeals.single.total, 70125);
    expect(find.text('聚餐分帳結果'), findsOneWidget);
  });
}

class _RetryRepository extends MemorySplitRepository {
  final attempts = <String>[];
  final resume = Completer<void>();

  @override
  Future<void> saveQuickMeal(QuickMeal meal) async {
    attempts.add(meal.id);
    if (attempts.length == 1) throw const FormatException('這次儲存失敗，請再試一次');
    await resume.future;
    await super.saveQuickMeal(meal);
  }
}
