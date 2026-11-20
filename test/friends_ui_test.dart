import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:split_together/data/memory_repository.dart';
import 'package:split_together/domain.dart';
import 'package:split_together/screens/friends_screen.dart';
import 'package:split_together/screens/group_screens.dart';
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
