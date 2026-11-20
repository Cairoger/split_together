import 'package:sqflite/sqflite.dart';

import '../domain.dart';

// sqflite runs version callbacks inside its opening transaction. Extend the
// migration sequence here when adding a version, keeping existing records.
Future<void> migrateLedger(Database db, int oldVersion, int newVersion) async {
  if (oldVersion != 0 || newVersion != 1) {
    throw StateError('尚未支援此資料庫版本，請檢查應用程式版本');
  }
  final batch = db.batch();
  for (final statement in _schemaV1) {
    batch.execute(statement);
  }
  await batch.commit(noResult: true);
}

const _schemaV1 = [
  '''CREATE TABLE app_settings (
    key TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL
  )''',
  '''CREATE TABLE groups (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL CHECK (length(trim(name)) > 0),
    category TEXT NOT NULL,
    currency TEXT NOT NULL DEFAULT 'TWD' CHECK (currency = 'TWD'),
    is_archived INTEGER NOT NULL CHECK (is_archived IN (0,1)),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  )''',
  '''CREATE TABLE members (
    id TEXT PRIMARY KEY NOT NULL,
    group_id TEXT NOT NULL REFERENCES groups(id),
    name TEXT NOT NULL CHECK (length(name) > 0 AND name = trim(name)),
    is_self INTEGER NOT NULL CHECK (is_self IN (0,1)),
    is_active INTEGER NOT NULL CHECK (is_active IN (0,1)),
    created_at TEXT NOT NULL,
    CHECK (is_self = 0 OR is_active = 1),
    UNIQUE (group_id, name),
    UNIQUE (group_id, id)
  )''',
  'CREATE UNIQUE INDEX one_self_per_group ON members(group_id) WHERE is_self = 1',
  '''CREATE TABLE expenses (
    id TEXT PRIMARY KEY NOT NULL,
    group_id TEXT NOT NULL REFERENCES groups(id),
    title TEXT NOT NULL CHECK (length(trim(title)) > 0),
    amount_minor INTEGER NOT NULL CHECK (amount_minor BETWEEN 1 AND ${Money.maxMinor}),
    payer_member_id TEXT NOT NULL,
    split_method TEXT NOT NULL CHECK (split_method IN ('equal','exact','percent','weight')),
    category TEXT NOT NULL,
    spent_at TEXT NOT NULL,
    note TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE (group_id, id),
    FOREIGN KEY (group_id, payer_member_id) REFERENCES members(group_id, id)
  )''',
  'CREATE INDEX expenses_by_date ON expenses(group_id, spent_at)',
  '''CREATE TABLE expense_splits (
    group_id TEXT NOT NULL,
    expense_id TEXT NOT NULL,
    member_id TEXT NOT NULL,
    amount_minor INTEGER NOT NULL CHECK (amount_minor BETWEEN 0 AND ${Money.maxMinor}),
    input_weight INTEGER,
    PRIMARY KEY (expense_id, member_id),
    FOREIGN KEY (group_id, expense_id) REFERENCES expenses(group_id, id) ON DELETE CASCADE,
    FOREIGN KEY (group_id, member_id) REFERENCES members(group_id, id)
  )''',
  'CREATE INDEX splits_by_group ON expense_splits(group_id, expense_id)',
  '''CREATE TABLE settlements (
    id TEXT PRIMARY KEY NOT NULL,
    group_id TEXT NOT NULL REFERENCES groups(id),
    from_member_id TEXT NOT NULL,
    to_member_id TEXT NOT NULL,
    amount_minor INTEGER NOT NULL CHECK (amount_minor BETWEEN 1 AND ${Money.maxMinor}),
    paid_at TEXT NOT NULL,
    note TEXT NOT NULL,
    created_at TEXT NOT NULL,
    CHECK (from_member_id <> to_member_id),
    FOREIGN KEY (group_id, from_member_id) REFERENCES members(group_id, id),
    FOREIGN KEY (group_id, to_member_id) REFERENCES members(group_id, id)
  )''',
  'CREATE INDEX settlements_by_date ON settlements(group_id, paid_at)',
];
