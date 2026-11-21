import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../domain.dart';
import 'account_cipher.dart';
import 'ledger_backup.dart';
import 'repository.dart';
import 'schema.dart';

typedef _Row = Map<String, Object?>;

class SqliteSplitRepository extends LedgerRepository {
  SqliteSplitRepository({this.factory, this.path, AccountCipher? accountCipher})
    : _cipher = accountCipher ?? AccountCipher();

  final DatabaseFactory? factory;
  final String? path;
  final AccountCipher _cipher;
  Future<Database>? _opening;
  Future<Database> get _database =>
      _opening ??= _open().onError((Object error, StackTrace stack) {
        // This runs after assigning the pending Future, even if _open failed
        // before its first await. A retry can always open a fresh connection.
        _opening = null;
        Error.throwWithStackTrace(error, stack);
      });

  Future<Database> _open() async {
    final driver = factory ?? databaseFactory;
    final location =
        path ?? p.join(await driver.getDatabasesPath(), 'split_together.db');
    return driver.openDatabase(
      location,
      options: OpenDatabaseOptions(
        version: ledgerSchemaVersion,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, version) => migrateLedger(db, 0, version),
        onUpgrade: migrateLedger,
      ),
    );
  }

  @override
  Future<void> close() async {
    final pending = _opening;
    if (pending != null) await (await pending).close();
    _opening = null;
  }

  Future<Map<String, String>> _settings(DatabaseExecutor db) async {
    final rows = await db.query('app_settings');
    return {
      for (final row in rows) row['key'] as String: row['value'] as String,
    };
  }

  @override
  Future<AppData> load() async {
    final db = await _database;
    return db.transaction((tx) async {
      final settings = await _settings(tx);
      return AppData(
        defaultName: settings['default_name'] ?? '我',
        hasSeenExampleResult: settings['example_result_seen'] == 'true',
        appearance: settings['appearance'] == AppAppearance.dark.name
            ? AppAppearance.dark
            : AppAppearance.light,
        groups: await _loadGroups(tx),
        quickMeals: await _loadQuickMeals(tx),
        bankApp: _decodeBankApp(settings['bank_app']),
        friends: await _loadFriends(tx, includeBankDetails: true),
      );
    });
  }

  Future<List<SavedFriend>> _loadFriends(
    DatabaseExecutor tx, {
    bool includeBankDetails = false,
  }) async {
    final friends = await tx.query(
      'friends',
      columns: [
        'id',
        'name',
        'is_archived',
        if (includeBankDetails) ...['bank_code', 'last_four'],
      ],
      orderBy: 'name, id',
    );
    return [
      for (final row in friends)
        SavedFriend(
          id: row['id'] as String,
          name: row['name'] as String,
          isArchived: row['is_archived'] == 1,
          bankCode: row['bank_code'] as String?,
          lastFour: row['last_four'] as String?,
        ),
    ];
  }

  @override
  Future<LedgerBackup> createBackup(DateTime createdAt) async {
    final db = await _database;
    final data = await db.transaction(
      (tx) async => AppData(
        defaultName: '我',
        friends: await _loadFriends(tx),
        groups: await _loadGroups(tx),
        quickMeals: await _loadQuickMeals(tx),
      ),
    );
    return LedgerBackup.fromData(data, createdAt);
  }

  Future<bool> _isLedgerEmpty(DatabaseExecutor db) async {
    // 其餘帳目資料表都有指向群組或聚餐的外鍵。裝置設定不算帳目。
    final rows = await db.rawQuery('''
      SELECT NOT (
        EXISTS(SELECT 1 FROM groups) OR EXISTS(SELECT 1 FROM friends)
        OR EXISTS(SELECT 1 FROM quick_meals)
      ) AS empty
    ''');
    return rows.single['empty'] == 1;
  }

  @override
  Future<bool> isLedgerEmpty() async => _isLedgerEmpty(await _database);

  @override
  Future<void> restoreBackup(LedgerBackup backup) async {
    final db = await _database;
    await db.transaction((tx) async {
      if (!await _isLedgerEmpty(tx)) {
        throw const FormatException(nonEmptyLedgerMessage);
      }
      final batch = tx.batch();
      for (final friend in backup.data.friends) {
        batch.insert('friends', {
          'id': friend.id,
          'name': friend.name,
          'is_archived': friend.isArchived ? 1 : 0,
        });
      }
      for (final group in backup.data.groups) {
        batch.insert('groups', _groupRow(group));
        for (final member in group.members) {
          batch.insert('members', _memberRow(group.id, member));
        }
        for (final expense in group.expenses) {
          batch.insert('expenses', _expenseRow(group.id, expense));
          _insertExpenseSplits(batch, group.id, expense);
        }
        for (final payment in group.repayments) {
          batch.insert('settlements', _paymentRow(group.id, payment));
        }
      }
      for (final meal in backup.data.quickMeals) {
        _insertQuickMeal(batch, meal);
      }
      await batch.commit(noResult: true);
    });
  }

  @override
  Future<String> createFriend(String name) async {
    final friend = newSavedFriend(name);
    final db = await _database;
    await _insertFriends(db, [friend]);
    return friend.id;
  }

  Future<void> _updateActiveFriend(
    String id,
    Map<String, Object?> values,
  ) async {
    final db = await _database;
    final count = await db.update(
      'friends',
      values,
      where: 'id = ? AND is_archived = 0',
      whereArgs: [id],
    );
    if (count == 0) throw const FormatException('找不到常用朋友');
  }

  @override
  Future<void> renameFriend(String id, String name) async =>
      _updateActiveFriend(id, {'name': validateFriendName(name)});

  @override
  Future<void> archiveFriend(String id) =>
      _updateActiveFriend(id, {'is_archived': 1});

  @override
  Future<void> saveQuickMeal(QuickMeal meal) async {
    final db = await _database;
    await db.transaction((tx) async {
      final prior = await _loadQuickMeals(tx, id: meal.id);
      if (prior.isNotEmpty) {
        prior.single.verifyRetry(meal);
        return;
      }
      for (final id in meal.people.keys.where(meal.needsSavedFriend)) {
        await _checkActiveFriend(tx, id);
      }
      final batch = tx.batch();
      _insertQuickMeal(batch, meal);
      await batch.commit(noResult: true);
    });
  }

  Future<List<QuickMeal>> _loadQuickMeals(
    DatabaseExecutor tx, {
    String? id,
  }) async {
    final args = id == null ? null : [id];
    final meals = await tx.query(
      'quick_meals',
      where: id == null ? null : 'id = ?',
      whereArgs: args,
      orderBy: 'created_at DESC, id DESC',
    );
    if (meals.isEmpty) return [];
    final members = await tx.query(
      'quick_meal_people',
      where: id == null ? null : 'meal_id = ?',
      whereArgs: args,
      orderBy: 'rowid',
    );
    final participants = <String, List<_Row>>{};
    for (final row in members) {
      (participants[row['meal_id'] as String] ??= []).add(row);
    }
    return [
      for (final row in meals)
        _readQuickMeal(row, participants[row['id']] ?? const []),
    ];
  }

  QuickMeal _readQuickMeal(_Row row, List<_Row> members) => QuickMeal.recorded(
    id: row['id'] as String,
    createdAt: DateTime.fromMicrosecondsSinceEpoch(
      row['created_at'] as int,
      isUtc: true,
    ),
    total: row['total_minor'] as int,
    payerId: row['payer_id'] as String,
    people: {
      for (final m in members) m['person_id'] as String: m['name'] as String,
    },
    shares: {
      for (final m in members)
        m['person_id'] as String: m['share_minor'] as int,
    },
  );

  @override
  Future<void> writeName(String value) => _writeSetting('default_name', value);

  @override
  Future<void> setAppearance(AppAppearance value) =>
      _writeSetting('appearance', value.name);

  @override
  Future<void> markExampleResultSeen() =>
      _writeSetting('example_result_seen', 'true');

  Future<void> _writeSetting(String key, String value) async {
    final db = await _database;
    await db.insert('app_settings', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  BankAppChoice? _decodeBankApp(String? raw) {
    if (raw == null) return null;
    try {
      return switch (jsonDecode(raw)) {
        {'id': final String id, 'label': final String label} => BankAppChoice(
          id: id,
          label: label,
        ),
        _ => null,
      };
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> setBankApp(BankAppChoice? choice) async {
    if (choice == null) {
      final db = await _database;
      await db.delete(
        'app_settings',
        where: 'key = ?',
        whereArgs: ['bank_app'],
      );
    } else {
      await _writeSetting(
        'bank_app',
        jsonEncode({'id': choice.id, 'label': choice.label}),
      );
    }
  }

  Future<_Row> _accountRow(
    DatabaseExecutor tx,
    String id,
    FriendAccount? account,
  ) async {
    if (account == null) {
      return {'bank_code': null, 'last_four': null, 'account_cipher': null};
    }
    // The database transaction serializes first use of the device key.
    final encryptedRows = await tx.rawQuery(
      'SELECT 1 FROM friends WHERE account_cipher IS NOT NULL LIMIT 1',
    );
    final cipher = await _cipher.encrypt(
      id,
      account.code,
      account.number,
      canCreateKey: encryptedRows.isEmpty,
    );
    return {
      'bank_code': account.code,
      'last_four': account.number.substring(account.number.length - 4),
      'account_cipher': cipher,
    };
  }

  @override
  Future<void> setFriendAccount(
    String friendId,
    String? bankCode,
    String? accountNumber,
  ) async {
    final account = validateFriendAccount(bankCode, accountNumber);
    final db = await _database;
    await db.transaction((tx) async {
      final values = await _accountRow(tx, friendId, account);
      final count = await tx.update(
        'friends',
        values,
        where: 'id = ?',
        whereArgs: [friendId],
      );
      if (count != 1) throw const FormatException('找不到常用朋友');
    });
  }

  @override
  Future<String?> readFriendAccount(String friendId) async {
    final db = await _database;
    final rows = await db.query(
      'friends',
      columns: ['bank_code', 'account_cipher'],
      where: 'id = ?',
      whereArgs: [friendId],
    );
    if (rows.isEmpty) throw const FormatException('找不到常用朋友');
    final data = rows.single['account_cipher'] as Uint8List?;
    if (data == null) return null;
    return _cipher.decrypt(friendId, rows.single['bank_code'] as String, data);
  }

  Future<void> _insertFriends(
    DatabaseExecutor tx,
    List<NewFriend> friends,
  ) async {
    for (final friend in friends) {
      await tx.insert('friends', {
        'id': friend.id,
        'name': friend.name,
        ...await _accountRow(tx, friend.id, friend.account),
      });
    }
  }

  Future<void> _checkActiveFriend(DatabaseExecutor tx, String? id) async {
    if (id == null) return;
    final rows = await tx.query(
      'friends',
      columns: ['id'],
      where: 'id = ? AND is_archived = 0',
      whereArgs: [id],
    );
    if (rows.isEmpty) throw const FormatException('找不到常用朋友');
  }

  @override
  Future<String> insertGroup(
    Ledger Function(String) build, {
    List<NewFriend> newFriends = const [],
  }) async {
    final db = await _database;
    return db.transaction((tx) async {
      final settings = await _settings(tx);
      final group = build(settings['default_name'] ?? '我');
      await _insertFriends(tx, newFriends);
      final batch = tx.batch();
      batch.insert('groups', _groupRow(group));
      for (final member in group.members) {
        await _checkActiveFriend(tx, member.friendId);
        batch.insert('members', _memberRow(group.id, member));
      }
      await batch.commit(noResult: true);
      return group.id;
    });
  }

  @override
  Future<void> changeGroup(
    String id,
    Ledger Function(Ledger) update, {
    List<NewFriend> newFriends = const [],
  }) async {
    final db = await _database;
    await db.transaction((tx) async {
      final group = (await _loadGroups(tx, id)).firstOrNull;
      if (group == null) throw const FormatException('找不到群組');
      final next = update(group);
      await _insertFriends(tx, newFriends);
      final batch = tx.batch();
      batch.update('groups', _groupRow(next), where: 'id = ?', whereArgs: [id]);
      final members = {for (final member in group.members) member.id: member};
      for (final member in next.members) {
        final old = members[member.id];
        if (old?.friendId != member.friendId) {
          await _checkActiveFriend(tx, member.friendId);
        }
        if (old == null) {
          batch.insert('members', _memberRow(id, member));
        } else if (!identical(old, member)) {
          batch.update(
            'members',
            _memberRow(id, member),
            where: 'id = ?',
            whereArgs: [member.id],
          );
        }
      }
      final expenses = {
        for (final expense in group.expenses) expense.id: expense,
      };
      for (final expense in next.expenses) {
        final old = expenses.remove(expense.id);
        if (identical(old, expense)) continue;
        if (old == null) {
          batch.insert('expenses', _expenseRow(id, expense));
        } else {
          batch.update(
            'expenses',
            _expenseRow(id, expense),
            where: 'id = ?',
            whereArgs: [expense.id],
          );
          batch.delete(
            'expense_splits',
            where: 'expense_id = ?',
            whereArgs: [expense.id],
          );
        }
        _insertExpenseSplits(batch, id, expense);
      }
      for (final removed in expenses.keys) {
        batch.delete('expenses', where: 'id = ?', whereArgs: [removed]);
      }
      final payments = group.repayments.map((r) => r.id).toSet();
      for (final payment in next.repayments) {
        if (!payments.remove(payment.id)) {
          batch.insert('settlements', _paymentRow(id, payment));
        }
      }
      for (final removed in payments) {
        batch.delete('settlements', where: 'id = ?', whereArgs: [removed]);
      }
      await batch.commit(noResult: true);
    });
  }
}

void _insertQuickMeal(Batch batch, QuickMeal meal) {
  batch.insert('quick_meals', {
    'id': meal.id,
    'created_at': meal.createdAt.microsecondsSinceEpoch,
    'total_minor': meal.total,
    'payer_id': meal.payerId,
  });
  for (final person in meal.people.entries) {
    batch.insert('quick_meal_people', {
      'meal_id': meal.id,
      'person_id': person.key,
      'name': person.value,
      'share_minor': meal.shares[person.key]!,
    });
  }
}

void _insertExpenseSplits(Batch batch, String groupId, Expense expense) {
  for (final share in expense.shares.entries) {
    batch.insert('expense_splits', {
      'group_id': groupId,
      'expense_id': expense.id,
      'member_id': share.key,
      'amount_minor': share.value,
      'input_weight': expense.inputs[share.key],
    });
  }
}

// Fixed fractional-second width preserves chronological TEXT index ordering.
String _utc(DateTime value) {
  final iso = value.toUtc().toIso8601String();
  return '${iso.substring(0, iso.length - 1).padRight(26, '0')}Z';
}

_Row _groupRow(Ledger g) => {
  'id': g.id,
  'name': g.name,
  'category': g.category,
  'currency': 'TWD',
  'is_archived': g.archived ? 1 : 0,
  'created_at': _utc(g.createdAt),
  'updated_at': _utc(g.updatedAt),
};

_Row _memberRow(String groupId, Member m) => {
  'id': m.id,
  'group_id': groupId,
  'name': m.name,
  'is_self': m.isSelf ? 1 : 0,
  'is_active': m.isActive ? 1 : 0,
  'friend_id': m.friendId,
  'created_at': _utc(m.createdAt),
};

_Row _expenseRow(String groupId, Expense e) => {
  'id': e.id,
  'group_id': groupId,
  'title': e.title,
  'amount_minor': e.amount,
  'payer_member_id': e.payerId,
  'split_method': e.method.name,
  'category': e.category,
  'spent_at': _utc(e.spentAt),
  'note': e.note,
  'created_at': _utc(e.createdAt),
  'updated_at': _utc(e.updatedAt),
};

_Row _paymentRow(String groupId, Repayment r) => {
  'id': r.id,
  'group_id': groupId,
  'from_member_id': r.fromId,
  'to_member_id': r.toId,
  'amount_minor': r.amount,
  'paid_at': _utc(r.paidAt),
  'note': r.note,
  'created_at': _utc(r.createdAt),
};

Future<List<Ledger>> _loadGroups(DatabaseExecutor tx, [String? groupId]) async {
  final args = groupId == null ? null : [groupId];
  final groups = await tx.query(
    'groups',
    where: groupId == null ? null : 'id = ?',
    whereArgs: args,
    orderBy: 'updated_at DESC, id',
  );
  if (groups.isEmpty) return [];
  final where = groupId == null ? null : 'group_id = ?';
  Future<List<_Row>> rows(String table, [String? order]) =>
      tx.query(table, where: where, whereArgs: args, orderBy: order);

  final members = <String, List<Member>>{};
  for (final row in await rows('members', 'is_self DESC, created_at, rowid')) {
    (members[row['group_id'] as String] ??= []).add(
      Member(
        id: row['id'] as String,
        name: row['name'] as String,
        isSelf: row['is_self'] == 1,
        isActive: row['is_active'] == 1,
        friendId: row['friend_id'] as String?,
        createdAt: DateTime.parse(row['created_at'] as String),
      ),
    );
  }
  final shares = <String, Map<String, int>>{};
  final inputs = <String, Map<String, int>>{};
  for (final row in await rows('expense_splits', 'rowid')) {
    final expenseId = row['expense_id'] as String;
    final memberId = row['member_id'] as String;
    (shares[expenseId] ??= {})[memberId] = row['amount_minor'] as int;
    final input = row['input_weight'] as int?;
    if (input != null) (inputs[expenseId] ??= {})[memberId] = input;
  }
  final expenses = <String, List<Expense>>{};
  for (final row in await rows(
    'expenses',
    'spent_at DESC, created_at DESC, id',
  )) {
    final id = row['id'] as String;
    (expenses[row['group_id'] as String] ??= []).add(
      Expense(
        id: id,
        title: row['title'] as String,
        payerId: row['payer_member_id'] as String,
        amount: row['amount_minor'] as int,
        method: SplitMethod.values.byName(row['split_method'] as String),
        category: row['category'] as String,
        spentAt: DateTime.parse(row['spent_at'] as String),
        note: row['note'] as String,
        createdAt: DateTime.parse(row['created_at'] as String),
        updatedAt: DateTime.parse(row['updated_at'] as String),
        shares: shares[id]!,
        inputs: inputs[id] ?? {},
      ),
    );
  }
  final repayments = <String, List<Repayment>>{};
  for (final row in await rows(
    'settlements',
    'paid_at DESC, created_at DESC, id',
  )) {
    (repayments[row['group_id'] as String] ??= []).add(
      Repayment(
        id: row['id'] as String,
        fromId: row['from_member_id'] as String,
        toId: row['to_member_id'] as String,
        amount: row['amount_minor'] as int,
        paidAt: DateTime.parse(row['paid_at'] as String),
        note: row['note'] as String,
        createdAt: DateTime.parse(row['created_at'] as String),
      ),
    );
  }
  return [
    for (final row in groups)
      Ledger(
        id: row['id'] as String,
        name: row['name'] as String,
        category: row['category'] as String,
        archived: row['is_archived'] == 1,
        createdAt: DateTime.parse(row['created_at'] as String),
        updatedAt: DateTime.parse(row['updated_at'] as String),
        members: members[row['id']]!,
        expenses: expenses[row['id']] ?? [],
        repayments: repayments[row['id']] ?? [],
      ),
  ];
}
