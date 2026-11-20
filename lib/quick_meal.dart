part of 'domain.dart';

// 常用朋友以 32 位十六進位 ID 儲存，自己的身分不依賴顯示名稱。
const quickMealSelfId = '@self';

String quickMealGuestId(String mealId, int number) => '@guest:$mealId:$number';

final _guestNumber = RegExp(r'^[1-9][0-9]*$');

class QuickMeal {
  factory QuickMeal({
    required String id,
    required DateTime createdAt,
    required int total,
    required String payerId,
    required Map<String, String> people,
  }) => QuickMeal.recorded(
    id: id,
    createdAt: createdAt,
    total: total,
    payerId: payerId,
    people: people,
    shares: SplitService.divide(
      total,
      SplitMethod.equal,
      people.keys.toList(),
      const {},
    ),
  );

  // 歷史紀錄保留確認當時的姓名與分攤結果，不以目前的名單重新計算。
  QuickMeal.recorded({
    required this.id,
    required DateTime createdAt,
    required this.total,
    required this.payerId,
    required Map<String, String> people,
    required Map<String, int> shares,
  }) : createdAt = createdAt.toUtc(),
       people = Map.unmodifiable(people),
       shares = Map.unmodifiable(shares) {
    if (id.trim().isEmpty) throw const FormatException('缺少聚餐紀錄編號');
    if (people.length < 2) throw const FormatException('請至少選兩位出席者');
    if (!people.containsKey(payerId)) {
      throw const FormatException('請從出席者中選擇付款人');
    }
    if (people.entries.any(
      (p) => p.key.trim().isEmpty || p.value.trim().isEmpty,
    )) {
      throw const FormatException('出席者資料不完整');
    }
    if (total <= 0 ||
        total > Money.maxMinor ||
        shares.length != people.length ||
        !people.keys.every(shares.containsKey) ||
        shares.values.any(
          (n) =>
              n < total ~/ people.length ||
              n > (total + people.length - 1) ~/ people.length,
        ) ||
        shares.values.fold(0, (a, b) => a + b) != total) {
      throw const FormatException('分攤金額與聚餐帳單不符');
    }
  }

  final String id, payerId;
  final DateTime createdAt;
  final int total;
  final Map<String, String> people;
  final Map<String, int> shares;

  // 臨時參與者只屬於當餐；其他餐的編號不能當作這餐的臨時出席者。
  bool needsSavedFriend(String personId) {
    if (personId == quickMealSelfId) return false;
    final prefix = '@guest:$id:';
    return !personId.startsWith(prefix) ||
        !_guestNumber.hasMatch(personId.substring(prefix.length));
  }

  List<Transfer> get transfers => SettlementService.suggest({
    for (final share in shares.entries)
      share.key: (share.key == payerId ? total : 0) - share.value,
  });

  String get shareText {
    final payments = transfers;
    return [
      '快速聚餐｜${Money.format(total)}',
      '付款人：${people[payerId]}',
      for (final t in payments)
        '${people[t.fromId]} → ${people[t.toId]}　${Money.format(t.amount)}',
      if (payments.isEmpty) '本次無須轉帳',
    ].join('\n');
  }

  // 相同草稿可安全重送。若編號相同但內容不同，保留已儲存的原始結果。
  void verifyRetry(QuickMeal other) {
    if (total != other.total ||
        payerId != other.payerId ||
        !createdAt.isAtSameMomentAs(other.createdAt) ||
        people.length != other.people.length ||
        people.keys.any(
          (id) =>
              people[id] != other.people[id] || shares[id] != other.shares[id],
        )) {
      throw const FormatException('此聚餐已儲存，請從紀錄查看');
    }
  }
}
