import 'package:material_ui/material_ui.dart';

import '../domain.dart';
import '../state.dart';
import '../ui.dart';
import 'expense_screens.dart';
import 'friends_screen.dart';
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
  final members = <MemberDraft>[];
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

  Set<String> get usedNames => {
    AppScope.of(context).data.defaultName,
    for (final member in members) member.name,
  };

  List<String> get typedNames => others.text
      .split(RegExp(r'[\r\n]+'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();

  String? typedError(List<String> names) {
    final taken = usedNames;
    for (final value in names) {
      if (!taken.add(value)) return '群組裡已經有「$value」';
    }
    return null;
  }

  void collectNames() {
    final names = typedNames;
    if (typedError(names) != null) return;
    setState(() {
      members.addAll(names.map((n) => MemberDraft(name: n)));
      others.clear();
    });
  }

  Future<void> pickMember() async {
    if (typedError(typedNames) != null) return;
    collectNames();
    await showMemberSheet(
      context,
      usedNames: usedNames,
      usedFriendIds: members.map((m) => m.friendId).whereType<String>().toSet(),
      save: (draft) async => setState(() => members.add(draft)),
    );
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
        final names = typedNames;
        final issue = typedError(names);
        if (issue != null) throw FormatException(issue);
        id = await c.change(
          (r) => r.createGroupWithMembers(name.text, category, [
            ...members,
            for (final item in names) MemberDraft(name: item),
          ]),
        );
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
            if (members.isNotEmpty)
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final m in members)
                    InputChip(
                      label: Text(m.name),
                      avatar: m.friendId == null && !m.saveAsFriend
                          ? null
                          : const Icon(Icons.contacts_outlined, size: 16),
                      deleteButtonTooltipMessage: '移除${m.name}',
                      onDeleted: busy
                          ? null
                          : () => setState(() => members.remove(m)),
                    ),
                ],
              ),
            if (members.isNotEmpty) const SizedBox(height: 8),
            TextField(
              controller: others,
              enabled: !busy,
              minLines: 1,
              maxLines: 4,
              onChanged: (value) {
                if (value.contains('\n') && typedError(typedNames) == null) {
                  collectNames();
                } else {
                  setState(() {});
                }
              },
              decoration: InputDecoration(
                labelText: '其他成員（選填）',
                helperText: '可一次貼上多行姓名，每行一位。',
                errorText: typedError(typedNames),
              ),
            ),
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.add),
                  onPressed:
                      busy ||
                          typedNames.isEmpty ||
                          typedError(typedNames) != null
                      ? null
                      : collectNames,
                  label: const Text('加入名單'),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.contacts_outlined),
                  onPressed: busy || typedError(typedNames) != null
                      ? null
                      : pickMember,
                  label: const Text('新增或選取朋友'),
                ),
              ],
            ),
          ],
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: busy || (creating && typedError(typedNames) != null)
                ? null
                : save,
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
                      Icon(
                        categoryIcon(g.category),
                        color: Theme.of(context).colorScheme.primary,
                      ),
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
                      color: balanceColor(Theme.of(context).colorScheme, value),
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
    final friends = {for (final friend in c.data.friends) friend.id: friend};
    return Scaffold(
      appBar: AppBar(title: const Text('成員管理')),
      body: PageBody(
        children: [
          if (!g.archived)
            FilledButton.icon(
              icon: const Icon(Icons.person_add_outlined),
              label: const Text('新增成員'),
              onPressed: () => showMemberSheet(
                context,
                usedNames: g.members.map((m) => m.name).toSet(),
                usedFriendIds: g.members
                    .map((m) => m.friendId)
                    .whereType<String>()
                    .toSet(),
                save: (draft) =>
                    c.change((r) => r.addGroupMember(groupId, draft)),
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
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      balanceLabel(balances[m.id]!),
                      style: TextStyle(
                        color: balanceColor(
                          Theme.of(context).colorScheme,
                          balances[m.id]!,
                        ),
                      ),
                    ),
                    if (friends[m.friendId] case final friend?)
                      Text(friendAccountSummary(friend)),
                  ],
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
                          if (!m.isSelf)
                            PopupMenuItem(
                              value: 'friend',
                              child: Text(
                                m.friendId == null ? '連結常用朋友' : '朋友收款資料',
                              ),
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
                          } else if (v == 'friend') {
                            final id = m.friendId;
                            if (id != null) {
                              await openPage(
                                context,
                                FriendDetailScreen(friendId: id),
                              );
                            } else {
                              await showMemberSheet(
                                context,
                                linkName: m.name,
                                usedNames: g.members
                                    .where((other) => other.id != m.id)
                                    .map((m) => m.name)
                                    .toSet(),
                                usedFriendIds: g.members
                                    .map((m) => m.friendId)
                                    .whereType<String>()
                                    .toSet(),
                                save: (draft) => c.change(
                                  (r) =>
                                      r.linkMemberFriend(groupId, m.id, draft),
                                ),
                              );
                            }
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
