import 'package:material_ui/material_ui.dart';

import '../domain.dart';
import '../state.dart';
import '../ui.dart';
import 'expense_screens.dart';
import 'settlement_screen.dart';

class GroupFormScreen extends StatefulWidget {
  const GroupFormScreen({super.key, this.groupId});
  final String? groupId;
  @override
  State<GroupFormScreen> createState() => _GroupFormScreenState();
}

class _GroupFormScreenState extends State<GroupFormScreen> {
  final name = TextEditingController();
  final others = TextEditingController();
  String category = groupCategories.first;
  String? error;
  bool initialized = false, busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (initialized) return;
    initialized = true;
    final id = widget.groupId;
    if (id != null) {
      final group = AppScope.of(context).group(id);
      name.text = group.name;
      category = group.category;
    }
  }

  @override
  void dispose() {
    name.dispose();
    others.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (busy) return;
    final c = AppScope.of(context);
    if (name.text.trim().isEmpty) {
      setState(() => error = '請輸入群組名稱');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      var id = widget.groupId;
      if (id == null) {
        final names = others.text
            .split('\n')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        id = await c.change((r) => r.createGroup(name.text, category, names));
      } else {
        final existingId = id;
        await c.change((r) => r.editGroup(existingId, name.text, category));
      }
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = errorMessage(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final creating = widget.groupId == null;
    return Scaffold(
      appBar: AppBar(title: Text(creating ? '建立群組' : '編輯群組')),
      body: PageBody(
        children: [
          TextField(
            controller: name,
            decoration: const InputDecoration(
              labelText: '群組名稱',
              hintText: '例如：台南小旅行',
            ),
            textInputAction: TextInputAction.next,
          ),
          const SectionTitle('群組類型'),
          Wrap(
            spacing: 8,
            children: [
              for (final option in groupCategories)
                ChoiceChip(
                  label: Text(option),
                  selected: category == option,
                  onSelected: (_) => setState(() => category = option),
                ),
            ],
          ),
          if (creating) ...[
            const SectionTitle('成員'),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const CircleAvatar(child: Icon(Icons.person_outline)),
              title: Text(AppScope.of(context).data.defaultName),
              subtitle: const Text('我 · 自動加入'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: others,
              minLines: 2,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: '其他成員（選填）',
                helperText: '每行一位，也可以稍後新增。',
              ),
            ),
          ],
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(error!, style: const TextStyle(color: debitRed)),
            ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: busy ? null : save,
            child: Text(creating ? '儲存群組' : '儲存變更'),
          ),
        ],
      ),
    );
  }
}

class GroupScreen extends StatelessWidget {
  const GroupScreen({super.key, required this.groupId});
  final String groupId;

  Future<void> archive(BuildContext context, Ledger g) async {
    final c = AppScope.of(context);
    final action = g.archived ? '解除封存' : '封存';
    if (!await confirmAction(
      context,
      '$action群組',
      g.archived ? '解除封存後，可繼續記帳及管理成員。' : '封存後仍可查閱所有紀錄。',
      action,
    )) {
      return;
    }
    try {
      await c.change((r) => r.setArchived(groupId, !g.archived));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(errorMessage(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = AppScope.of(context).group(groupId);
    final value = BalanceService.balances(g)[g.self.id]!;
    final expenses = [...g.expenses]
      ..sort((a, b) => b.spentAt.compareTo(a.spentAt));
    final byCategory = g.expenseByCategory;
    return Scaffold(
      appBar: AppBar(
        title: Text(g.name),
        actions: [
          PopupMenuButton<String>(
            tooltip: '群組選項',
            itemBuilder: (_) => [
              if (!g.archived)
                const PopupMenuItem(value: 'edit', child: Text('編輯群組')),
              PopupMenuItem(
                value: 'archive',
                child: Text(g.archived ? '解除封存群組' : '封存群組'),
              ),
            ],
            onSelected: (option) {
              if (option == 'edit') {
                openPage<String>(context, GroupFormScreen(groupId: groupId));
              } else {
                archive(context, g);
              }
            },
          ),
        ],
      ),
      body: PageBody(
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Icon(categoryIcon(g.category), color: inkGreen),
                      Text(
                        '${g.category}${g.archived ? ' · 已封存' : ''} · 群組總消費',
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    Money.format(g.totalExpense),
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '我：${balanceLabel(value)}',
                    style: TextStyle(
                      color: value < 0 ? debitRed : inkGreen,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (!g.archived)
                FilledButton.icon(
                  onPressed: () =>
                      openPage(context, ExpenseFormScreen(groupId: groupId)),
                  icon: const Icon(Icons.add),
                  label: const Text('新增消費'),
                ),
              OutlinedButton.icon(
                onPressed: () =>
                    openPage(context, SettlementScreen(groupId: groupId)),
                icon: const Icon(Icons.swap_horiz),
                label: const Text('智慧結算'),
              ),
              OutlinedButton.icon(
                onPressed: () =>
                    openPage(context, MembersScreen(groupId: groupId)),
                icon: const Icon(Icons.people_outline),
                label: const Text('成員管理'),
              ),
            ],
          ),
          const SectionTitle('消費明細'),
          if (expenses.isEmpty)
            const EmptyCard(
              Icons.receipt_long_outlined,
              '尚無消費紀錄',
              '新增消費後，即可查看每個人的分攤與餘額。',
            ),
          for (final e in expenses)
            Card(
              child: ListTile(
                title: Text(e.title),
                subtitle: Text(
                  '${shortDate(e.spentAt)} · ${g.member(e.payerId).name} 支付\n${Money.format(e.amount)}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => openPage(
                  context,
                  ExpenseDetailScreen(groupId: groupId, expenseId: e.id),
                ),
              ),
            ),
          if (byCategory.isNotEmpty) ...[
            const SectionTitle('分類統計'),
            Card(
              child: Column(
                children: [
                  for (final entry in byCategory.entries)
                    ListTile(
                      title: Text(entry.key),
                      subtitle: Text(Money.format(entry.value)),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

Future<void> editName(
  BuildContext context, {
  required String title,
  required String initial,
  required Future<void> Function(String) save,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _NameDialog(title: title, initial: initial, save: save),
);

class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.initial,
    required this.save,
  });
  final String title, initial;
  final Future<void> Function(String) save;
  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late String value = widget.initial;
  String? error;
  bool busy = false;
  Future<void> submit() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.save(value);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = errorMessage(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.title),
    content: TextFormField(
      autofocus: true,
      initialValue: widget.initial,
      onChanged: (v) => value = v,
      decoration: InputDecoration(labelText: '名稱', errorText: error),
      onFieldSubmitted: (_) => submit(),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: busy ? null : submit, child: const Text('儲存')),
    ],
  );
}

class MembersScreen extends StatelessWidget {
  const MembersScreen({super.key, required this.groupId});
  final String groupId;
  @override
  Widget build(BuildContext context) {
    final c = AppScope.of(context);
    final g = c.group(groupId);
    final balances = BalanceService.balances(g);
    return Scaffold(
      appBar: AppBar(title: const Text('成員管理')),
      body: PageBody(
        children: [
          if (!g.archived)
            FilledButton.icon(
              icon: const Icon(Icons.person_add_outlined),
              label: const Text('新增成員'),
              onPressed: () => editName(
                context,
                title: '新增成員',
                initial: '',
                save: (name) => c.change((r) => r.addMember(groupId, name)),
              ),
            ),
          const SizedBox(height: 12),
          for (final m in g.members)
            Card(
              child: ListTile(
                title: Text(
                  '${m.name}${m.isSelf && m.name != '我' ? '（我）' : ''}${m.isActive ? '' : '（已停用）'}',
                ),
                leading: Icon(
                  m.isActive ? Icons.person_outline : Icons.person_off_outlined,
                  color: muted,
                ),
                subtitle: Text(
                  balanceLabel(balances[m.id]!),
                  style: TextStyle(
                    color: balances[m.id]! < 0 ? debitRed : inkGreen,
                  ),
                ),
                trailing: g.archived
                    ? null
                    : PopupMenuButton<String>(
                        tooltip: '${m.name}的成員選項',
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'rename',
                            child: Text('重新命名'),
                          ),
                          if (!m.isSelf && m.isActive)
                            PopupMenuItem(
                              value: 'deactivate',
                              enabled: balances[m.id] == 0,
                              child: Text(
                                balances[m.id] == 0 ? '停用成員' : '結清後可停用',
                              ),
                            ),
                        ],
                        onSelected: (v) async {
                          if (v == 'rename') {
                            await editName(
                              context,
                              title: '重新命名',
                              initial: m.name,
                              save: (name) => c.change(
                                (r) => r.renameMember(groupId, m.id, name),
                              ),
                            );
                          } else if (await confirmAction(
                            context,
                            '停用成員',
                            '保留${m.name}的歷史紀錄，新增消費時將不再預選這位成員。',
                            '停用',
                          )) {
                            try {
                              await c.change(
                                (r) => r.deactivateMember(groupId, m.id),
                              );
                            } catch (e) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(errorMessage(e))),
                                );
                              }
                            }
                          }
                        },
                      ),
              ),
            ),
        ],
      ),
    );
  }
}
