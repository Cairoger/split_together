import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../domain.dart';

typedef _Row = Map<String, Object?>;

/// V1 的金額單位為新台幣分。資料欄位刻意獨立於 SQLite 和裝置設定。
final class LedgerBackup {
  LedgerBackup._(this.data, this.createdAt);

  factory LedgerBackup.fromData(AppData data, DateTime createdAt) =>
      LedgerBackup._(_readData(_writeData(data)), createdAt.toUtc());

  static const maxBytes = 32 * 1024 * 1024;
  static const _format = 'SplitTogether-Ledger';
  static const _version = 1;
  final AppData data;
  final DateTime createdAt;

  Future<Uint8List> encode() async {
    final content = _content(createdAt, _writeData(data));
    final bytes = utf8.encode(
      jsonEncode({...content, 'sha256': await _checksum(content)}),
    );
    if (bytes.length > maxBytes) {
      throw const FormatException('帳本已超過單一備份的大小上限（32 MB）。');
    }
    return bytes;
  }

  static Future<LedgerBackup> decode(List<int> bytes) async {
    if (bytes.isEmpty || bytes.length > maxBytes) _invalid();
    Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      _invalid();
    }
    if (json is! _Row || json['format'] != _format) _invalid();
    if (json['version'] is! int) _invalid();
    if (json['version'] != _version) {
      throw const FormatException('這個備份格式版本尚未支援。請確認 App 版本。');
    }
    final row = _fields(json, 'format version createdAt data sha256');
    final date = _date(row['createdAt']);
    final data = _fields(row['data'], 'currency groups friends quickMeals');
    if (row['sha256'] != await _checksum(_content(date, data))) {
      throw const FormatException('備份完整性檢查失敗，請選擇其他備份。');
    }
    return LedgerBackup._(_readData(data), date);
  }

  static _Row _content(DateTime date, _Row data) => {
    'format': _format,
    'version': _version,
    'createdAt': _iso(date),
    'data': data,
  };

  static Future<String> _checksum(_Row content) async {
    final digest = await Sha256().hash(utf8.encode(jsonEncode(content)));
    return digest.bytes.map((n) => n.toRadixString(16).padLeft(2, '0')).join();
  }
}

Never _invalid() => throw const FormatException('備份資料不完整或不符合帳本格式，請選擇其他備份。');

_Row _fields(Object? value, String names) {
  final keys = names.split(' ');
  if (value is! _Row ||
      value.length != keys.length ||
      !keys.every(value.containsKey)) {
    _invalid();
  }
  return value;
}

String _string(Object? value, {bool allowEmpty = false}) {
  if (value is! String || (!allowEmpty && value.trim().isEmpty)) _invalid();
  return value;
}

bool _flag(Object? value) => value is bool ? value : _invalid();

int _integer(Object? value) => value is int ? value : _invalid();

int _amount(Object? value) {
  final amount = _integer(value);
  if (amount <= 0 || amount > Money.maxMinor) _invalid();
  return amount;
}

String _iso(DateTime date) => date.toUtc().toIso8601String();

DateTime _date(Object? value) {
  if (value is! String || !value.endsWith('Z')) _invalid();
  final date = DateTime.tryParse(value);
  // DateTime.parse 會將不存在的日期進位；只接受本格式寫出的原始 UTC 日期。
  if (date == null || _iso(date) != value) _invalid();
  return date;
}

List<T> _list<T>(Object? value, T Function(Object?) read) {
  if (value is! List<Object?>) _invalid();
  return List.unmodifiable(value.map(read));
}

Map<String, T> _map<T>(Object? value, T Function(Object?) read) {
  if (value is! _Row) _invalid();
  return Map.unmodifiable({
    for (final e in value.entries) _string(e.key): read(e.value),
  });
}

String _unique(Object? value, Set<String> seen) {
  final id = _string(value);
  if (!seen.add(id)) _invalid();
  return id;
}

_Row _writeData(AppData data) => {
  'currency': 'TWD',
  'friends': [
    for (final f in data.friends)
      {'id': f.id, 'name': f.name, 'archived': f.isArchived},
  ],
  'groups': [for (final g in data.groups) _writeGroup(g)],
  'quickMeals': [
    for (final m in data.quickMeals)
      {
        'id': m.id,
        'createdAt': _iso(m.createdAt),
        'totalMinor': m.total,
        'payerId': m.payerId,
        'people': m.people,
        'shares': m.shares,
      },
  ],
};

_Row _writeGroup(Ledger g) => {
  'id': g.id,
  'name': g.name,
  'category': g.category,
  'archived': g.archived,
  'createdAt': _iso(g.createdAt),
  'updatedAt': _iso(g.updatedAt),
  'members': [
    for (final m in g.members)
      {
        'id': m.id,
        'name': m.name,
        'self': m.isSelf,
        'active': m.isActive,
        'friendId': m.friendId,
        'createdAt': _iso(m.createdAt),
      },
  ],
  'expenses': [
    for (final e in g.expenses)
      {
        'id': e.id,
        'title': e.title,
        'amountMinor': e.amount,
        'payerId': e.payerId,
        'method': e.method.name,
        'category': e.category,
        'spentAt': _iso(e.spentAt),
        'note': e.note,
        'createdAt': _iso(e.createdAt),
        'updatedAt': _iso(e.updatedAt),
        'shares': e.shares,
        'inputs': e.inputs,
      },
  ],
  'repayments': [
    for (final p in g.repayments)
      {
        'id': p.id,
        'fromId': p.fromId,
        'toId': p.toId,
        'amountMinor': p.amount,
        'paidAt': _iso(p.paidAt),
        'note': p.note,
        'createdAt': _iso(p.createdAt),
      },
  ],
};

AppData _readData(_Row data) {
  if (data['currency'] != 'TWD') _invalid();
  final friendIds = <String>{};
  final friends = _list(data['friends'], (raw) {
    final row = _fields(raw, 'id name archived');
    final id = _unique(row['id'], friendIds);
    if (id.startsWith('@')) _invalid(); // 保留給聚餐本人及臨時出席者。
    return SavedFriend(
      id: id,
      name: _string(row['name']),
      isArchived: _flag(row['archived']),
    );
  });
  // SQLite 的主鍵跨群組唯一，群組內的關聯另外檢查。
  final groupIds = <String>{};
  final memberIds = <String>{};
  final expenseIds = <String>{};
  final repaymentIds = <String>{};
  final groups = _list(data['groups'], (raw) {
    final row = _fields(
      raw,
      'id name category archived createdAt updatedAt members expenses repayments',
    );
    final memberNames = <String>{};
    final linkedFriends = <String>{};
    final members = _list(row['members'], (raw) {
      final m = _fields(raw, 'id name self active friendId createdAt');
      final name = _unique(m['name'], memberNames);
      if (name != name.trim()) _invalid();
      final friendId = m['friendId'] == null ? null : _string(m['friendId']);
      final isSelf = _flag(m['self']);
      final isActive = _flag(m['active']);
      if (isSelf && (!isActive || friendId != null)) _invalid();
      if (friendId != null &&
          (!friendIds.contains(friendId) || !linkedFriends.add(friendId))) {
        _invalid();
      }
      return Member(
        id: _unique(m['id'], memberIds),
        name: name,
        isSelf: isSelf,
        isActive: isActive,
        friendId: friendId,
        createdAt: _date(m['createdAt']),
      );
    });
    if (members.where((m) => m.isSelf).length != 1) _invalid();
    final localIds = members.map((m) => m.id).toSet();
    return Ledger(
      id: _unique(row['id'], groupIds),
      name: _string(row['name']),
      category: _string(row['category']),
      archived: _flag(row['archived']),
      createdAt: _date(row['createdAt']),
      updatedAt: _date(row['updatedAt']),
      members: members,
      expenses: _list(
        row['expenses'],
        (e) => _readExpense(e, localIds, expenseIds),
      ),
      repayments: _list(
        row['repayments'],
        (p) => _readRepayment(p, localIds, repaymentIds),
      ),
    );
  });

  final mealIds = <String>{};
  final meals = _list(data['quickMeals'], (raw) {
    final row = _fields(raw, 'id createdAt totalMinor payerId people shares');
    final meal = QuickMeal.recorded(
      id: _unique(row['id'], mealIds),
      createdAt: _date(row['createdAt']),
      total: _amount(row['totalMinor']),
      payerId: _string(row['payerId']),
      people: _map(row['people'], _string),
      shares: _map(row['shares'], _integer),
    );
    if (!meal.people.keys
        .where(meal.needsSavedFriend)
        .every(friendIds.contains)) {
      _invalid();
    }
    return meal;
  });
  return AppData(
    defaultName: '我',
    groups: groups,
    friends: friends,
    quickMeals: meals,
  );
}

Expense _readExpense(Object? raw, Set<String> members, Set<String> expenseIds) {
  final e = _fields(
    raw,
    'id title amountMinor payerId method category spentAt note createdAt updatedAt shares inputs',
  );
  final payerId = _string(e['payerId']);
  final amount = _amount(e['amountMinor']);
  final method = SplitMethod.values
      .where((m) => m.name == e['method'])
      .firstOrNull;
  final shares = _map(e['shares'], _integer);
  final inputs = _map(e['inputs'], _integer);
  if (method == null ||
      !members.contains(payerId) ||
      !shares.keys.every(members.contains)) {
    _invalid();
  }
  if (method == SplitMethod.equal && inputs.isNotEmpty) _invalid();
  final expected = SplitService.divide(
    amount,
    method,
    shares.keys.toList(),
    inputs,
  );
  if (shares.entries.any((s) => expected[s.key] != s.value)) _invalid();
  return Expense(
    id: _unique(e['id'], expenseIds),
    title: _string(e['title']),
    amount: amount,
    payerId: payerId,
    method: method,
    category: _string(e['category']),
    spentAt: _date(e['spentAt']),
    note: _string(e['note'], allowEmpty: true),
    createdAt: _date(e['createdAt']),
    updatedAt: _date(e['updatedAt']),
    shares: shares,
    inputs: inputs,
  );
}

Repayment _readRepayment(
  Object? raw,
  Set<String> members,
  Set<String> repaymentIds,
) {
  final p = _fields(raw, 'id fromId toId amountMinor paidAt note createdAt');
  final from = _string(p['fromId']);
  final to = _string(p['toId']);
  if (from == to || !members.contains(from) || !members.contains(to)) {
    _invalid();
  }
  return Repayment(
    id: _unique(p['id'], repaymentIds),
    fromId: from,
    toId: to,
    amount: _amount(p['amountMinor']),
    paidAt: _date(p['paidAt']),
    note: _string(p['note'], allowEmpty: true),
    createdAt: _date(p['createdAt']),
  );
}
