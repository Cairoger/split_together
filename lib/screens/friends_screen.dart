import 'package:material_ui/material_ui.dart';

import '../bank_apps.dart';
import '../domain.dart';
import '../state.dart';
import '../ui.dart';

String friendAccountSummary(SavedFriend friend) {
  final code = friend.bankCode, tail = friend.lastFour;
  if (code == null || tail == null) return '尚無收款帳號';
  return '${bankLabel(code)} · 末四碼 $tail';
}

class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key});

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  String search = '';

  @override
  Widget build(BuildContext context) {
    final friends = AppScope.of(context).data.friends;
    final matches = _matchingFriends(friends, search);
    return Scaffold(
      appBar: AppBar(title: const Text('常用朋友')),
      body: PageBody(
        children: [
          if (friends.isEmpty)
            const EmptyCard(
              Icons.contacts_outlined,
              '尚無常用朋友',
              '新增群組成員時勾選「存為常用朋友」，下次分帳就能直接選取。',
            )
          else ...[
            TextField(
              decoration: const InputDecoration(
                labelText: '搜尋朋友',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (v) => setState(() => search = v),
            ),
            const SizedBox(height: 12),
            if (matches.isEmpty) const Text('沒有符合的朋友'),
            for (final friend in matches)
              Card(
                child: ListTile(
                  key: ValueKey(friend.id),
                  title: Text(friend.name),
                  subtitle: Text(friendAccountSummary(friend)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => openPage(
                    context,
                    FriendDetailScreen(friendId: friend.id),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

List<SavedFriend> _matchingFriends(List<SavedFriend> friends, String input) {
  final query = input.trim().toLowerCase();
  return friends.where((f) => f.name.toLowerCase().contains(query)).toList()
    ..sort((a, b) {
      final byName = a.name.compareTo(b.name);
      return byName == 0 ? a.id.compareTo(b.id) : byName;
    });
}

class FriendDetailScreen extends StatefulWidget {
  const FriendDetailScreen({super.key, required this.friendId});
  final String friendId;

  @override
  State<FriendDetailScreen> createState() => _FriendDetailScreenState();
}

class _FriendDetailScreenState extends State<FriendDetailScreen> {
  bool busy = false;
  String? error;

  Future<void> readAccount(SavedFriend friend, {required bool copy}) async {
    if (busy) return;
    final c = AppScope.of(context);
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final value = await c.repo.readFriendAccount(friend.id);
      if (value == null) throw const FormatException('尚無收款帳號');
      if (!mounted) return;
      if (copy) {
        await copyAccount(value);
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('已複製收款帳號')));
        }
      } else {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('${friend.name}的收款帳號'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(bankLabel(friend.bankCode!)),
                const SizedBox(height: 8),
                Text(value),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('關閉'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = errorMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> removeAccount(SavedFriend friend) async {
    if (busy) return;
    final c = AppScope.of(context);
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (await confirmAction(
            context,
            '刪除收款帳號',
            '「${friend.name}」在各群組使用的這組收款資料將一併移除，既有帳目會保留。',
            '刪除',
          ) &&
          mounted) {
        await c.change((repo) => repo.setFriendAccount(friend.id, null, null));
      }
    } catch (e) {
      if (mounted) setState(() => error = errorMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppScope.of(context);
    final friend = c.data.friends
        .where((f) => f.id == widget.friendId)
        .firstOrNull;
    if (friend == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('常用朋友')),
        body: const Center(child: Text('找不到這位朋友')),
      );
    }
    final hasAccount = friend.lastFour != null;
    return Scaffold(
      appBar: AppBar(title: Text(friend.name)),
      body: PageBody(
        children: [
          const SectionTitle('收款帳號'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.account_balance_outlined),
              title: Text(friendAccountSummary(friend)),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (hasAccount) ...[
                OutlinedButton.icon(
                  icon: const Icon(Icons.visibility_outlined),
                  label: const Text('查看完整帳號'),
                  onPressed: busy
                      ? null
                      : () => readAccount(friend, copy: false),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.copy),
                  label: const Text('複製收款帳號'),
                  onPressed: busy
                      ? null
                      : () => readAccount(friend, copy: true),
                ),
              ],
              FilledButton.icon(
                icon: const Icon(Icons.edit_outlined),
                label: Text(hasAccount ? '編輯收款資料' : '新增收款資料'),
                onPressed: busy
                    ? null
                    : () => openPage(context, _AccountEditor(friend: friend)),
              ),
              if (hasAccount)
                TextButton(
                  onPressed: busy ? null : () => removeAccount(friend),
                  child: const Text('刪除收款帳號'),
                ),
            ],
          ),
          if (error != null) _ErrorText(error!),
        ],
      ),
    );
  }
}

class _AccountEditor extends StatefulWidget {
  const _AccountEditor({required this.friend});
  final SavedFriend friend;
  @override
  State<_AccountEditor> createState() => _AccountEditorState();
}

class _AccountEditorState extends State<_AccountEditor> {
  final form = GlobalKey<FormState>();
  late final bank = TextEditingController(text: widget.friend.bankCode);
  final number = TextEditingController();
  String? error;
  bool busy = false;
  @override
  void dispose() {
    bank.dispose();
    number.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (busy || !form.currentState!.validate()) return;
    final c = AppScope.of(context);
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final code = _bankCode(bank.text)!;
      final account = normalizeAccountNumber(number.text);
      await c.change(
        (repo) => repo.setFriendAccount(widget.friend.id, code, account),
      );
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
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('收款資料')),
    body: Form(
      key: form,
      child: PageBody(
        children: [
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: Text(widget.friend.name),
            subtitle: Text(friendAccountSummary(widget.friend)),
          ),
          _BankFields(bank: bank, number: number),
          if (error != null) _ErrorText(error!),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: busy ? null : save,
            child: const Text('儲存收款資料'),
          ),
        ],
      ),
    ),
  );
}

const _aliases = {
  '822': ['中信', '中國信託銀行'],
  '812': ['台新', '臺新', '臺新銀行'],
  '700': ['郵局', '行動郵局'],
};

String? _bankCode(String input) {
  final query = input.trim();
  if (RegExp(r'^[0-9]{3}$').hasMatch(query)) return query;
  for (final bank in bankNames.entries) {
    if (bank.value == query ||
        bankLabel(bank.key) == query ||
        (_aliases[bank.key]?.contains(query) ?? false)) {
      return bank.key;
    }
  }
  return null;
}

class _BankFields extends StatelessWidget {
  const _BankFields({required this.bank, required this.number});
  final TextEditingController bank, number;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextFormField(
        controller: bank,
        decoration: const InputDecoration(
          labelText: '銀行名稱或代碼',
          helperText: '其他銀行可直接輸入三碼代碼。',
        ),
        validator: (v) => _bankCode(v ?? '') == null ? '請選擇銀行或輸入三碼代碼' : null,
        autovalidateMode: AutovalidateMode.onUserInteraction,
      ),
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: bank,
        builder: (_, value, _) {
          final query = value.text.trim();
          if (_bankCode(query) != null) return const SizedBox.shrink();
          return Wrap(
            spacing: 6,
            children: [
              for (final entry in bankNames.entries)
                if (entry.key.contains(query) ||
                    entry.value.contains(query) ||
                    (_aliases[entry.key]?.any(
                          (alias) => alias.contains(query),
                        ) ??
                        false))
                  ActionChip(
                    label: Text(bankLabel(entry.key)),
                    onPressed: () => bank.text = entry.key,
                  ),
            ],
          );
        },
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: number,
        keyboardType: TextInputType.number,
        autocorrect: false,
        enableSuggestions: false,
        decoration: const InputDecoration(labelText: '收款帳號'),
        validator: (v) {
          try {
            normalizeAccountNumber(v ?? '');
            return null;
          } on FormatException catch (e) {
            return e.message;
          }
        },
      ),
    ],
  );
}

class _ErrorText extends StatelessWidget {
  const _ErrorText(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(
      message,
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    ),
  );
}

Future<void> showMemberSheet(
  BuildContext context, {
  required Set<String> usedNames,
  required Set<String> usedFriendIds,
  required Future<void> Function(MemberDraft) save,
  String? linkName,
}) => showModalBottomSheet<void>(
  context: context,
  useSafeArea: true,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (ctx) => _MemberSheet(
    usedNames: usedNames,
    usedFriendIds: usedFriendIds,
    save: save,
    linkName: linkName,
  ),
);

class _MemberSheet extends StatefulWidget {
  const _MemberSheet({
    required this.usedNames,
    required this.usedFriendIds,
    required this.save,
    this.linkName,
  });
  final Set<String> usedNames, usedFriendIds;
  final String? linkName;
  final Future<void> Function(MemberDraft) save;
  @override
  State<_MemberSheet> createState() => _MemberSheetState();
}

class _MemberSheetState extends State<_MemberSheet> {
  late final name = TextEditingController(text: widget.linkName);
  final bank = TextEditingController();
  final account = TextEditingController();
  String search = '';
  String? selectedId, error;
  late bool saveFriend = widget.linkName != null;
  bool selectSaved = false, busy = false, touchedName = false;
  bool get linking => widget.linkName != null;

  @override
  void dispose() {
    name.dispose();
    bank.dispose();
    account.dispose();
    super.dispose();
  }

  String? get nameError {
    if (name.text.trim().isEmpty) return '請輸入成員名稱';
    if (widget.usedNames.contains(name.text.trim())) return '群組裡已經有這個名稱';
    return null;
  }

  void switchTab(bool saved) {
    if (saved == selectSaved) return;
    setState(() {
      selectSaved = saved;
      selectedId = null;
      search = '';
      touchedName = false;
      error = null;
      if (!linking) name.clear();
    });
  }

  Future<void> submit() async {
    if (busy || nameError != null || (selectSaved && selectedId == null)) {
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      String? code, number;
      if (!selectSaved &&
          saveFriend &&
          (bank.text.trim().isNotEmpty || account.text.trim().isNotEmpty)) {
        code = _bankCode(bank.text);
        if (code == null) throw const FormatException('請在收款資料中選擇銀行或輸入三碼代碼');
        number = normalizeAccountNumber(account.text);
      }
      await widget.save(
        MemberDraft(
          name: name.text.trim(),
          friendId: selectedId,
          saveAsFriend: !selectSaved && saveFriend,
          bankCode: code,
          accountNumber: number,
        ),
      );
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
  Widget build(BuildContext context) {
    final friends = AppScope.of(context).data.friends;
    final matches = _matchingFriends(friends, search);
    final choice = friends.where((f) => f.id == selectedId).firstOrNull;
    final submitLabel = linking ? '儲存連結' : '加入成員';
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .85,
          ),
          child: AbsorbPointer(
            absorbing: busy,
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
              children: [
                Text(
                  linking ? '連結常用朋友' : '新增成員',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: Text(linking ? '建立朋友資料' : '輸入姓名'),
                      selected: !selectSaved,
                      onSelected: (_) => switchTab(false),
                    ),
                    ChoiceChip(
                      label: const Text('從常用朋友選取'),
                      selected: selectSaved,
                      onSelected: (_) => switchTab(true),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (selectSaved && choice == null) ...[
                  TextField(
                    decoration: const InputDecoration(
                      labelText: '搜尋朋友',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (v) => setState(() => search = v),
                  ),
                  if (matches.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(friends.isEmpty ? '尚無常用朋友' : '沒有符合的朋友'),
                    ),
                  for (final friend in matches)
                    ListTile(
                      key: ValueKey(friend.id),
                      enabled: !widget.usedFriendIds.contains(friend.id),
                      title: Text(friend.name),
                      subtitle: Text(
                        widget.usedFriendIds.contains(friend.id)
                            ? '已在此群組'
                            : friendAccountSummary(friend),
                      ),
                      onTap: () => setState(() {
                        selectedId = friend.id;
                        if (!linking) name.text = friend.name;
                        touchedName = true;
                        error = null;
                      }),
                    ),
                ],
                if (choice != null)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.contacts_outlined),
                    title: Text(choice.name),
                    subtitle: Text(friendAccountSummary(choice)),
                    trailing: IconButton(
                      tooltip: '重新選擇朋友',
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() {
                        selectedId = null;
                        search = '';
                      }),
                    ),
                  ),
                if (!selectSaved || choice != null)
                  TextField(
                    controller: name,
                    readOnly: linking,
                    decoration: InputDecoration(
                      labelText: '成員名稱',
                      errorText: touchedName ? nameError : null,
                    ),
                    onChanged: (_) => setState(() {
                      touchedName = true;
                      error = null;
                    }),
                  ),
                if (!selectSaved) ...[
                  if (!linking)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('存為常用朋友'),
                      value: saveFriend,
                      onChanged: (v) => setState(() => saveFriend = v),
                    ),
                  if (saveFriend)
                    ExpansionTile(
                      title: const Text('收款資料（選填）'),
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: const EdgeInsets.only(bottom: 10),
                      maintainState: true,
                      children: [_BankFields(bank: bank, number: account)],
                    ),
                ],
                if (error != null) _ErrorText(error!),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed:
                      busy ||
                          nameError != null ||
                          (selectSaved && choice == null)
                      ? null
                      : submit,
                  child: Text(submitLabel),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
