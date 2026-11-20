import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../domain.dart';
import 'repository.dart';
import 'schema.dart';

typedef _Row = Map<String, Object?>;

class SqliteSplitRepository extends LedgerRepository {
  SqliteSplitRepository({this.factory, this.path});

  final DatabaseFactory? factory;
  final String? path;
  Future<Database>? _opening;
  Future<Database> get _database => _opening ??= _open().onError((
    Object error,
    StackTrace stack,
  ) {
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
        version: 1,
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
    return {for (final row in rows) row['key'] as String: row['value'] as String};
  }

  @override
  Future<AppData> load() async {
    final db = await _database;
    return db.transaction((tx) async {
      final settings = await _settings(tx);
      return AppData(
        defaultName: settings['default_name'] ?? '我',
        appearance: settings['appearance'] == AppAppearance.dark.name
            ? AppAppearance.dark
            : AppAppearance.light,
        groups: await _loadGroups(tx),
      );
    });
  }

  @override
  Future<void> writeName(String value) => _writeSetting('default_name', value);

  @override
  Future<void> setAppearance(AppAppearance value) =>
      _writeSetting('appearance', value.name);

  Future<void> _writeSetting(String key, String value) async {
    final db = await _database;
    await db.insert('app_settings', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<String> insertGroup(Ledger Function(String) build) async {
    final db = await _database;
    return db.transaction((tx) async {
      final settings = await _settings(tx);
      final group = build(settings['default_name'] ?? '我');
      final batch = tx.batch();
      batch.insert('groups', _groupRow(group));
      for (final member in group.members) {
        batch.insert('members', _memberRow(group.id, member));
      }
      await batch.commit(noResult: true);
      return group.id;
    });
  }

  @override
  Future<void> changeGroup(String id, Ledger Function(Ledger) update) async {
    final db = await _database;
    await db.transaction((tx) async {
      final group = (await _loadGroups(tx, id)).firstOrNull;
      if (group == null) throw const FormatException('找不到群組');
      final next = update(group);
      final batch = tx.batch();
      batch.update('groups', _groupRow(next), where: 'id = ?', whereArgs: [id]);
      final members = {for (final member in group.members) member.id: member};
      for (final member in next.members) {
        final old = members[member.id];
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
        for (final share in expense.shares.entries) {
          batch.insert('expense_splits', {
            'group_id': id,
            'expense_id': expense.id,
            'member_id': share.key,
            'amount_minor': share.value,
            'input_weight': expense.inputs[share.key],
          });
        }
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
