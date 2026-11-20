import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../bank_apps.dart';
import '../bank_launcher.dart';
import '../data/repository.dart';
import '../domain.dart';
import '../meal_share.dart';
import '../state.dart';
import '../ui.dart';
import 'bank_screen.dart' show BankAppScreen;
import 'friends_screen.dart' show friendAccountSummary;
import 'group_screens.dart' show editName;

class QuickMealScreen extends StatefulWidget {
  const QuickMealScreen({super.key});

  @override
  State<QuickMealScreen> createState() => _QuickMealScreenState();
}

class _QuickMealScreenState extends State<QuickMealScreen> {
  final _draftId = newId();
  final _createdAt = DateTime.now().toUtc();
  final _attendees = <String>{};
  final _amount = TextEditingController();
  String? _payerId;
  String? _saveError;
  bool _payerWasRemoved = false;
  bool _editedAmount = false;
  bool _saving = false;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void _selectAttendee(String id, bool selected) {
    setState(() {
      if (selected) {
        _attendees.add(id);
      } else {
        _attendees.remove(id);
        if (_payerId == id) {
          _payerId = null;
          _payerWasRemoved = true;
        }
      }
      _saveError = null;
    });
  }

  Future<void> _addFriend() async {
    final controller = AppScope.of(context);
    await editName(
      context,
      title: '新增常用朋友',
      initial: '',
      save: (name) async {
        await controller.change((repo) => repo.createFriend(name));
      },
    );
  }

  Future<void> _save(QuickMeal meal) async {
    if (_saving) return;
    final controller = AppScope.of(context);
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      await controller.change((repo) => repo.saveQuickMeal(meal));
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _saveError = errorMessage(error);
        });
      }
      return;
    }
    if (mounted) {
      Navigator.of(context).pushReplacement<void, void>(
        MaterialPageRoute(builder: (_) => _MealResultScreen(meal: meal)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final people = AppScope.of(context).data.quickMealPeople;
    final attending = {
      for (final person in people.entries)
        if (_attendees.contains(person.key)) person.key: person.value,
    };
    final payer = _payerId;
    int? total;
    String? amountError;
    if (_amount.text.trim().isNotEmpty) {
      try {
        total = Money.parse(_amount.text);
      } on FormatException catch (error) {
        amountError = error.message;
      }
    } else if (_editedAmount) {
      amountError = '請輸入帳單總額。';
    }
    final preview =
        total != null && attending.length >= 2 && attending.containsKey(payer)
        ? QuickMeal(
            id: _draftId,
            createdAt: _createdAt,
            total: total,
            payerId: payer!,
            people: attending,
          )
        : null;
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('快速聚餐'),
          actions: [
            TextButton(
              onPressed: _saving
                  ? null
                  : () => openPage<void>(context, const _MealHistoryScreen()),
              child: const Text('聚餐紀錄'),
            ),
          ],
        ),
        body: PageBody(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '這次誰出席？',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                TextButton.icon(
                  key: const ValueKey('meal-add-friend'),
                  onPressed: _saving ? null : _addFriend,
                  icon: const Icon(Icons.person_add_outlined),
                  label: const Text('新增朋友'),
                ),
              ],
            ),
            Text(
              attending.length < 2
                  ? '請勾選至少兩人，自己也可以參加。'
                  : '已選 ${attending.length} 人',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final person in people.entries)
                  FilterChip(
                    key: ValueKey('meal-attendee-${person.key}'),
                    label: Text(person.value),
                    selected: attending.containsKey(person.key),
                    onSelected: _saving
                        ? null
                        : (yes) => _selectAttendee(person.key, yes),
                  ),
              ],
            ),
            const SectionTitle('誰先付？'),
            if (attending.isEmpty)
              const Text('勾選出席者後，就能選擇付款人。')
            else
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final person in attending.entries)
                    ChoiceChip(
                      key: ValueKey('meal-payer-${person.key}'),
                      label: Text(person.value),
                      selected: payer == person.key,
                      onSelected: _saving
                          ? null
                          : (_) => setState(() {
                              _payerId = person.key;
                              _payerWasRemoved = false;
                              _saveError = null;
                            }),
                    ),
                ],
              ),
            if (_payerWasRemoved)
              Semantics(
                liveRegion: true,
                child: Text(
                  '原付款人已取消出席，請重新選擇付款人。',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            const SizedBox(height: 20),
            TextField(
              key: const ValueKey('meal-amount'),
              controller: _amount,
              readOnly: _saving,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: '帳單總額',
                prefixText: r'NT$ ',
                errorText: amountError,
                errorMaxLines: 3,
              ),
              onChanged: (_) => setState(() {
                _editedAmount = true;
                _saveError = null;
              }),
            ),
            if (preview != null) ..._breakdown(preview),
            const SizedBox(height: 20),
            if (_saveError != null)
              Semantics(
                liveRegion: true,
                child: Text(
                  _saveError!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            FilledButton(
              key: const ValueKey('meal-save'),
              onPressed: preview == null || _saving
                  ? null
                  : () => _save(preview),
              child: Text(_saving ? '儲存中…' : '儲存這一餐'),
            ),
          ],
        ),
      ),
    );
  }
}

List<Widget> _breakdown(QuickMeal meal, {bool showBankEntry = false}) => [
  const SectionTitle('每人分攤'),
  Card(
    child: Column(
      children: [
        for (final person in meal.people.entries)
          _AmountLine(
            key: ValueKey('meal-share-${person.key}'),
            label: person.value,
            amount: meal.shares[person.key]!,
          ),
      ],
    ),
  ),
  const SectionTitle('應轉清單'),
  if (meal.transfers.isEmpty)
    const Text('這一餐沒有需要轉帳的款項。')
  else
    Card(
      child: Column(
        children: [
          for (final transfer in meal.transfers) ...[
            _AmountLine(
              key: ValueKey('meal-transfer-${transfer.fromId}'),
              label:
                  '${meal.people[transfer.fromId]} → ${meal.people[transfer.toId]}',
              amount: transfer.amount,
            ),
            if (showBankEntry && transfer.fromId == quickMealSelfId)
              _MealBankActions(
                friendId: transfer.toId,
                recipientName: meal.people[transfer.toId]!,
                amount: transfer.amount,
              ),
          ],
        ],
      ),
    ),
];

class _MealBankActions extends StatefulWidget {
  const _MealBankActions({
    required this.friendId,
    required this.recipientName,
    required this.amount,
  });

  final String friendId;
  final String recipientName;
  final int amount;

  @override
  State<_MealBankActions> createState() => _MealBankActionsState();
}

class _MealBankActionsState extends State<_MealBankActions> {
  bool _busy = false;
  String? _status;

  Future<void> _run(
    Future<String?> Function() action, {
    required String onFailure,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    String? status;
    try {
      status = await action();
    } catch (_) {
      status = onFailure;
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _status = status;
      });
    }
  }

  Future<void> _copy(String friendId) {
    final repo = AppScope.of(context).repo;
    return _run(() async {
      final number = await repo.readFriendAccount(friendId);
      if (number == null) return '尚未儲存收款帳號。';
      if (!mounted) return null;
      await copyAccount(number);
      return '已複製收款帳號';
    }, onFailure: '無法複製帳號，請到常用朋友確認收款資料。');
  }

  Future<void> _launch(BankAppChoice? choice) => _run(() async {
    if (choice == null) {
      await openPage<void>(context, const BankAppScreen());
      return null;
    }
    if (!BankLauncher.supportsDirectOpen(choice)) {
      return await BankLauncher.openOfficialPage(choice)
          ? null
          : '無法開啟商店頁面，請手動打開銀行 App。';
    }
    if (await BankLauncher.open(choice) || !mounted) return null;
    if (!bankApps.any((bank) => bank.id == choice.id)) {
      return '無法開啟所選項目，請在「我的轉帳 App」重新選取。';
    }
    final viewStore = await confirmAction(
      context,
      '無法開啟${choice.label}',
      '請確認手機已安裝此 App。也可以前往官方商店頁面查看。',
      '前往商店',
    );
    if (!viewStore || !mounted) return null;
    return await BankLauncher.openOfficialPage(choice)
        ? null
        : '無法開啟商店頁面，請手動打開銀行 App。';
  }, onFailure: '無法開啟選定項目，請手動打開銀行 App。');

  @override
  Widget build(BuildContext context) {
    final data = AppScope.of(context).data;
    final choice = data.bankApp;
    final friend = data.friends
        .where((f) => f.id == widget.friendId)
        .firstOrNull;
    final hasAccount = friend?.bankCode != null && friend?.lastFour != null;
    final launchLabel = choice == null
        ? '選擇我的轉帳 App'
        : choice.id.startsWith('ios-shortcut:')
        ? '執行捷徑：${choice.label}'
        : BankLauncher.supportsDirectOpen(choice)
        ? '開啟${choice.label}'
        : '從 App Store 查看${choice.label}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '你要轉給${widget.recipientName} ${Money.format(widget.amount)}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          Text(hasAccount ? friendAccountSummary(friend!) : '尚未儲存收款帳號'),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              FilledButton.tonalIcon(
                key: const ValueKey('meal-bank-open'),
                onPressed: _busy ? null : () => _launch(choice),
                icon: const Icon(Icons.open_in_new),
                label: Text(launchLabel),
              ),
              if (hasAccount)
                OutlinedButton.icon(
                  key: const ValueKey('meal-bank-copy-account'),
                  onPressed: _busy ? null : () => _copy(widget.friendId),
                  icon: const Icon(Icons.copy),
                  label: const Text('複製收款帳號'),
                ),
            ],
          ),
          const SizedBox(height: 4),
          const Text('只會開啟 App，不會代為轉帳或記錄還款。'),
          if (_status != null)
            Semantics(liveRegion: true, child: Text(_status!)),
        ],
      ),
    );
  }
}

class _AmountLine extends StatelessWidget {
  const _AmountLine({super.key, required this.label, required this.amount});
  final String label;
  final int amount;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
    child: SizedBox(
      width: double.infinity,
      child: Wrap(
        spacing: 14,
        runSpacing: 2,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(label),
          Text(
            Money.format(amount),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    ),
  );
}

String _mealDate(DateTime date) {
  final local = date.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '${shortDate(local)} $hour:$minute';
}

class _MealHistoryScreen extends StatelessWidget {
  const _MealHistoryScreen();

  @override
  Widget build(BuildContext context) {
    final meals = AppScope.of(context).data.quickMeals;
    return Scaffold(
      appBar: AppBar(title: const Text('聚餐紀錄')),
      body: PageBody(
        children: [
          if (meals.isEmpty)
            const EmptyCard(
              Icons.restaurant_outlined,
              '尚無聚餐紀錄',
              '儲存第一餐後，即可在這裡回看分攤與應轉清單。',
            ),
          for (final meal in meals)
            Card(
              child: ListTile(
                key: ValueKey('meal-history-${meal.id}'),
                title: Text(
                  '${Money.format(meal.total)} · ${meal.people.length} 人平分',
                ),
                subtitle: Text(
                  '${_mealDate(meal.createdAt)}\n${meal.people[meal.payerId]} 先付',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () =>
                    openPage<void>(context, _MealResultScreen(meal: meal)),
              ),
            ),
        ],
      ),
    );
  }
}

class _MealResultScreen extends StatelessWidget {
  const _MealResultScreen({required this.meal});
  final QuickMeal meal;

  Future<void> _copy(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await Clipboard.setData(ClipboardData(text: meal.shareText));
      messenger.showSnackBar(const SnackBar(content: Text('已複製分帳清單')));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('無法使用剪貼簿，請再試一次。')));
    }
  }

  Future<void> _share(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await shareMealText(meal.shareText);
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('無法開啟系統分享，可先複製清單。')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('聚餐分帳結果')),
      body: PageBody(
        children: [
          Text(_mealDate(meal.createdAt), style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
          Text(
            Money.format(meal.total),
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          Text('${meal.people.length} 人平分 · ${meal.people[meal.payerId]} 先付'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              OutlinedButton.icon(
                onPressed: () => _copy(context),
                icon: const Icon(Icons.copy),
                label: const Text('複製清單'),
              ),
              FilledButton.icon(
                onPressed: () => _share(context),
                icon: const Icon(Icons.share_outlined),
                label: const Text('分享清單'),
              ),
            ],
          ),
          ..._breakdown(meal, showBankEntry: true),
        ],
      ),
    );
  }
}
