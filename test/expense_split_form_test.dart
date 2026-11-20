import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:split_together/app.dart';
import 'package:split_together/data/memory_repository.dart';
import 'package:split_together/domain.dart';

Finder _key(String key) => find.byKey(ValueKey(key));

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
    await tester.scrollUntilVisible(target, 180, scrollable: scrollable);
  }
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  await _show(tester, target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, Finder field, String value) async {
  await _show(tester, field);
  await tester.enterText(field, value);
  await tester.pumpAndSettle();
}

Future<void> _launch(
  WidgetTester tester,
  MemorySplitRepository repo, {
  Size size = const Size(480, 1000),
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

Future<void> _newExpense(WidgetTester tester, [String amount = '1200']) async {
  await _tap(tester, find.text('新增消費'));
  await _enter(tester, _key('expense-amount'), amount);
  await _enter(tester, _key('expense-title'), '午餐');
}

Future<void> _mode(WidgetTester tester, String name) =>
    _tap(tester, _key('expense-method-$name'));

Future<void> _precise(WidgetTester tester, String control, String value) async {
  await _tap(tester, _key(control));
  await _enter(tester, _key('split-precise-input'), value);
  await _tap(tester, find.text('套用'));
}

Future<void> _expectShare(WidgetTester tester, String id, int cents) async {
  final share = _key('split-share-$id');
  await _show(tester, share);
  expect(tester.widget<Text>(share).data, contains(Money.format(cents)));
}

Future<void> _expectPercent(
  WidgetTester tester,
  String id,
  int basisPoints,
) async {
  final control = _key('percent-value-$id');
  await _show(tester, control);
  final label = tester
      .widgetList<Text>(
        find.descendant(of: control, matching: find.byType(Text)),
      )
      .map((text) => text.data)
      .whereType<String>()
      .singleWhere((value) => value.contains('%'));
  expect(Money.parse(label.replaceAll('%', ''), allowZero: true), basisPoints);
}

Future<bool> _canSave(WidgetTester tester) async {
  final save = _key('expense-save');
  await _show(tester, save);
  return tester.widget<FilledButton>(save).onPressed != null;
}

Future<void> _openSaved(WidgetTester tester, String title) async {
  await _tap(tester, find.text('週末'));
  await _tap(tester, find.text(title));
  await _tap(tester, find.text('編輯消費'));
}

void main() {
  testWidgets('按份數分會即時重算每人金額，大份數可精確輸入並在上下限停用按鈕', (tester) async {
    final repo = MemorySplitRepository();
    await repo.createGroup('週末', '聚餐', ['小安', '小林']);
    final group = (await repo.load()).groups.single;
    final ids = group.members.map((member) => member.id).toList();
    final self = group.self.id;
    await _launch(tester, repo, size: const Size(320, 640), scale: 1.8);
    await _newExpense(tester);
    expect(
      tester.widget<ChoiceChip>(_key('expense-method-equal')).selected,
      isTrue,
    );
    await _mode(tester, 'weight');
    final minus = _key('weight-minus-$self');
    final plus = _key('weight-plus-$self');
    await _show(tester, minus);
    expect(tester.widget<IconButton>(minus).onPressed, isNull);
    for (final button in [minus, plus]) {
      final node = tester.getSemantics(button);
      expect(node.label + node.tooltip, contains(group.self.name));
    }
    await _tap(tester, plus);
    for (final id in ids) {
      await _expectShare(tester, id, id == self ? 60000 : 30000);
    }
    await _precise(tester, 'weight-value-$self', '10000');
    await _show(tester, plus);
    expect(tester.widget<IconButton>(plus).onPressed, isNull);
    expect(tester.widget<IconButton>(minus).onPressed, isNotNull);
    await _show(tester, _key('weight-bar'));
    expect(find.text('總份數 10002 份'), findsOneWidget);
    expect(
      find.descendant(of: _key('weight-bar'), matching: find.byType(Expanded)),
      findsNWidgets(3),
    );
    expect(tester.takeException(), isNull);
    await _tap(tester, _key('expense-save'));
    final saved = (await repo.load()).groups.single.expenses.single;
    expect(saved.method, SplitMethod.weight);
    final weights = {for (final id in ids) id: id == self ? 10000 : 1};
    expect(saved.inputs, weights);
    expect(
      saved.shares,
      SplitService.divide(120000, SplitMethod.weight, ids, weights),
    );

    await _openSaved(tester, '午餐');
    await _tap(tester, _key('weight-value-$self'));
    final input = _key('split-precise-input');
    final editor = find.descendant(
      of: input,
      matching: find.byType(EditableText),
    );
    expect(tester.widget<EditableText>(editor).controller.text, '10000');
    for (final invalid in ['0', '10001', '1.5']) {
      await _enter(tester, input, invalid);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '套用'))
            .onPressed,
        isNull,
      );
    }
    await _tap(tester, find.text('取消'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('兩人百分比的滑桿與精確輸入都會自動補足另一人，一次只開一列', (tester) async {
    final repo = MemorySplitRepository();
    await repo.createGroup('週末', '生活', ['小安']);
    final group = (await repo.load()).groups.single;
    final self = group.self.id;
    final friend = group.members.singleWhere((m) => !m.isSelf).id;
    await _launch(tester, repo, size: const Size(320, 640), scale: 1.8);
    await _newExpense(tester, '100');
    await _mode(tester, 'percent');
    await _expectPercent(tester, self, 5000);
    await _expectPercent(tester, friend, 5000);
    await _precise(tester, 'percent-value-$self', '60');
    await _expectPercent(tester, self, 6000);
    await _expectPercent(tester, friend, 4000);
    await _expectShare(tester, self, 6000);
    await _expectShare(tester, friend, 4000);
    final slider = _key('percent-slider-$self');
    if (slider.evaluate().isEmpty) {
      await _tap(tester, _key('percent-toggle-$self'));
    }
    await _show(tester, slider);
    await tester.tapAt(tester.getCenter(slider));
    await tester.pumpAndSettle();
    await _expectPercent(tester, self, 5000);
    await _expectPercent(tester, friend, 5000);

    await _tap(tester, _key('percent-toggle-$friend'));
    await _show(tester, _key('percent-slider-$friend'));
    expect(find.byType(Slider), findsOneWidget);
    final widget = tester.widget<Slider>(_key('percent-slider-$friend'));
    widget.onChanged!(widget.min + (widget.max - widget.min) * .4);
    await tester.pumpAndSettle();
    await _expectPercent(tester, self, 6000);
    await _expectPercent(tester, friend, 4000);
    await _tap(tester, _key('expense-save'));
    expect((await repo.load()).groups.single.expenses.single.inputs, {
      self: 6000,
      friend: 4000,
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('金額欄有焦點時開啟精確輸入，套用後不會重開表單鍵盤', (tester) async {
    final repo = MemorySplitRepository();
    await repo.createGroup('週末', '聚餐', ['小安']);
    final self = (await repo.load()).groups.single.self.id;
    await _launch(tester, repo, size: const Size(480, 1400));
    await _newExpense(tester, '100');
    await _mode(tester, 'percent');
    final amountField = _key('expense-amount');
    await _enter(tester, amountField, '100');
    final amountFocus = tester
        .widget<EditableText>(
          find.descendant(of: amountField, matching: find.byType(EditableText)),
        )
        .focusNode;
    await _show(tester, _key('percent-value-$self'));
    expect(amountFocus.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
    await _precise(tester, 'percent-value-$self', '60');
    expect(amountFocus.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('多人百分比不足顯示尚未分配，105% 隱藏圖表和金額，保留一人可穩定分完尾差', (tester) async {
    final repo = MemorySplitRepository();
    await repo.createGroup('週末', '生活', ['小安', '小林']);
    final group = (await repo.load()).groups.single;
    final self = group.self.id;
    final others =
        group.members.where((m) => !m.isSelf).map((m) => m.id).toList()..sort();
    final a = others.first, b = others.last;
    await _launch(tester, repo);
    await _newExpense(tester, '100');
    await _mode(tester, 'percent');
    final sorted = [self, a, b]..sort();
    for (final id in sorted) {
      await _expectPercent(tester, id, id == sorted.first ? 3334 : 3333);
    }
    for (final entry in {self: '50', a: '30', b: '20'}.entries) {
      await _precise(tester, 'percent-value-${entry.key}', entry.value);
    }
    await _tap(tester, _key('percent-toggle-$self'));
    final remainder = _key('percent-remainder-$self');
    await _show(tester, remainder);
    expect(
      find.descendant(of: remainder, matching: find.textContaining('保留我')),
      findsOneWidget,
    );
    await _tap(tester, remainder);
    await _expectPercent(tester, a, 2500);
    await _expectPercent(tester, b, 2500);
    await _precise(tester, 'percent-value-$a', '30');
    await _precise(tester, 'percent-value-$b', '20');
    final slider = _key('percent-slider-$self');
    await _show(tester, slider);
    tester.widget<Slider>(slider).onChanged!(55);
    await tester.pumpAndSettle();
    await _expectPercent(tester, a, 3000);
    await _expectPercent(tester, b, 2000);
    await _show(tester, find.textContaining('超出 5%').first);
    expect(_key('percent-donut'), findsNothing);
    for (final id in sorted) {
      expect(_key('split-share-$id'), findsNothing);
    }
    expect(await _canSave(tester), isFalse);
    await _precise(tester, 'percent-value-$self', '40.01');
    await _show(tester, _key('percent-donut'));
    await _show(tester, find.textContaining('尚未分配').first);
    expect(_key('split-share-$self'), findsNothing);
    expect(await _canSave(tester), isFalse);
    await _tap(tester, remainder);
    await _expectPercent(tester, a, 3000);
    await _expectPercent(tester, b, 2999);
    await _expectShare(tester, self, 4001);
    await _expectShare(tester, a, 3000);
    await _expectShare(tester, b, 2999);
    await _tap(tester, _key('expense-save'));
    expect((await repo.load()).groups.single.expenses.single.inputs, {
      self: 4001,
      a: 3000,
      b: 2999,
    });
  });

  testWidgets('切換分帳方式保留各自草稿，增減參與者不會改寫其他人的比例', (tester) async {
    final repo = MemorySplitRepository();
    await repo.createGroup('週末', '聚餐', ['小安', '小林']);
    final group = (await repo.load()).groups.single;
    final self = group.self.id;
    final others = group.members
        .where((m) => !m.isSelf)
        .map((m) => m.id)
        .toList();
    final a = others.first, b = others.last;
    await _launch(tester, repo);
    await _newExpense(tester, '100');
    await _tap(tester, _key('expense-member-$b'));
    await _mode(tester, 'percent');
    await _precise(tester, 'percent-value-$self', '60');
    await _mode(tester, 'weight');
    await _tap(tester, _key('weight-plus-$a'));
    await _mode(tester, 'exact');
    await _enter(tester, _key('split-exact-$self'), '75');
    await _enter(tester, _key('split-exact-$a'), '25');
    await _mode(tester, 'percent');
    await _tap(tester, _key('expense-member-$b'));
    await _expectPercent(tester, self, 6000);
    await _expectPercent(tester, a, 4000);
    await _expectPercent(tester, b, 0);
    await _precise(tester, 'percent-value-$b', '25');
    await _tap(tester, _key('expense-member-$a'));
    await _expectPercent(tester, self, 6000);
    await _expectPercent(tester, b, 2500);
    expect(_key('percent-value-$a'), findsNothing);
    expect(await _canSave(tester), isFalse);
    await _tap(tester, _key('expense-member-$a'));
    await _expectPercent(tester, a, 4000);
    await _tap(tester, _key('expense-member-$b'));
    await _mode(tester, 'weight');
    await _expectShare(tester, a, 6667);
    await _mode(tester, 'exact');
    await _expectShare(tester, self, 7500);
    await _expectShare(tester, a, 2500);
    await _mode(tester, 'percent');
    await _tap(tester, _key('expense-save'));
    final saved = (await repo.load()).groups.single.expenses.single;
    expect(saved.inputs, {self: 6000, a: 4000});
    expect(saved.shares, {self: 6000, a: 4000});
  });

  testWidgets('編輯舊百分比消費保留精確比例、已停用的付款與分攤成員，以及更多資料', (tester) async {
    final repo = MemorySplitRepository();
    final groupId = await repo.createGroup('週末', '聚餐', ['小安', '小林']);
    final group = (await repo.load()).groups.single;
    final self = group.self.id;
    final oldPayer = group.members.singleWhere((m) => m.name == '小安').id;
    final absent = group.members.singleWhere((m) => m.name == '小林').id;
    final date = DateTime(2023, 4, 15, 12, 34).toUtc();
    final inputs = {self: 3333, oldPayer: 6667};
    final original = Expense(
      id: 'previous',
      title: '舊車票',
      amount: 10000,
      payerId: oldPayer,
      method: SplitMethod.percent,
      category: '交通',
      spentAt: date,
      note: '紙本車票',
      createdAt: date,
      updatedAt: date,
      shares: inputs,
      inputs: inputs,
    );
    await repo.saveExpense(groupId, original);
    await repo.addRepayment(
      groupId,
      Repayment(
        id: 'settled',
        fromId: self,
        toId: oldPayer,
        amount: 3333,
        paidAt: date,
        note: '',
        createdAt: date,
      ),
    );
    await repo.deactivateMember(groupId, oldPayer);
    await _launch(tester, repo);
    await _openSaved(tester, '舊車票');
    await _expectPercent(tester, self, 3333);
    await _expectPercent(tester, oldPayer, 6667);
    expect(_key('percent-value-$absent'), findsNothing);
    expect(find.text('紙本車票'), findsNothing);
    await _tap(tester, find.text('更多資料'));
    await _show(tester, find.textContaining('2023/04/15'));
    expect(find.text('交通'), findsOneWidget);
    final note = find.widgetWithText(TextField, '紙本車票');
    await _enter(tester, note, '車票已核對');
    await _tap(tester, _key('expense-save'));
    final data = (await repo.load()).groups.single;
    final saved = data.expenses.single;
    expect(saved.id, original.id);
    expect(saved.inputs, inputs);
    expect(saved.shares, original.shares);
    expect(saved.payerId, oldPayer);
    expect(saved.spentAt, date);
    expect(saved.createdAt, date);
    expect(saved.category, '交通');
    expect(saved.note, '車票已核對');
    expect(data.repayments.single.id, 'settled');

    await _tap(tester, find.text('編輯消費'));
    await _tap(tester, find.text('更多資料'));
    await _tap(tester, find.textContaining('2023/04/15'));
    await _tap(tester, find.text('16'));
    await _tap(tester, find.text('確定'));
    await _tap(tester, find.text('交通'));
    await _tap(tester, find.text('購物').last);
    await _tap(tester, _key('expense-save'));
    final updated = (await repo.load()).groups.single.expenses.single;
    expect(updated.spentAt, DateTime(2023, 4, 16, 12, 34).toUtc());
    expect(updated.category, '購物');
    expect(updated.note, '車票已核對');
    expect(updated.inputs, inputs);
  });
}
