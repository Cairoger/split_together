import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:split_together/app.dart';
import 'package:split_together/data/ledger_backup.dart';
import 'package:split_together/data/memory_repository.dart';
import 'package:split_together/data/repository.dart';
import 'package:split_together/domain.dart';
import 'package:split_together/screens/backup_screen.dart';
import 'package:split_together/services/backup_file_picker.dart';
import 'package:split_together/services/ledger_backup_service.dart';
import 'package:split_together/state.dart';

class FakeFilePicker implements BackupFilePicker {
  @override
  final bool isSupported;
  FakeFilePicker({this.isSupported = true});

  Uint8List? file;
  String? suggestedName;
  bool cancelSave = false, failSave = false;
  int saves = 0, opens = 0;
  Completer<void>? waitForSave;

  @override
  Future<bool> save(String filename, Uint8List bytes) async {
    saves++;
    suggestedName = filename;
    await waitForSave?.future;
    if (cancelSave) return false;
    if (failSave) throw const FormatException('備份檔寫入失敗，請重新選擇儲存位置。');
    file = Uint8List.fromList(bytes);
    return true;
  }

  @override
  Future<Uint8List?> open() async {
    opens++;
    return file;
  }
}

class FailingRestoreRepository extends MemorySplitRepository {
  bool failWrite = true;
  @override
  Future<void> restoreBackup(LedgerBackup backup) async {
    if (failWrite) throw StateError('test-only write failure');
    await super.restoreBackup(backup);
  }
}

Future<void> seedLedger(MemorySplitRepository repo) async {
  final date = DateTime.utc(2023, 1, 3);
  final friend = await repo.createFriend('林同學');
  await repo.setFriendAccount(friend, '999', '000012345678');
  final id = await repo.createGroupWithMembers('旅行', '旅遊', [
    MemberDraft(name: '阿林', friendId: friend),
  ]);
  final group = (await repo.load()).groups.single;
  final ids = group.members.map((m) => m.id).toList();
  final self = group.self.id;
  final other = ids.singleWhere((id) => id != self);
  await repo.saveExpense(
    id,
    Expense(
      id: 'expense',
      title: '早餐',
      amount: 30001,
      payerId: self,
      method: SplitMethod.equal,
      category: '餐飲',
      spentAt: date,
      note: '測試資料',
      createdAt: date,
      updatedAt: date,
      shares: SplitService.divide(30001, SplitMethod.equal, ids, {}),
      inputs: const {},
    ),
  );
  await repo.addRepayment(
    id,
    Repayment(
      id: 'repayment',
      fromId: other,
      toId: self,
      amount: 10000,
      paidAt: date,
      note: '部分還款',
      createdAt: date,
    ),
  );
  await repo.saveQuickMeal(
    QuickMeal(
      id: 'meal',
      createdAt: date,
      total: 17301,
      payerId: friend,
      people: {quickMealSelfId: '我', friend: '當時的朋友'},
    ),
  );
  await repo.archiveFriend(friend);
  final priorTrip = await repo.createGroup('已結清的行程', '旅遊', ['另一位成員']);
  await repo.setArchived(priorTrip, true);
}

Future<void> showBackup(
  WidgetTester t,
  MemorySplitRepository repo,
  FakeFilePicker picker,
) async {
  final controller = AppController(repo);
  await controller.initialize();
  addTearDown(controller.dispose);
  await t.pumpWidget(
    AppScope(
      controller: controller,
      child: MaterialApp(home: BackupScreen(picker: picker)),
    ),
  );
  await t.pumpAndSettle();
}

Future<void> tap(WidgetTester t, String label) async {
  final target = find.text(label);
  await t.ensureVisible(target);
  await t.tap(target);
  await t.pump();
  await t.pump(const Duration(milliseconds: 350));
  await t.pump();
}

void main() {
  testWidgets('在 Android 的設定打開備份頁可直接使用兩個檔案操作', (t) async {
    await t.pumpWidget(SplitTogetherApp(repository: MemorySplitRepository()));
    await t.pumpAndSettle();
    await t.tap(find.text('設定'));
    await t.pumpAndSettle();
    final entry = find.text('備份與還原');
    await t.scrollUntilVisible(
      entry,
      180,
      scrollable: find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    await tap(t, '備份與還原');
    expect(find.text('匯出備份檔'), findsOneWidget);
    expect(find.text('從備份檔還原'), findsOneWidget);
    expect(find.textContaining('未加密'), findsOneWidget);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.text('匯出備份檔'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('不支援檔案選擇器的平台保留返回及離線帳本', (t) async {
    await showBackup(
      t,
      MemorySplitRepository(),
      FakeFilePicker(isSupported: false),
    );
    expect(find.textContaining('僅支援 Android'), findsOneWidget);
    expect(find.text('匯出備份檔'), findsNothing);
    expect(find.text('從備份檔還原'), findsNothing);
  });

  testWidgets('匯出連點、取消、儲存位置寫入失敗及重試', (t) async {
    final repo = MemorySplitRepository();
    await repo.createFriend('已儲存的朋友');
    final picker = FakeFilePicker()..waitForSave = Completer<void>();
    await showBackup(t, repo, picker);
    expect(picker.saves, 0);
    await tap(t, '匯出備份檔');
    await tap(t, '匯出備份檔');
    expect(picker.saves, 1);
    expect(find.text('已匯出備份檔。'), findsNothing);
    picker.cancelSave = true;
    picker.waitForSave!.complete();
    await t.pumpAndSettle();
    expect(find.text('已取消匯出。'), findsOneWidget);
    expect(picker.file, isNull);
    picker.cancelSave = false;
    picker.failSave = true;
    await tap(t, '匯出備份檔');
    expect(find.textContaining('寫入失敗'), findsOneWidget);
    expect(picker.file, isNull);
    picker.failSave = false;
    await tap(t, '匯出備份檔');
    expect(find.text('已匯出備份檔。'), findsOneWidget);
    expect(await repo.isLedgerEmpty(), isFalse);
    expect(
      picker.suggestedName,
      matches(
        RegExp(r'^SplitTogether_\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}\.json$'),
      ),
    );
  });

  test('過大、損毀、不支援的快照都會在顯示預覽前被擋下', () async {
    final target = MemorySplitRepository();
    final picker = FakeFilePicker();
    final service = LedgerBackupService(target, picker);
    final data = await (await target.createBackup(DateTime.utc(2025))).encode();
    final changed = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
    changed['sha256'] = '';
    final badChecksum = utf8.encode(jsonEncode(changed));
    changed['version'] = 999;
    for (final bytes in [
      Uint8List(LedgerBackup.maxBytes + 1),
      Uint8List.fromList([255]),
      badChecksum,
      utf8.encode(jsonEncode(changed)),
    ]) {
      picker.file = bytes;
      await expectLater(service.pickForRestore(), throwsFormatException);
      expect(await target.isLedgerEmpty(), isTrue);
    }
  });

  testWidgets('取消選檔、取消預覽及出現本機資料都不覆蓋帳本', (t) async {
    final target = MemorySplitRepository();
    final picker = FakeFilePicker();
    await showBackup(t, target, picker);
    await tap(t, '從備份檔還原');
    expect(find.text('已取消還原。'), findsOneWidget);
    final source = MemorySplitRepository();
    await source.createFriend('備份裡的朋友');
    picker.file = await (await source.createBackup(DateTime.utc(2024)))
        .encode();
    await tap(t, '從備份檔還原');
    expect(find.textContaining('備份時間'), findsOneWidget);
    await tap(t, '取消');
    expect(await target.isLedgerEmpty(), isTrue);
    await tap(t, '從備份檔還原');
    await target.createFriend('正在使用的朋友');
    await tap(t, '確認還原');
    expect(find.text(nonEmptyLedgerMessage), findsOneWidget);
    await tap(t, '從備份檔還原');
    expect(picker.opens, 3);
    expect((await target.load()).friends.single.name, '正在使用的朋友');
  });

  testWidgets('虛構帳本匯出可在另一個空帳本還原；保留封存、歷史與餘額', (t) async {
    final picker = FakeFilePicker();
    final source = MemorySplitRepository();
    await seedLedger(source);
    final before = await source.load();
    await LedgerBackupService(source, picker).exportFile();
    final json = utf8.decode(picker.file!);
    expect(json, isNot(contains('000012345678')));
    expect(json, isNot(contains('bankCode')));
    expect(json, isNot(contains('lastFour')));
    final target = FailingRestoreRepository();
    await showBackup(t, target, picker);
    await tap(t, '從備份檔還原');
    expect(find.textContaining('消費　1 筆'), findsOneWidget);
    expect(find.textContaining('快速聚餐　1 餐'), findsOneWidget);
    expect(find.textContaining('還款　1 筆'), findsOneWidget);
    await tap(t, '確認還原');
    expect(find.textContaining('操作未完成'), findsOneWidget);
    expect(await target.isLedgerEmpty(), isTrue);
    target.failWrite = false;
    await tap(t, '從備份檔還原');
    await tap(t, '確認還原');
    expect(find.textContaining('還原完成'), findsOneWidget);
    final after = await target.load();
    final original = before.groups.singleWhere((g) => !g.archived);
    final recovered = after.groups.singleWhere((g) => !g.archived);
    expect(recovered.id, original.id);
    expect(recovered.expenses.single.shares, original.expenses.single.shares);
    expect(recovered.repayments.single.amount, 10000);
    expect(
      BalanceService.balances(recovered),
      BalanceService.balances(original),
    );
    expect(after.groups.singleWhere((g) => g.archived).name, '已結清的行程');
    expect(
      after.quickMeals.single.shareText,
      before.quickMeals.single.shareText,
    );
    expect(after.friends.single.isArchived, isTrue);
    expect(await target.readFriendAccount(after.friends.single.id), isNull);
    expect(
      await source.readFriendAccount(before.friends.single.id),
      '000012345678',
    );
  });
}
