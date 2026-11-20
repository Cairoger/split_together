import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:split_together/app.dart';
import 'package:split_together/data/memory_repository.dart';
import 'package:split_together/domain.dart';
import 'package:split_together/screens/backup_screen.dart';
import 'package:split_together/services/drive_backup_gateway.dart';
import 'package:split_together/services/ledger_backup_service.dart';
import 'package:split_together/state.dart';

const accountA = 'a@example.invalid';
const accountB = 'b@example.invalid';

class FakeDrive implements DriveBackupGateway {
  String? selected = accountA;
  String? nextAccount;
  bool failUpload = false;
  bool failDelete = false;
  bool repeatLatest = false;
  int uploadCalls = 0;
  Completer<void>? uploadGate;
  final cachedTimes = <String, DateTime?>{};
  final storage =
      <String, Map<String, ({DriveBackupFile file, Uint8List bytes})>>{};
  final events = <String>[];

  Map<String, ({DriveBackupFile file, Uint8List bytes})> _files(
    String account,
  ) {
    if (account != selected) {
      throw const DriveBackupException('Google 帳戶已變更。', needsReconnect: true);
    }
    return storage.putIfAbsent(account, () => {});
  }

  @override
  bool get isSupported => true;
  @override
  Future<String?> currentAccount() async => selected;
  @override
  Future<String?> connect() async {
    if (nextAccount != null) selected = nextAccount;
    return nextAccount;
  }

  @override
  Future<void> disconnect() async => selected = null;
  @override
  Future<DateTime?> lastKnownBackup(String account) async {
    _files(account);
    return cachedTimes[account];
  }

  @override
  Future<void> rememberLatest(String account, DateTime? date) async {
    _files(account);
    cachedTimes[account] = date;
  }

  @override
  Future<List<DriveBackupFile>> list(String account) async {
    final files = _files(account).values.map((v) => v.file).toList();
    return [...files, if (repeatLatest && files.isNotEmpty) files.last];
  }

  @override
  Future<DriveBackupFile> upload(String account, Uint8List bytes) async {
    uploadCalls++;
    await uploadGate?.future;
    if (failUpload) {
      events.add('上傳失敗');
      throw const DriveBackupException('連線中斷，請再試。');
    }
    final file = DriveBackupFile(
      id: 'file-$uploadCalls',
      createdAt: DateTime.utc(2024, 6, uploadCalls),
    );
    _files(account)[file.id] = (file: file, bytes: Uint8List.fromList(bytes));
    events.add('上傳成功 ${file.id}');
    return file;
  }

  @override
  Future<Uint8List> download(String account, String id) async =>
      _files(account)[id]!.bytes;
  @override
  Future<void> delete(String account, String id) async {
    if (failDelete) throw const DriveBackupException('無法整理備份');
    _files(account).remove(id);
    events.add('刪除 $id');
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
}

Future<void> showBackup(
  WidgetTester t,
  MemorySplitRepository repo,
  FakeDrive drive,
) async {
  final controller = AppController(repo);
  await controller.initialize();
  addTearDown(controller.dispose);
  await t.pumpWidget(
    AppScope(
      controller: controller,
      child: MaterialApp(home: BackupScreen(gateway: drive)),
    ),
  );
  await frames(t);
}

Future<void> frames(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 350));
  await t.pump();
}

Future<void> tap(WidgetTester t, Finder target) async {
  await t.ensureVisible(target);
  await t.tap(target);
  await frames(t);
}

Future<void> openPreview(WidgetTester t) async {
  await tap(t, find.text('從備份還原'));
  await tap(t, find.textContaining('最新備份'));
  expect(find.text('還原預覽'), findsOneWidget);
}

void main() {
  testWidgets('離線開啟設定的備份入口只查看連結，不會主動要求授權或上傳', (t) async {
    const channel = MethodChannel('split_together/drive_backup');
    final messenger = t.binding.defaultBinaryMessenger;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await t.pumpWidget(SplitTogetherApp(repository: MemorySplitRepository()));
    await t.pumpAndSettle();
    expect(calls, isEmpty);
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
    await tap(t, entry);
    expect(find.text('連結 Google 帳戶'), findsOneWidget);
    expect(calls, ['currentAccount']);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    await t.tap(find.text('首頁'));
    await t.pumpAndSettle();
    expect(find.text('開始聚餐分帳'), findsOneWidget);
    expect(calls, ['currentAccount']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  test('Drive 上損毀或較新的快照無法進入還原，帳本仍為空', () async {
    final drive = FakeDrive();
    final source = MemorySplitRepository();
    await seedLedger(source);
    await LedgerBackupService(source, drive).backUp(accountA);
    final files = drive.storage[accountA]!;
    final original = files.values.single;
    final newer =
        jsonDecode(utf8.decode(original.bytes)) as Map<String, dynamic>;
    newer['version'] = 999;
    final repo = MemorySplitRepository();
    final target = LedgerBackupService(repo, drive);
    for (final bytes in [
      Uint8List.fromList([255]),
      utf8.encode(jsonEncode(newer)),
    ]) {
      files[original.file.id] = (file: original.file, bytes: bytes);
      await expectLater(
        target.preview(accountA, original.file.id),
        throwsFormatException,
      );
      expect(await repo.isLedgerEmpty(), isTrue);
    }
    files[original.file.id] = original;
    await target.restore(await target.preview(accountA, original.file.id));
    expect((await repo.load()).quickMeals, hasLength(1));
  });

  test('備份失敗保留兩份原檔及成功時間，下一次成功才清理舊檔', () async {
    final drive = FakeDrive();
    final service = LedgerBackupService(MemorySplitRepository(), drive);
    await service.backUp(accountA);
    final previous = await service.backUp(accountA);
    final oldBytes = Map.of(drive.storage[accountA]!);
    drive.failUpload = true;
    await expectLater(
      service.backUp(accountA),
      throwsA(isA<DriveBackupException>()),
    );
    expect(drive.cachedTimes[accountA], previous.latest);
    expect(drive.storage[accountA], oldBytes);
    expect(drive.events, ['上傳成功 file-1', '上傳成功 file-2', '上傳失敗']);

    drive.failUpload = false;
    final next = await service.backUp(accountA);
    expect(next.cleanupPending, isFalse);
    expect(next.latest, DateTime.utc(2024, 6, 4));
    expect(drive.cachedTimes[accountA], next.latest);
    expect((await service.versions(accountA)).map((f) => f.id), [
      'file-4',
      'file-2',
    ]);
    expect(drive.events.sublist(3), ['上傳成功 file-4', '刪除 file-1']);
  });

  test('上傳成功、清理失敗仍保留成功時間與原有檔案，下次可再整理', () async {
    final drive = FakeDrive();
    final service = LedgerBackupService(MemorySplitRepository(), drive);
    await service.backUp(accountA);
    await service.backUp(accountA);
    drive.failDelete = true;
    final last = await service.backUp(accountA);
    expect(last.cleanupPending, isTrue);
    expect(drive.cachedTimes[accountA], DateTime.utc(2024, 6, 3));
    expect(drive.storage[accountA]!.keys, ['file-1', 'file-2', 'file-3']);
    drive.failDelete = false;
    await service.backUp(accountA);
    expect(drive.storage[accountA]!.keys, ['file-3', 'file-4']);
  });

  test('Drive 分頁重複回傳最新檔，仍只刪除第三舊的備份', () async {
    final drive = FakeDrive()..repeatLatest = true;
    final service = LedgerBackupService(MemorySplitRepository(), drive);
    await service.backUp(accountA);
    await service.backUp(accountA);
    await service.backUp(accountA);
    expect(drive.storage[accountA]!.keys, ['file-2', 'file-3']);
    expect((await service.versions(accountA)).map((f) => f.id), [
      'file-3',
      'file-2',
    ]);
    expect(drive.events.where((e) => e.startsWith('刪除')), ['刪除 file-1']);
  });

  test('選了還原預覽後換帳戶，及預覽後機內產生資料都阻擋寫入', () async {
    final drive = FakeDrive();
    final source = MemorySplitRepository();
    await source.createFriend('來源朋友');
    await LedgerBackupService(source, drive).backUp(accountA);
    final empty = MemorySplitRepository();
    final target = LedgerBackupService(empty, drive);
    final preview = await target.preview(accountA, 'file-1');

    drive.selected = accountB;
    expect(await target.versions(accountB), isEmpty);
    await expectLater(target.restore(preview), throwsFormatException);
    expect(await empty.isLedgerEmpty(), isTrue);
    drive.selected = accountA;
    await empty.createFriend('本機新增');
    await expectLater(target.restore(preview), throwsFormatException);
    expect((await empty.load()).friends.single.name, '本機新增');
  });

  testWidgets('備份須主動按下並確認；連點及上傳中再點都只上傳一次', (t) async {
    final drive = FakeDrive();
    final repo = MemorySplitRepository();
    await showBackup(t, repo, drive);
    expect(drive.uploadCalls, 0);
    final start = find.text('立即備份');
    await tap(t, start);
    expect(find.textContaining('銀行收款欄位'), findsOneWidget);
    await tap(t, find.text('取消'));
    expect(drive.uploadCalls, 0);

    await t.ensureVisible(start);
    final point = t.getCenter(start);
    await t.tapAt(point);
    await t.tapAt(point);
    await frames(t);
    expect(find.text('確認備份'), findsOneWidget);
    drive.uploadGate = Completer<void>();
    await tap(t, find.text('確認備份'));
    expect(drive.uploadCalls, 1);
    final button = t.widget<FilledButton>(
      find.ancestor(of: start, matching: find.byType(FilledButton)),
    );
    expect(button.onPressed, isNull);
    await t.tap(start);
    await frames(t);
    expect(drive.uploadCalls, 1);
    drive.uploadGate!.complete();
    await frames(t);
    expect(find.text('備份成功。'), findsOneWidget);
    expect(drive.storage[accountA]!.length, 1);
  });

  testWidgets('換帳戶清掉原帳戶的時間和清單，解除連結保留本機與雲端紀錄', (t) async {
    final drive = FakeDrive();
    final repo = MemorySplitRepository();
    await repo.createFriend('保留這位');
    await LedgerBackupService(repo, drive).backUp(accountA);
    await showBackup(t, repo, drive);
    expect(find.textContaining('上次成功備份　'), findsOneWidget);
    drive.nextAccount = accountB;
    await tap(t, find.text('切換 Google 帳戶'));
    expect(find.text(accountB), findsOneWidget);
    expect(find.text(accountA), findsNothing);
    expect(find.textContaining('上次成功備份　'), findsNothing);
    expect(find.text('這個帳戶尚無備份'), findsOneWidget);
    await tap(t, find.text('解除連結'));
    expect(find.text('尚未連結 Google 帳戶'), findsOneWidget);
    expect((await repo.load()).friends.single.name, '保留這位');
    expect(drive.storage[accountA]!.length, 1);
    expect(drive.storage[accountB], isEmpty);
  });

  testWidgets('模擬 A 備份、B 選擇同帳戶；預覽與最後確認都可取消，確認後分攤與還款結果相同', (t) async {
    final drive = FakeDrive();
    final source = MemorySplitRepository();
    await seedLedger(source);
    final before = await source.load();
    await LedgerBackupService(source, drive).backUp(accountA);
    final target = MemorySplitRepository();
    await showBackup(t, target, drive);

    await openPreview(t);
    expect(find.textContaining('快速聚餐　1 餐'), findsOneWidget);
    expect(find.textContaining('還款　1 筆'), findsOneWidget);
    await tap(t, find.text('取消'));
    expect(await target.isLedgerEmpty(), isTrue);
    await openPreview(t);
    await tap(t, find.text('繼續'));
    expect(find.text('確認還原到這台裝置？'), findsOneWidget);
    await tap(t, find.text('取消'));
    expect(await target.isLedgerEmpty(), isTrue);

    await openPreview(t);
    await tap(t, find.text('繼續'));
    await tap(t, find.text('確認還原'));
    expect(find.textContaining('還原完成'), findsOneWidget);
    final after = await target.load();
    expect(after.groups.single.id, before.groups.single.id);
    expect(
      after.groups.single.expenses.single.shares,
      before.groups.single.expenses.single.shares,
    );
    expect(after.groups.single.repayments.single.amount, 10000);
    expect(
      BalanceService.balances(after.groups.single),
      BalanceService.balances(before.groups.single),
    );
    expect(
      after.quickMeals.single.shareText,
      before.quickMeals.single.shareText,
    );
    expect(await target.readFriendAccount(after.friends.single.id), isNull);
    expect(
      await source.readFriendAccount(before.friends.single.id),
      '000012345678',
    );
    expect(drive.uploadCalls, 1);
  });
}
