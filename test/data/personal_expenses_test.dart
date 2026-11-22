import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:split_together/data/memory_repository.dart';
import 'package:split_together/data/repository.dart';
import 'package:split_together/data/schema.dart';
import 'package:split_together/data/sqlite_repository.dart';
import 'package:split_together/domain.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _mealDate = DateTime.utc(2026, 10, 31, 8, 30);

void main() {
  sqfliteFfiInit();
  for (final sqlite in [false, true]) {
    group(sqlite ? 'SQLite 個人支出' : '記憶體個人支出', () {
      late SplitRepository repo;

      setUp(() {
        repo = sqlite
            ? SqliteSplitRepository(
                factory: databaseFactoryFfi,
                path: inMemoryDatabasePath,
              )
            : MemorySplitRepository();
      });
      tearDown(() => repo.close());

      test('四人吃 1200 元，墊付或欠款皆只記本人 300 元，重送與取消只改該餐記帳狀態', () async {
        final lin = await repo.createFriend('小林');
        final people = {
          quickMealSelfId: '我',
          lin: '小林',
          await repo.createFriend('小陳'): '小陳',
          await repo.createFriend('小李'): '小李',
        };
        final meals = [
          for (final payer in [quickMealSelfId, lin])
            QuickMeal(
              id: 'meal-$payer',
              createdAt: _mealDate,
              total: 120000,
              payerId: payer,
              people: people,
            ),
        ];
        for (final meal in meals) {
          await repo.saveQuickMeal(meal);
        }
        expect(
          (await repo.load()).quickMeals.where(
            (m) => m.recordedAsPersonalExpense,
          ),
          isEmpty,
        );
        expect(
          meals.first.transfers.fold(0, (sum, t) => sum + t.amount),
          90000,
        );
        expect(
          meals.last.transfers
              .singleWhere((t) => t.fromId == quickMealSelfId)
              .amount,
          30000,
        );
        for (final meal in meals) {
          await Future.wait([
            repo.setQuickMealPersonalExpense(meal.id, true),
            repo.setQuickMealPersonalExpense(meal.id, true),
          ]);
          await repo.saveQuickMeal(meal);
        }
        final saved = (await repo.load()).quickMeals;
        expect(
          saved
              .where((m) => m.recordedAsPersonalExpense)
              .map((m) => m.selfShare),
          [30000, 30000],
        );
        await repo.setQuickMealPersonalExpense(meals.first.id, false);
        await repo.setQuickMealPersonalExpense(meals.first.id, false);
        final after = (await repo.load()).quickMeals;
        expect(after, hasLength(2));
        expect(
          after.where((m) => m.recordedAsPersonalExpense).single.id,
          meals.last.id,
        );
        expect(
          after.singleWhere((m) => m.id == meals.first.id).shareText,
          meals.first.shareText,
        );
      });

      test('沒有本人、本人份額為零或聚餐不存在，均無法記入', () async {
        final first = await repo.createFriend('朋友甲');
        final second = await repo.createFriend('朋友乙');
        for (final other in [second, quickMealSelfId]) {
          final meal = QuickMeal.recorded(
            id: 'tiny-$other',
            createdAt: _mealDate,
            people: {
              first: '朋友甲',
              other: other == quickMealSelfId ? '我' : '朋友乙',
            },
            payerId: first,
            total: 1,
            shares: {first: 1, other: 0},
          );
          await repo.saveQuickMeal(meal);
          expect(meal.selfShare, 0);
          await expectLater(
            repo.setQuickMealPersonalExpense(meal.id, true),
            throwsFormatException,
          );
        }
        await expectLater(
          repo.setQuickMealPersonalExpense('不存在', true),
          throwsFormatException,
        );
        final saved = (await repo.load()).quickMeals;
        expect(saved, hasLength(2));
        expect(saved.where((m) => m.recordedAsPersonalExpense), isEmpty);
      });
    });
  }

  test('第 4 版升級保留聚餐原始尾差與封存群組，失敗可重試，記入及取消都跨重啟保存', () async {
    final directory = await Directory.systemTemp.createTemp(
      'split-personal-expense-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = p.join(directory.path, 'old-ledger.db');
    const oldFriendId = '00000000000000000000000000000001';
    final old = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 4,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, version) => migrateLedger(db, 0, version),
      ),
    );
    await old.transaction((tx) async {
      final stamp = _mealDate.toIso8601String();
      await tx.insert('groups', {
        'id': 'g',
        'name': '舊帳本',
        'category': '聚餐',
        'is_archived': 1,
        'created_at': stamp,
        'updated_at': stamp,
      });
      await tx.insert('members', {
        'id': 'member',
        'group_id': 'g',
        'name': '本人',
        'is_self': 1,
        'is_active': 1,
        'created_at': stamp,
      });
      await tx.insert('friends', {
        'id': oldFriendId,
        'name': '小林',
        'is_archived': 1,
      });
      await tx.insert('quick_meals', {
        'id': 'old',
        'created_at': _mealDate.microsecondsSinceEpoch,
        'total_minor': 101,
        'payer_id': oldFriendId,
      });
      for (final (id, name, share) in [
        (quickMealSelfId, '本人', 51),
        (oldFriendId, '小林', 50),
      ]) {
        await tx.insert('quick_meal_people', {
          'meal_id': 'old',
          'person_id': id,
          'name': name,
          'share_minor': share,
        });
      }
    });
    await old.close();

    SqliteSplitRepository open() =>
        SqliteSplitRepository(factory: databaseFactoryFfi, path: path);
    var repo = open();
    addTearDown(() => repo.close());
    final upgraded = await repo.load();
    expect(upgraded.quickMeals.single.recordedAsPersonalExpense, isFalse);
    expect(upgraded.quickMeals.single.createdAt, _mealDate);
    expect(upgraded.quickMeals.single.shares, {
      quickMealSelfId: 51,
      oldFriendId: 50,
    });
    expect(upgraded.groups.single.name, '舊帳本');
    expect(upgraded.groups.single.archived, isTrue);
    expect(upgraded.groups.single.self.id, 'member');
    expect(upgraded.friends.single.isArchived, isTrue);
    final db = await databaseFactoryFfi.openDatabase(path);
    expect(await db.getVersion(), 5);
    await db.execute(
      """CREATE TRIGGER reject_record BEFORE UPDATE ON quick_meals
      BEGIN SELECT RAISE(ABORT, '測試寫入失敗'); END""",
    );
    await expectLater(
      repo.setQuickMealPersonalExpense('old', true),
      throwsA(isA<DatabaseException>()),
    );
    expect(
      (await repo.load()).quickMeals.single.recordedAsPersonalExpense,
      isFalse,
    );
    await db.execute('DROP TRIGGER reject_record');
    await repo.setQuickMealPersonalExpense('old', true);

    await repo.close();
    repo = open();
    final recorded = (await repo.load()).quickMeals.single;
    expect(recorded.recordedAsPersonalExpense, isTrue);
    expect(recorded.selfShare, 51);
    expect(recorded.shareText, upgraded.quickMeals.single.shareText);
    await repo.setQuickMealPersonalExpense('old', false);
    await repo.close();
    repo = open();
    final removed = (await repo.load()).quickMeals.single;
    expect(removed.recordedAsPersonalExpense, isFalse);
    expect(removed.shareText, recorded.shareText);
  });
}
