import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:split_together/data/memory_repository.dart';
import 'package:split_together/domain.dart';
import 'package:split_together/screens/friends_screen.dart';
import 'package:split_together/screens/group_screens.dart';
import 'package:split_together/screens/home_screen.dart';
import 'package:split_together/state.dart';

Finder field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Future<void> showPage(
  WidgetTester t,
  AppController controller,
  Widget page,
) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = const Size(430, 900);
  addTearDown(t.view.resetDevicePixelRatio);
  addTearDown(t.view.resetPhysicalSize);
  await t.pumpWidget(
    AppScope(
      controller: controller,
      child: MaterialApp(key: UniqueKey(), home: page),
    ),
  );
  await t.pumpAndSettle();
}

Future<void> tap(WidgetTester t, Finder target) async {
  await t.ensureVisible(target);
  await t.pumpAndSettle();
  await t.tap(target);
  await t.pumpAndSettle();
}

Future<void> input(WidgetTester t, String label, String value) async {
  final target = field(label);
  await t.ensureVisible(target);
  await t.pumpAndSettle();
  await t.enterText(target, value);
  await t.pumpAndSettle();
}

void main() {
  testWidgets('設定與聚餐共用朋友名單，改名與移出名單都保留原餐次', (t) async {
    final repo = MemorySplitRepository();
    final c = AppController(repo);
    await c.initialize();
    addTearDown(c.dispose);
    await showPage(t, c, const HomeScreen());
    Future<void> settingsFriends() async {
      await tap(t, find.text('設定'));
      await tap(t, find.text('常用朋友'));
    }

    Future<void> back() async {
      await t.pageBack();
      await t.pumpAndSettle();
    }

    await settingsFriends();
    expect(find.text('尚無常用朋友'), findsOneWidget);
    await tap(t, find.text('新增常用朋友'));
    await input(t, '名稱', '   ');
    await tap(t, find.text('儲存'));
    expect(find.text('請填寫朋友姓名'), findsOneWidget);
    expect(c.data.activeFriends, isEmpty);
    await input(t, '名稱', '  小林  ');
    await tap(t, find.text('儲存'));
    final lin = c.data.activeFriends.single;
    expect(lin.name, '小林');
    expect(c.data.quickMeals, isEmpty);

    await back();
    await tap(t, find.text('首頁'));
    await tap(t, find.text('開始聚餐分帳'));
    Finder attendee(String id) => find.byKey(ValueKey('meal-attendee-$id'));
    expect(t.widget<FilterChip>(attendee(lin.id)).selected, isFalse);
    await tap(t, find.byKey(const ValueKey('meal-add-friend')));
    await input(t, '名稱', '小安');
    await tap(t, find.text('儲存'));
    final an = c.data.activeFriends.singleWhere((f) => f.id != lin.id);
    expect(t.widget<FilterChip>(attendee(an.id)).selected, isFalse);
    await tap(t, attendee(lin.id));
    await tap(t, attendee(quickMealSelfId));
    await tap(t, find.byKey(ValueKey('meal-payer-${lin.id}')));
    await t.enterText(find.byKey(const ValueKey('meal-amount')), '600');
    await t.pumpAndSettle();
    await tap(t, find.byKey(const ValueKey('meal-save')));
    final meal = c.data.quickMeals.single;
    expect(meal.payerId, lin.id);
    expect(meal.shares, {quickMealSelfId: 30000, lin.id: 30000});
    await back();
    await settingsFriends();
    expect(find.byKey(ValueKey(an.id)), findsOneWidget);

    await tap(t, find.byTooltip('小林的名單選項'));
    await tap(t, find.text('重新命名'));
    await input(t, '名稱', '   ');
    await tap(t, find.text('儲存'));
    expect(find.text('請填寫朋友姓名'), findsOneWidget);
    await input(t, '名稱', '  小安  ');
    await tap(t, find.text('儲存'));
    expect(
      c.data.activeFriends.map((f) => f.id),
      unorderedEquals([lin.id, an.id]),
    );
    expect(c.data.activeFriends.map((f) => f.name), everyElement('小安'));
    final renamedLabel = c.data.quickMealPeople[lin.id]!;
    expect(renamedLabel, isNot(c.data.quickMealPeople[an.id]));
    final menu = find.byTooltip('$renamedLabel的名單選項');
    await tap(t, menu);
    await tap(t, find.text('移出常用名單'));
    await tap(t, find.text('取消'));
    expect(c.data.activeFriends, hasLength(2));
    await tap(t, menu);
    await tap(t, find.text('移出常用名單'));
    await tap(t, find.text('移出'));
    expect(c.data.activeFriends.single.id, an.id);
    expect(find.byKey(ValueKey(lin.id)), findsNothing);
    await back();
    expect(find.text('1 位朋友'), findsOneWidget);
    await tap(t, find.text('首頁'));
    await tap(t, find.byKey(ValueKey('meal-history-${meal.id}')));
    expect(find.text(r'你要轉給小林 NT$300'), findsOneWidget);
    final saved = (await repo.load()).quickMeals.single;
    expect(saved.id, meal.id);
    expect(saved.payerId, meal.payerId);
    expect(saved.people, meal.people);
    expect(saved.shares, meal.shares);
    await back();
    await tap(t, find.text('開始聚餐分帳'));
    expect(attendee(lin.id), findsNothing);
    expect(t.widget<FilterChip>(attendee(an.id)).selected, isFalse);
    expect(find.byType(ChoiceChip), findsNothing);
  });

  testWidgets('移出常用名單後原群組可查看收款資料，新增成員不再列出該朋友', (t) async {
    final repo = MemorySplitRepository();
    final groupId = await repo.createGroupWithMembers('聚會', '聚餐', [
      const MemberDraft(
        name: '旅伴',
        saveAsFriend: true,
        bankCode: '700',
        accountNumber: '000000123456',
      ),
    ]);
    final friend = (await repo.load()).friends.single;
    await repo.archiveFriend(friend.id);
    final c = AppController(repo);
    await c.initialize();
    addTearDown(c.dispose);
    await showPage(t, c, MembersScreen(groupId: groupId));
    expect(find.text('旅伴'), findsOneWidget);
    expect(find.textContaining('末四碼 3456'), findsOneWidget);
    await tap(t, find.byTooltip('旅伴的成員選項'));
    await tap(t, find.text('朋友收款資料'));
    await tap(t, find.text('查看完整帳號'));
    expect(find.text('000000123456'), findsOneWidget);
    await tap(t, find.text('關閉'));
    await t.pageBack();
    await t.pumpAndSettle();
    await tap(t, find.text('新增成員'));
    await tap(t, find.text('從常用朋友選取'));
    expect(find.text('尚無常用朋友'), findsOneWidget);
    expect(find.byKey(ValueKey(friend.id)), findsNothing);
  });

  testWidgets('成員可儲存收款資料；選取同一朋友加入另一組時僅顯示末四碼', (t) async {
    final repo = MemorySplitRepository();
    final first = await repo.createGroup('旅行', '旅遊', []);
    final second = await repo.createGroup('室友', '生活', []);
    final c = AppController(repo);
    await c.initialize();
    await showPage(t, c, MembersScreen(groupId: first));
    await tap(t, find.text('新增成員'));
    await input(t, '成員名稱', '測試旅伴');
    await tap(t, find.text('存為常用朋友'));
    await tap(t, find.text('收款資料（選填）'));
    await input(t, '銀行名稱或代碼', '郵局');
    await input(t, '收款帳號', '000-000-123456');
    await tap(t, find.text('加入成員'));
    final friend = (await repo.load()).friends.single;
    expect(friend.bankCode, '700');
    expect(await repo.readFriendAccount(friend.id), '000000123456');
    expect(find.textContaining('末四碼 3456'), findsOneWidget);
    expect(find.textContaining('000000123456'), findsNothing);

    await showPage(t, c, MembersScreen(groupId: second));
    await tap(t, find.text('新增成員'));
    await tap(t, find.text('從常用朋友選取'));
    await input(t, '搜尋朋友', '測試');
    await tap(t, find.byKey(ValueKey(friend.id)));
    await tap(t, find.text('加入成員'));
    expect(c.group(second).members.last.friendId, friend.id);
    expect((await repo.load()).friends, hasLength(1));
    expect(find.textContaining('末四碼 3456'), findsOneWidget);

    await showPage(t, c, const FriendsScreen());
    await tap(t, find.text('測試旅伴'));
    await tap(t, find.text('查看完整帳號'));
    expect(find.text('000000123456'), findsOneWidget);
    await tap(t, find.text('關閉'));
    expect(find.text('000000123456'), findsNothing);
    await tap(t, find.text('刪除收款帳號'));
    await tap(t, find.text('取消'));
    expect(find.textContaining('末四碼 3456'), findsOneWidget);
    await tap(t, find.text('編輯收款資料'));
    await input(t, '銀行名稱或代碼', '004');
    await input(t, '收款帳號', '000000009876');
    await tap(t, find.text('儲存收款資料'));
    expect(find.textContaining('末四碼 9876'), findsOneWidget);
    await tap(t, find.text('刪除收款帳號'));
    await tap(t, find.text('刪除'));
    expect(await repo.readFriendAccount(friend.id), isNull);
    expect(c.group(first).members.last.friendId, friend.id);
    expect(c.group(second).members.last.friendId, friend.id);
  });

  testWidgets('批次貼上姓名可刪除標籤，重名提示阻止儲存', (t) async {
    final repo = MemorySplitRepository();
    final c = AppController(repo);
    await c.initialize();
    await showPage(t, c, const GroupFormScreen());
    await input(t, '群組名稱', '聚會');
    await input(t, '其他成員（選填）', '小安\n小晴');
    expect(find.byType(InputChip), findsNWidgets(2));
    await tap(t, find.byTooltip('移除小晴'));
    await input(t, '其他成員（選填）', ' 小安 ');
    expect(find.text('群組裡已經有「小安」'), findsOneWidget);
    expect(
      t
          .widget<FilledButton>(find.widgetWithText(FilledButton, '儲存群組'))
          .onPressed,
      isNull,
    );
    await input(t, '其他成員（選填）', '小林');
    await tap(t, find.text('儲存群組'));
    expect((await repo.load()).groups.single.members.map((m) => m.name), [
      '我',
      '小安',
      '小林',
    ]);
  });

  testWidgets('明確選擇常用朋友後連結到舊成員，保留原有成員 ID 與顯示名稱', (t) async {
    final repo = MemorySplitRepository();
    await repo.createGroupWithMembers('一群', '生活', [
      const MemberDraft(name: '小安', saveAsFriend: true),
    ]);
    final id = await repo.createGroup('二群', '生活', ['旅伴']);
    final c = AppController(repo);
    await c.initialize();
    final member = c.group(id).members.last;
    final friend = c.data.friends.single;
    await showPage(t, c, MembersScreen(groupId: id));
    await tap(t, find.byTooltip('旅伴的成員選項'));
    await tap(t, find.text('連結常用朋友'));
    await tap(t, find.text('從常用朋友選取'));
    await tap(t, find.byKey(ValueKey(friend.id)));
    await tap(t, find.text('儲存連結'));
    final linked = c.group(id).member(member.id);
    expect(linked.friendId, friend.id);
    expect(linked.name, '旅伴');
  });
}
