import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:split_together/data/memory_repository.dart';
import 'package:split_together/domain.dart';
import 'package:split_together/screens/quick_meal_result_screen.dart';
import 'package:split_together/state.dart';

Future<void> showPage(
  WidgetTester tester,
  MemorySplitRepository repo,
  Widget page,
) async {
  final controller = AppController(repo);
  await controller.initialize();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    AppScope(
      controller: controller,
      child: MaterialApp(home: page),
    ),
  );
  await tester.pumpAndSettle();
}

QuickMeal meal(String payer, Map<String, String> people, int total) =>
    QuickMeal(
      id: 'meal',
      createdAt: DateTime.utc(2026),
      total: total,
      payerId: payer,
      people: people,
    );

void main() {
  const self = quickMealSelfId;
  const two = {self: '我', 'lin': '小林'};
  const three = {self: '我', 'lin': '小林', 'chen': '小陳'};

  testWidgets('我先付時醒目顯示扣除自付份額後的應收總額，並從主按鈕分享清單', (tester) async {
    final dinner = meal(self, three, 90000);
    final sent = <MethodCall>[];
    const shareChannel = MethodChannel('split_together/meal_share');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(shareChannel, (call) async {
      sent.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(shareChannel, null));
    await showPage(
      tester,
      MemorySplitRepository(),
      QuickMealResultScreen(meal: dinner),
    );
    expect(find.text(r'你應收 NT$600').hitTestable(), findsOneWidget);
    expect(find.byKey(const ValueKey('meal-bank-open')), findsNothing);
    final button = find.widgetWithText(FilledButton, '分享分帳清單');
    expect(button.hitTestable(), findsOneWidget);
    expect(sent, isEmpty);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(sent.single.method, 'shareText');
    expect(sent.single.arguments, dinner.shareText);
  });

  testWidgets('我未出席或分到零元時，只顯示這餐不用轉帳', (tester) async {
    final noPayment = [
      meal('lin', {'lin': '小林', 'chen': '小陳'}, 60000),
      meal('!', {self: '我', '!': '小林'}, 1), // 這一分由付款人分攤。
      meal(self, two, 1), // 我先付且自己分攤全部。
    ];
    for (final dinner in noPayment) {
      await showPage(
        tester,
        MemorySplitRepository(),
        QuickMealResultScreen(meal: dinner),
      );
      expect(find.text('這餐你不用轉帳').hitTestable(), findsOneWidget);
      expect(find.byKey(const ValueKey('meal-bank-open')), findsNothing);
      expect(
        find.byKey(const ValueKey('meal-bank-copy-account')),
        findsNothing,
      );
      expect(find.widgetWithText(FilledButton, '分享分帳清單'), findsNothing);
    }
  });

  testWidgets('範例的付款按鈕僅供辨識，回到真實聚餐後資料與轉帳設定仍保持原狀', (tester) async {
    final repo = MemorySplitRepository();
    const choice = BankAppChoice(id: 'example.app', label: '原有 App');
    await repo.setBankApp(choice);
    final calls = <MethodCall>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    for (final name in [
      'split_together/bank_launcher',
      'split_together/meal_share',
    ]) {
      final channel = MethodChannel(name);
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    }
    await showPage(tester, repo, const QuickMealExampleScreen());
    expect(find.text(r'NT$600'), findsOneWidget);
    expect(find.text('我、小林'), findsOneWidget);
    await tester.tap(find.text('看範例結果'));
    await tester.pumpAndSettle();
    expect(find.text(r'你要轉給小林 NT$300'), findsOneWidget);
    final exampleButton = find.widgetWithText(FilledButton, '選擇我的轉帳 App');
    expect(tester.widget<FilledButton>(exampleButton).onPressed, isNull);
    await tester.tap(exampleButton);
    await tester.pumpAndSettle();
    expect(find.text('分享分帳清單'), findsNothing);
    expect(find.text('複製清單'), findsNothing);
    await tester.tap(find.text('開始聚餐分帳'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsWidgets);
    final amount = tester.widget<TextField>(
      find.byKey(const ValueKey('meal-amount')),
    );
    expect(amount.controller!.text, isEmpty);
    final attendee = tester.widget<FilterChip>(
      find.byKey(const ValueKey('meal-attendee-@self')),
    );
    expect(attendee.selected, isFalse);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(calls, isEmpty);
    final data = await repo.load();
    expect(data.quickMeals, isEmpty);
    expect(data.groups, isEmpty);
    expect(data.friends, isEmpty);
    expect(data.bankApp?.id, choice.id);
  });
}
