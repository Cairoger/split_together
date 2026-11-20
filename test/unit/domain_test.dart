import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:split_together/domain.dart';

final _date = DateTime.utc(2026, 1, 1);

Expense _expense(String id, String payer, int amount, Map<String, int> shares) {
  return Expense(
    id: id,
    title: '午餐',
    amount: amount,
    payerId: payer,
    method: SplitMethod.exact,
    category: '餐飲',
    spentAt: _date,
    note: '',
    createdAt: _date,
    updatedAt: _date,
    shares: shares,
    inputs: shares,
  );
}

Ledger _ledger(
  List<String> ids,
  List<Expense> expenses, {
  String groupId = 'g',
  List<Repayment> repayments = const [],
  Set<String> inactive = const {},
}) {
  return Ledger(
    id: groupId,
    name: '群組',
    category: '旅遊',
    archived: false,
    createdAt: _date,
    updatedAt: _date,
    members: [
      for (final id in ids)
        Member(
          id: id,
          name: id,
          isSelf: id == ids.first,
          isActive: !inactive.contains(id),
          createdAt: _date,
        ),
    ],
    expenses: expenses,
    repayments: repayments,
  );
}

Repayment _payment(String from, String to, int amount) => Repayment(
  id: 'payment',
  fromId: from,
  toId: to,
  amount: amount,
  paidAt: _date,
  note: '',
  createdAt: _date,
);

List<(String, String, int)> _transfers(Map<String, int> balances) => [
  for (final t in SettlementService.suggest(balances))
    (t.fromId, t.toId, t.amount),
];

void main() {
  group('Money', () {
    test('T03 decimal strings and boundaries', () {
      expect(Money.parse('1200'), 120000);
      expect(Money.parse('1200.50'), 120050);
      expect(Money.parse(' 001.7 '), 170);
      expect(Money.parse('0.01'), 1);
      expect(Money.parse('0.00', allowZero: true), 0);
      expect(Money.parse('99999999.99'), Money.maxMinor);
      for (final text in [
        '',
        ' ',
        '0',
        '0.00',
        '-1',
        '1.236',
        '7.',
        '.1',
        '1e2',
        '1 00',
        'NaN',
        '100000000',
        '9' * 80,
      ]) {
        expect(() => Money.parse(text), throwsFormatException, reason: text);
      }
    });

    test('formats whole dollars, fractional dollars and negative balances', () {
      expect(Money.format(120000), r'NT$1,200');
      expect(Money.format(120050), r'NT$1,200.50');
      expect(Money.format(-1), r'-NT$0.01');
      expect(Money.format(Money.maxMinor), r'NT$99,999,999.99');
      expect(Money.format(0), r'NT$0');
      for (final amount in [0, 1, 10, 100, 120050, Money.maxMinor]) {
        expect(Money.parse(Money.input(amount), allowZero: true), amount);
      }
    });
  });

  group('SplitService', () {
    test('T02 equal shares distribute leftover cents by stable ID', () {
      expect(
        SplitService.divide(120000, SplitMethod.equal, [
          'A',
          'B',
          'C',
          'D',
        ], {}),
        {'A': 30000, 'B': 30000, 'C': 30000, 'D': 30000},
      );
      expect(
        SplitService.divide(10000, SplitMethod.equal, ['C', 'B', 'A'], {}),
        {'A': 3334, 'B': 3333, 'C': 3333},
      );
      expect(SplitService.divide(1, SplitMethod.equal, ['A'], {}), {'A': 1});
      expect(SplitService.divide(1, SplitMethod.equal, ['C', 'A', 'B'], {}), {
        'A': 1,
        'B': 0,
        'C': 0,
      });
    });

    test('T04 percentages and weights use largest remainders', () {
      const ids = ['B', 'A'];
      expect(
        SplitService.divide(100000, SplitMethod.percent, ids, {
          'A': 7000,
          'B': 3000,
        }),
        {'A': 70000, 'B': 30000},
      );
      expect(
        SplitService.divide(1, SplitMethod.percent, ids, {
          'A': 4900,
          'B': 5100,
        }),
        {'A': 0, 'B': 1},
      );
      expect(
        SplitService.divide(5, SplitMethod.percent, ids, {
          'A': 5000,
          'B': 5000,
        }),
        {'A': 3, 'B': 2},
      );
      expect(
        SplitService.divide(200, SplitMethod.percent, ids, {
          'A': 10000,
          'B': 0,
        }),
        {'A': 200, 'B': 0},
      );
      expect(
        SplitService.divide(
          90000,
          SplitMethod.weight,
          ['A', 'B', 'C'],
          {'A': 2, 'B': 2, 'C': 1},
        ),
        {'A': 36000, 'B': 36000, 'C': 18000},
      );
      expect(
        SplitService.divide(Money.maxMinor, SplitMethod.weight, ids, {
          'A': 10000,
          'B': 10000,
        }),
        {'A': 5000000000, 'B': 4999999999},
      );
    });

    test(
      'T04 invalid percentages, weights and member selections are rejected',
      () {
        const ids = ['A', 'B'];
        for (final values in [
          {'A': 6999, 'B': 3000},
          {'A': 10001, 'B': -1},
        ]) {
          expect(
            () => SplitService.divide(100, SplitMethod.percent, ids, values),
            throwsFormatException,
          );
        }
        for (final weight in [-1, 0, 10001]) {
          expect(
            () => SplitService.divide(100, SplitMethod.weight, ids, {
              'A': weight,
              'B': 1,
            }),
            throwsFormatException,
          );
        }
        for (final invalid in <List<String>>[
          [],
          ['A', 'A'],
          [' '],
        ]) {
          expect(
            () => SplitService.divide(100, SplitMethod.equal, invalid, {}),
            throwsFormatException,
          );
        }
        expect(
          () => SplitService.divide(100, SplitMethod.weight, ids, {'A': 1}),
          throwsFormatException,
        );
        expect(
          () => SplitService.divide(100, SplitMethod.weight, ids, {
            'A': 1,
            'X': 1,
          }),
          throwsFormatException,
        );
        for (final amount in [-1, 0, Money.maxMinor + 1]) {
          expect(
            () => SplitService.divide(amount, SplitMethod.equal, ids, {}),
            throwsFormatException,
          );
        }
      },
    );

    test('T05 exact inputs must balance to the cent', () {
      const ids = ['A', 'B'];
      expect(
        SplitService.divide(80000, SplitMethod.exact, ids, {
          'A': 50000,
          'B': 30000,
        }),
        {'A': 50000, 'B': 30000},
      );
      expect(
        SplitService.divide(80000, SplitMethod.exact, ids, {
          'A': 80000,
          'B': 0,
        }),
        {'A': 80000, 'B': 0},
      );
      for (final values in [
        {'A': 50000, 'B': 29900},
        {'A': 50000, 'B': 30001},
        {'A': 80001, 'B': -1},
      ]) {
        expect(
          () => SplitService.divide(80000, SplitMethod.exact, ids, values),
          throwsFormatException,
        );
      }
    });
  });

  group('BalanceService and SettlementService', () {
    const ids = ['A', 'B', 'C', 'D'];
    final expenses = [
      _expense(
        'e1',
        'A',
        120000,
        SplitService.divide(120000, SplitMethod.equal, ids, {}),
      ),
      _expense(
        'e2',
        'B',
        60000,
        SplitService.divide(60000, SplitMethod.equal, ids, {}),
      ),
    ];

    test(
      'T02 payer outside the split and historical inactive members count',
      () {
        final ledger = _ledger(
          ['A', 'B', 'C'],
          [
            _expense('e', 'A', 60000, {'B': 30000, 'C': 30000}),
          ],
          inactive: {'B'},
        );
        expect(BalanceService.balances(ledger), {
          'A': 60000,
          'B': -30000,
          'C': -30000,
        });
      },
    );

    test('T06 exact four-person settlement and stable ID tie breaking', () {
      final balances = BalanceService.balances(_ledger(ids, expenses));
      expect(balances, {'A': 75000, 'B': 15000, 'C': -45000, 'D': -45000});
      final expected = [
        ('C', 'A', 45000),
        ('D', 'A', 30000),
        ('D', 'B', 15000),
      ];
      expect(_transfers(balances), expected);
      expect(
        _transfers(Map.fromEntries(balances.entries.toList().reversed)),
        expected,
      );
      expect(balances['A'], 75000);
      expect(SettlementService.suggest({}), isEmpty);
      expect(SettlementService.suggest({'A': 0, 'B': 0}), isEmpty);
      expect(
        () => SettlementService.suggest({'A': 5, 'B': -4}),
        throwsFormatException,
      );
    });

    test('T07 partial repayment recomputes largest remaining debts', () {
      final ledger = _ledger(
        ids,
        expenses,
        repayments: [_payment('C', 'A', 20000)],
      );
      expect(ledger.totalExpense, 180000);
      final balances = BalanceService.balances(ledger);
      expect(balances, {'A': 55000, 'B': 15000, 'C': -25000, 'D': -45000});
      expect(_transfers(balances), [
        ('D', 'A', 45000),
        ('C', 'B', 15000),
        ('C', 'A', 10000),
      ]);
    });

    test('T09 keeps group obligations separate in the personal overview', () {
      final first = _ledger(ids, expenses);
      final second = _ledger(
        ['me2', 'p2'],
        [
          _expense('e3', 'p2', 80000, {'me2': 80000}),
        ],
        groupId: 'g2',
      );
      expect(BalanceService.overview([first, second]), (
        receivable: 75000,
        payable: 80000,
        net: -5000,
      ));
      expect(BalanceService.overview([]), (receivable: 0, payable: 0, net: 0));
      expect(_transfers(BalanceService.balances(second)), [
        ('me2', 'p2', 80000),
      ]);
      final invalid = _ledger(ids, [
        _expense('e4', 'A', 100, {'p2': 100}),
      ]);
      expect(() => BalanceService.balances(invalid), throwsFormatException);
    });
  });

  test('T12 seeded random splits conserve money and settle all balances', () {
    final random = Random(93611);
    for (var trial = 0; trial < 200; trial++) {
      final ids = [for (var i = 0; i < 1 + trial % 15; i++) 'm$i'];
      final expenses = <Expense>[];
      for (final method in SplitMethod.values) {
        final participants = (ids.toList()..shuffle(random))
            .take(random.nextInt(ids.length) + 1)
            .toList();
        final amount = 1 + random.nextInt(10000000);
        final cuts = <int>[0];
        final total = method == SplitMethod.percent ? 10000 : amount;
        for (var i = 1; i < participants.length; i++) {
          cuts.add(random.nextInt(total + 1));
        }
        cuts.add(total);
        cuts.sort();
        final inputs = <String, int>{
          if (method != SplitMethod.equal)
            for (var i = 0; i < participants.length; i++)
              participants[i]: method == SplitMethod.weight
                  ? 1 + random.nextInt(10000)
                  : cuts[i + 1] - cuts[i],
        };
        final shares = SplitService.divide(
          amount,
          method,
          participants,
          inputs,
        );
        expect(shares.keys.toSet(), participants.toSet());
        expect(shares.values, everyElement(greaterThanOrEqualTo(0)));
        expect(shares.values.fold(0, (sum, n) => sum + n), amount);
        expect(
          SplitService.divide(
            amount,
            method,
            participants.reversed.toList(),
            Map.fromEntries(inputs.entries.toList().reversed),
          ),
          shares,
        );
        expenses.add(
          _expense(
            method.name,
            ids[random.nextInt(ids.length)],
            amount,
            shares,
          ),
        );
      }
      final balances = BalanceService.balances(_ledger(ids, expenses));
      final transfers = SettlementService.suggest(balances);
      final nonzeroCount = balances.values.where((n) => n != 0).length;
      expect(balances.values.fold(0, (sum, n) => sum + n), 0);
      expect(transfers.length, lessThanOrEqualTo(max(0, nonzeroCount - 1)));
      final remaining = Map.of(balances);
      for (final t in transfers) {
        expect(t.amount, greaterThan(0));
        expect(t.fromId, isNot(t.toId));
        expect(
          t.amount,
          lessThanOrEqualTo(min(-remaining[t.fromId]!, remaining[t.toId]!)),
        );
        remaining[t.fromId] = remaining[t.fromId]! + t.amount;
        remaining[t.toId] = remaining[t.toId]! - t.amount;
      }
      expect(remaining.values, everyElement(0));
      final recorded = [
        for (final t in transfers) _payment(t.fromId, t.toId, t.amount),
      ];
      expect(
        BalanceService.balances(_ledger(ids, expenses, repayments: recorded))
            .values,
        everyElement(0),
      );
    }
  });
}
