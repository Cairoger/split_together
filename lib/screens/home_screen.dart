import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../domain.dart';
import '../state.dart';
import '../ui.dart';
import 'backup_screen.dart';
import 'bank_screen.dart';
import 'friends_screen.dart';
import 'expense_screens.dart';
import 'group_screens.dart';
import 'personal_expenses_view.dart';
import 'quick_meal_result_screen.dart';
import 'quick_meal_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int tab = 0;
  bool archived = false;

  Future<void> create() async {
    final id = await openPage<String>(context, const GroupFormScreen());
    if (id != null && mounted) {
      await openPage(context, GroupScreen(groupId: id));
    }
  }

  Future<void> quickExpense(List<Ledger> active) async {
    if (active.isEmpty) {
      final id = await openPage<String>(context, const GroupFormScreen());
      if (id != null && mounted) {
        await openPage(context, ExpenseFormScreen(groupId: id));
      }
      return;
    }
    final id = active.length == 1
        ? active.first.id
        : await showModalBottomSheet<String>(
            context: context,
            showDragHandle: true,
            useSafeArea: true,
            builder: (ctx) => ListView(
              shrinkWrap: true,
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('選擇記帳群組'),
                ),
                for (final g in active)
                  ListTile(
                    leading: Icon(categoryIcon(g.category)),
                    title: Text(g.name),
                    onTap: () => Navigator.pop(ctx, g.id),
                  ),
              ],
            ),
          );
    if (id != null && mounted) {
      await openPage(context, ExpenseFormScreen(groupId: id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = AppScope.of(context).data;
    final groups = [...data.groups]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final active = groups.where((g) => !g.archived).toList();
    final visible = groups.where((g) => g.archived == archived).toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(
          [appName, '群組', '我的支出', '統計', '設定'][tab],
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          if (tab < 2)
            IconButton(
              tooltip: '新增群組',
              onPressed: create,
              icon: const Icon(Icons.group_add_outlined),
            ),
          const SizedBox(width: 6),
        ],
      ),
      body: switch (tab) {
        0 => PageBody(
          children: [
            FilledButton.icon(
              onPressed: () => openPage<void>(context, const QuickMealScreen()),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 56)),
              icon: const Icon(Icons.restaurant_outlined),
              label: const Text('開始聚餐分帳'),
            ),
            if (!data.hasSeenExampleResult)
              const _ExampleEntry(
                title: '用範例試一次',
                subtitle: r'兩人平分 NT$600，不會留下紀錄',
              ),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                Text(
                  '最近聚餐',
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                TextButton(
                  onPressed: () =>
                      openPage<void>(context, const QuickMealHistoryScreen()),
                  child: const Text('全部聚餐紀錄'),
                ),
              ],
            ),
            if (data.quickMeals.isEmpty) ...[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('還沒有聚餐紀錄'),
              ),
              const Text('不用建群組，也能先算這一餐。', textAlign: TextAlign.center),
            ],
            for (final meal in data.quickMeals.take(3))
              QuickMealHistoryTile(meal: meal),
            const SectionTitle('群組帳本'),
            _Summary(groups: groups),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => quickExpense(active),
              icon: const Icon(Icons.add),
              label: const Text('新增消費'),
            ),
            if (active.isEmpty)
              TextButton.icon(
                onPressed: create,
                icon: const Icon(Icons.group_add_outlined),
                label: const Text('建立群組'),
              )
            else
              const SectionTitle('近期群組'),
            for (final g in active.take(4)) _GroupCard(g),
            if (active.length > 4)
              TextButton(
                onPressed: () => setState(() => tab = 1),
                child: const Text('查看全部群組'),
              ),
          ],
        ),
        1 => PageBody(
          children: [
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('使用中'),
                  selected: !archived,
                  onSelected: (_) => setState(() => archived = false),
                ),
                ChoiceChip(
                  label: const Text('已封存'),
                  selected: archived,
                  onSelected: (_) => setState(() => archived = true),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (visible.isEmpty)
              EmptyCard(
                Icons.folder_open_outlined,
                archived ? '沒有封存的群組' : '還沒有群組',
                archived ? '已結清的群組可在群組明細封存。' : '建立群組後就能登記成員與共同消費。',
                action: archived
                    ? null
                    : OutlinedButton(
                        onPressed: create,
                        child: const Text('建立群組'),
                      ),
              ),
            for (final g in visible) _GroupCard(g),
          ],
        ),
        2 => const PersonalExpensesView(),
        3 => PageBody(
          children: [
            const SectionTitle('各群組消費'),
            if (groups.isEmpty)
              EmptyCard(
                Icons.bar_chart,
                '尚無群組統計',
                '建立群組並記錄消費後，即可查看各分類合計。',
                action: OutlinedButton(
                  onPressed: create,
                  child: const Text('建立群組'),
                ),
              ),
            for (final g in groups)
              Card(
                child: ExpansionTile(
                  key: PageStorageKey(g.id),
                  title: Text(g.name),
                  subtitle: Text('群組總消費 · ${Money.format(g.totalExpense)}'),
                  children: [
                    if (g.expenses.isEmpty)
                      const ListTile(title: Text('尚無消費紀錄')),
                    for (final category in g.expenseByCategory.entries)
                      ListTile(
                        title: Text(category.key),
                        subtitle: Text(Money.format(category.value)),
                      ),
                  ],
                ),
              ),
          ],
        ),
        _ => const _Settings(),
      },
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (v) => setState(() => tab = v),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '首頁',
          ),
          NavigationDestination(
            icon: Icon(Icons.groups_outlined),
            selectedIcon: Icon(Icons.groups),
            label: '群組',
          ),
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long),
            label: '我的支出',
          ),
          NavigationDestination(
            icon: Icon(Icons.bar_chart_outlined),
            selectedIcon: Icon(Icons.bar_chart),
            label: '統計',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '設定',
          ),
        ],
      ),
    );
  }
}

class _ExampleEntry extends StatelessWidget {
  const _ExampleEntry({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: ListTile(
      leading: const Icon(Icons.school_outlined),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => openPage<void>(context, const QuickMealExampleScreen()),
    ),
  );
}

class _Summary extends StatelessWidget {
  const _Summary({required this.groups});
  final List<Ledger> groups;
  @override
  Widget build(BuildContext context) {
    final totals = BalanceService.overview(groups);
    final net = totals.net;
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(22),
      ),
      child: DefaultTextStyle(
        style: TextStyle(color: colors.onSurface, fontSize: 15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.account_balance_wallet_outlined,
                  color: colors.primary,
                  size: 19,
                ),
                const SizedBox(width: 8),
                const Flexible(child: Text('我的淨餘額')),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '${net < 0
                  ? '−'
                  : net > 0
                  ? '+'
                  : ''}${Money.format(net.abs())}',
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.w700,
                color: balanceColor(colors, net),
              ),
            ),
            Divider(height: 32, color: colors.outlineVariant),
            Wrap(
              spacing: 36,
              runSpacing: 12,
              children: [
                _Metric(
                  '總應收',
                  totals.receivable,
                  balanceColor(colors, totals.receivable),
                ),
                _Metric(
                  '總應付',
                  totals.payable,
                  balanceColor(colors, -totals.payable),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric(this.label, this.amount, this.color);
  final String label;
  final int amount;
  final Color color;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(fontSize: 13)),
      Text(
        Money.format(amount),
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    ],
  );
}

class _GroupCard extends StatelessWidget {
  const _GroupCard(this.group);
  final Ledger group;
  @override
  Widget build(BuildContext context) {
    final balances = BalanceService.balances(group);
    final value = balances[group.self.id]!;
    final colors = Theme.of(context).colorScheme;
    final status = group.archived
        ? '已封存'
        : balances.values.any((v) => v != 0)
        ? '未結清'
        : '已結清';
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 6),
        leading: CircleAvatar(
          backgroundColor: colors.primaryContainer,
          foregroundColor: colors.onPrimaryContainer,
          child: Icon(categoryIcon(group.category)),
        ),
        title: Text(
          group.name,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${group.members.where((m) => m.isActive).length} 位成員 · $status',
            ),
            Text(
              '我：${balanceLabel(value)}',
              style: TextStyle(color: balanceColor(colors, value)),
            ),
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => openPage(context, GroupScreen(groupId: group.id)),
      ),
    );
  }
}

class _Settings extends StatefulWidget {
  const _Settings();
  @override
  State<_Settings> createState() => _SettingsState();
}

class _SettingsState extends State<_Settings> {
  bool savingAppearance = false;

  Future<void> selectAppearance(AppAppearance appearance) async {
    final controller = AppScope.of(context);
    if (savingAppearance || controller.data.appearance == appearance) return;
    setState(() => savingAppearance = true);
    try {
      await controller.change((repo) => repo.setAppearance(appearance));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(errorMessage(error))));
      }
    } finally {
      if (mounted) setState(() => savingAppearance = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppScope.of(context);
    final colors = Theme.of(context).colorScheme;
    return PageBody(
      children: [
        const SectionTitle('個人設定'),
        Card(
          child: ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('我的預設名稱'),
            subtitle: Text(c.data.defaultName),
            trailing: const Icon(Icons.edit_outlined),
            onTap: () => editName(
              context,
              title: '我的預設名稱',
              initial: c.data.defaultName,
              save: (name) => c.change((repo) => repo.setDefaultName(name)),
            ),
          ),
        ),
        const SectionTitle('外觀'),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: AppAppearance.values.map((mode) {
            final selected = c.data.appearance == mode;
            final foreground = selected ? colors.onPrimary : colors.onSurface;
            final (label, icon) = switch (mode) {
              AppAppearance.light => ('光亮模式', Icons.light_mode_outlined),
              AppAppearance.dark => ('黑暗模式', Icons.dark_mode_outlined),
            };
            return ChoiceChip(
              label: Text(label),
              selected: selected,
              backgroundColor: colors.surface,
              selectedColor: colors.primary,
              disabledColor: selected ? colors.primary : colors.surface,
              labelStyle: TextStyle(color: foreground),
              avatar: Icon(
                selected ? Icons.check : icon,
                size: 18,
                color: foreground,
              ),
              showCheckmark: false,
              onSelected: savingAppearance
                  ? null
                  : (_) => selectAppearance(mode),
            );
          }).toList(),
        ),
        const SectionTitle('朋友與轉帳'),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.contacts_outlined),
                title: const Text('常用朋友'),
                subtitle: Text('${c.data.activeFriends.length} 位朋友'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => openPage<void>(context, const FriendsScreen()),
              ),
              ListTile(
                leading: const Icon(Icons.account_balance_outlined),
                title: const Text('我的轉帳 App'),
                subtitle: Text(c.data.bankApp?.label ?? '尚未選擇'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => openPage<void>(context, const BankAppScreen()),
              ),
            ],
          ),
        ),
        const SectionTitle('帳本資料'),
        Card(
          child: ListTile(
            leading: const Icon(Icons.cloud_outlined),
            title: const Text('備份與還原'),
            subtitle: const Text('匯出帳本檔案，或從備份檔還原'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => openPage<void>(context, const BackupScreen()),
          ),
        ),
        const SectionTitle('使用說明'),
        const _ExampleEntry(title: '重看分帳教學', subtitle: '查看兩人平分的範例'),
        const SectionTitle('關於帳本'),
        const Card(
          child: Padding(
            padding: EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('本機離線儲存', style: TextStyle(fontWeight: FontWeight.bold)),
                SizedBox(height: 8),
                Text('帳本儲存在這台裝置，不會自動同步或備份。解除安裝、清除 App 資料或遺失裝置時，記帳資料可能遺失。'),
                Divider(height: 28),
                _InstalledAppVersion(),
                SizedBox(height: 4),
                Text('還款建議僅供核對，實際轉帳後請手動登記。'),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _InstalledAppVersion extends StatefulWidget {
  const _InstalledAppVersion();

  @override
  State<_InstalledAppVersion> createState() => _InstalledAppVersionState();
}

class _InstalledAppVersionState extends State<_InstalledAppVersion> {
  late final _packageInfo = PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) => FutureBuilder<PackageInfo>(
    future: _packageInfo,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Text('$appName · 正在讀取版本…');
      }
      final version = snapshot.data?.version.trim() ?? '';
      if (version.isEmpty) return const Text('$appName · 無法取得版本資訊');
      final build = snapshot.data!.buildNumber.trim();
      final suffix = build.isEmpty ? '' : '（組建 $build）';
      return Text('$appName · 版本 $version$suffix');
    },
  );
}
