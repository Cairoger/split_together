import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../bank_apps.dart';
import '../bank_launcher.dart';
import '../domain.dart';
import '../meal_share.dart';
import '../state.dart';
import '../ui.dart';
import 'bank_screen.dart' show BankAppScreen;
import 'friends_screen.dart' show friendAccountSummary;
import 'quick_meal_screen.dart' show QuickMealScreen;

class QuickMealResultScreen extends StatelessWidget {
  const QuickMealResultScreen({super.key, required this.meal});

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
    final selfShare = meal.shares[quickMealSelfId] ?? 0;
    final selfCollects =
        meal.payerId == quickMealSelfId && meal.total > selfShare;
    return Scaffold(
      appBar: AppBar(title: const Text('聚餐分帳結果')),
      body: PageBody(
        children: [
          _PersonalSummary(
            meal: meal,
            onShare: selfCollects ? () => _share(context) : null,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (!selfCollects)
                OutlinedButton.icon(
                  key: const ValueKey('meal-share-list'),
                  onPressed: () => _share(context),
                  icon: const Icon(Icons.share_outlined),
                  label: const Text('分享分帳清單'),
                ),
              TextButton.icon(
                onPressed: () => _copy(context),
                icon: const Icon(Icons.copy),
                label: const Text('複製清單'),
              ),
            ],
          ),
          MealBreakdown(meal: meal),
          const SizedBox(height: 12),
          Text(
            _mealDate(meal.createdAt),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _PersonalSummary extends StatelessWidget {
  const _PersonalSummary({
    required this.meal,
    this.onShare,
    this.example = false,
  });
  final QuickMeal meal;
  final VoidCallback? onShare;
  final bool example;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final payer = meal.people[meal.payerId]!;
    final selfShare = meal.shares[quickMealSelfId] ?? 0;
    final selfPaid = meal.payerId == quickMealSelfId;
    final owed = selfPaid ? meal.total - selfShare : 0;
    final owes = !selfPaid && selfShare > 0;
    final hasBankEntry =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    final title = owes
        ? '你要轉給$payer ${Money.format(selfShare)}'
        : owed > 0
        ? '你應收 ${Money.format(owed)}'
        : '這餐你不用轉帳';
    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!example) ...[
              Text(
                '已儲存',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(height: 4),
            ],
            Text(
              title,
              key: const ValueKey('meal-personal-summary'),
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '本餐 ${Money.format(meal.total)} · ${meal.people.length} 人平分 · $payer 先付',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            if (owes && (example || hasBankEntry)) ...[
              const SizedBox(height: 16),
              if (example) ...[
                FilledButton.icon(
                  onPressed: null,
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('選擇我的轉帳 App'),
                ),
                const SizedBox(height: 6),
                const Text('這是示意按鈕。自己分帳時，可從這裡選擇轉帳 App。'),
              ] else
                _MealBankActions(friendId: meal.payerId),
            ] else if (onShare != null) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const ValueKey('meal-share-list'),
                onPressed: onShare,
                icon: const Icon(Icons.share_outlined),
                label: const Text('分享分帳清單'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MealBankActions extends StatefulWidget {
  const _MealBankActions({required this.friendId});
  final String friendId;

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
        ? '開啟${choice.label}（捷徑）'
        : BankLauncher.supportsDirectOpen(choice)
        ? '開啟${choice.label}'
        : '從 App Store 查看${choice.label}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          key: const ValueKey('meal-bank-open'),
          onPressed: _busy ? null : () => _launch(choice),
          icon: const Icon(Icons.open_in_new),
          label: Text(launchLabel),
        ),
        const SizedBox(height: 6),
        const Text('請在轉帳 App 確認並完成付款。'),
        const SizedBox(height: 8),
        Text(hasAccount ? friendAccountSummary(friend!) : '尚未儲存收款帳號'),
        if (hasAccount)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('meal-bank-copy-account'),
              onPressed: _busy ? null : () => _copy(widget.friendId),
              icon: const Icon(Icons.copy),
              label: const Text('複製收款帳號'),
            ),
          ),
        if (_status != null) Semantics(liveRegion: true, child: Text(_status!)),
      ],
    );
  }
}

class MealBreakdown extends StatelessWidget {
  const MealBreakdown({super.key, required this.meal});

  final QuickMeal meal;

  @override
  Widget build(BuildContext context) {
    final transfers = meal.transfers;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
        const SectionTitle('全桌應轉清單'),
        if (transfers.isEmpty)
          const Text('這一餐沒有需要轉帳的款項。')
        else
          Card(
            child: Column(
              children: [
                for (final transfer in transfers)
                  _AmountLine(
                    key: ValueKey('meal-transfer-${transfer.fromId}'),
                    label:
                        '${meal.people[transfer.fromId]} → ${meal.people[transfer.toId]}',
                    amount: transfer.amount,
                  ),
              ],
            ),
          ),
      ],
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

class QuickMealHistoryScreen extends StatelessWidget {
  const QuickMealHistoryScreen({super.key});

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
          for (final meal in meals) QuickMealHistoryTile(meal: meal),
        ],
      ),
    );
  }
}

class QuickMealHistoryTile extends StatelessWidget {
  const QuickMealHistoryTile({super.key, required this.meal});
  final QuickMeal meal;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      key: ValueKey('meal-history-${meal.id}'),
      title: Text('${Money.format(meal.total)} · ${meal.people.length} 人平分'),
      subtitle: Text(
        '${_mealDate(meal.createdAt)}\n${meal.people[meal.payerId]} 先付 · 已儲存',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => openPage<void>(context, QuickMealResultScreen(meal: meal)),
    ),
  );
}

class QuickMealExampleScreen extends StatefulWidget {
  const QuickMealExampleScreen({super.key, this.showResult = false});
  final bool showResult;

  @override
  State<QuickMealExampleScreen> createState() => _QuickMealExampleScreenState();
}

class _QuickMealExampleScreenState extends State<QuickMealExampleScreen> {
  static final _example = QuickMeal(
    id: 'example',
    createdAt: DateTime.utc(2000),
    total: 60000,
    payerId: 'example-lin',
    people: const {quickMealSelfId: '我', 'example-lin': '小林'},
  );

  @override
  void initState() {
    super.initState();
    if (widget.showResult) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _recordViewedResult());
    }
  }

  Future<void> _recordViewedResult() async {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    final controller = AppScope.of(context);
    if (controller.data.hasSeenExampleResult) return;
    try {
      await controller.change((repo) => repo.markExampleResultSeen());
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('無法儲存教學進度，下次仍會顯示範例。')),
        );
      }
    }
  }

  void _start(BuildContext context) {
    Navigator.of(context).pushReplacement<void, void>(
      MaterialPageRoute(builder: (_) => const QuickMealScreen()),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('用範例試一次')),
    body: PageBody(
      children: [
        if (!widget.showResult) ...[
          const SectionTitle('這一餐怎麼分？'),
          Card(
            child: Column(
              children: [
                _AmountLine(label: '帳單總額', amount: _example.total),
                const Divider(height: 1),
                const ListTile(title: Text('今天有哪些人'), trailing: Text('我、小林')),
                const ListTile(title: Text('誰先付'), trailing: Text('小林')),
              ],
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => Navigator.of(context).pushReplacement<void, void>(
              MaterialPageRoute(
                builder: (_) => const QuickMealExampleScreen(showResult: true),
              ),
            ),
            child: const Text('看範例結果'),
          ),
          TextButton(
            onPressed: () => _start(context),
            child: const Text('略過範例，直接分帳'),
          ),
        ] else ...[
          _PersonalSummary(meal: _example, example: true),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => _start(context),
            child: const Text('開始聚餐分帳'),
          ),
          MealBreakdown(meal: _example),
        ],
      ],
    ),
  );
}
