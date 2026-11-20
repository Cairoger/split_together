import 'package:material_ui/material_ui.dart';

import '../data/repository.dart';
import '../domain.dart';
import '../state.dart';
import '../ui.dart';
import 'expense_split_controls.dart';

const _methods = {
  SplitMethod.equal: '平分',
  SplitMethod.exact: '指定金額',
  SplitMethod.percent: '百分比',
  SplitMethod.weight: '按份數分',
};

class LedgerDateField extends StatelessWidget {
  const LedgerDateField({
    super.key,
    required this.label,
    required this.date,
    required this.onChanged,
  });

  final String label;
  final DateTime date;
  final ValueChanged<DateTime>? onChanged;

  @override
  Widget build(BuildContext context) {
    final local = date.toLocal();
    final changed = onChanged;
    return OutlinedButton.icon(
      icon: const Icon(Icons.calendar_today_outlined),
      label: Text('$label　${shortDate(local)}'),
      onPressed: changed == null
          ? null
          : () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: local,
                firstDate: DateTime(local.year < 1900 ? local.year : 1900),
                lastDate: DateTime(
                  local.year > 2100 ? local.year : 2100,
                  12,
                  31,
                ),
                helpText: '選擇$label',
                cancelText: '取消',
                confirmText: '確定',
              );
              if (picked != null && context.mounted) {
                changed(
                  DateTime(
                    picked.year,
                    picked.month,
                    picked.day,
                    local.hour,
                    local.minute,
                    local.second,
                  ),
                );
              }
            },
    );
  }
}

class ExpenseFormScreen extends StatefulWidget {
  const ExpenseFormScreen({super.key, required this.groupId, this.expenseId});

  final String groupId;
  final String? expenseId;

  @override
  State<ExpenseFormScreen> createState() => _ExpenseFormScreenState();
}

class _ExpenseFormScreenState extends State<ExpenseFormScreen> {
  static const _categories = ['餐飲', '交通', '住宿', '購物', '娛樂', '其他'];
  final _exactAmounts = <String, String>{};
  final _percentages = <String, int>{};
  final _portions = <String, int>{};
  final _selected = <String>{};
  late final String _id;
  late final DateTime _createdAt;
  Expense? _original;
  late String _title, _amount, _payer, _category, _note;
  late DateTime _date;
  late SplitMethod _method;
  bool _initialized = false;
  bool _busy = false;
  bool _moreExpanded = false;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final group = AppScope.of(context).group(widget.groupId);
    final old = group.expenses
        .where((e) => e.id == widget.expenseId)
        .firstOrNull;
    _original = old;
    _id = old?.id ?? newId();
    _createdAt = old?.createdAt ?? DateTime.now().toUtc();
    _title = old?.title ?? '';
    _amount = old == null ? '' : Money.input(old.amount);
    _payer = old?.payerId ?? group.self.id;
    _category = old?.category ?? _categories.first;
    _note = old?.note ?? '';
    _date = old?.spentAt.toLocal() ?? DateTime.now();
    _method = old?.method ?? SplitMethod.equal;
    _selected.addAll(
      old?.shares.keys ??
          group.members.where((m) => m.isActive).map((m) => m.id),
    );
    if (old != null) {
      switch (old.method) {
        case SplitMethod.exact:
          _exactAmounts.addAll(
            old.shares.map((id, n) => MapEntry(id, Money.input(n))),
          );
        case SplitMethod.percent:
          _percentages.addAll(old.inputs);
        case SplitMethod.weight:
          _portions.addAll(old.inputs);
        case SplitMethod.equal:
          break;
      }
    }
  }

  // 百分比以基點儲存。分配剩餘基點時，沿用平分對成員 ID 的尾差順序。
  void _distributePercent(int points, List<String> ids) {
    if (ids.isEmpty) return;
    _percentages.addAll(
      points == 0
          ? {for (final id in ids) id: 0}
          : SplitService.divide(points, SplitMethod.equal, ids, const {}),
    );
  }

  void _startPercentDraft() {
    if (_method == SplitMethod.percent && _percentages.isEmpty) {
      _distributePercent(10000, _selected.toList());
    }
  }

  void _changeValue(String id, int value) {
    setState(() {
      if (_method == SplitMethod.weight) {
        _portions[id] = value;
      } else if (_method == SplitMethod.percent) {
        _percentages[id] = value;
        if (_selected.length == 2) {
          final other = _selected.firstWhere((memberId) => memberId != id);
          _percentages[other] = 10000 - value;
        }
      }
    });
  }

  void _splitRemainder(String keepId) {
    setState(
      () => _distributePercent(
        10000 - (_percentages[keepId] ?? 0),
        _selected.where((id) => id != keepId).toList(),
      ),
    );
  }

  Future<void> _save(
    int amount,
    Map<String, int> inputs,
    Map<String, int> shares,
  ) async {
    if (_busy) return;
    final controller = AppScope.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final expense = Expense(
        id: _id,
        title: _title.trim(),
        amount: amount,
        payerId: _payer,
        method: _method,
        category: _category,
        spentAt: _date.toUtc(),
        note: _note.trim(),
        createdAt: _createdAt,
        updatedAt: DateTime.now().toUtc(),
        shares: shares,
        inputs: inputs,
      );
      await controller.change(
        (repo) => repo.saveExpense(widget.groupId, expense),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = errorMessage(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final group = AppScope.of(context).group(widget.groupId);
    final editing = widget.expenseId != null;
    final heading = editing ? '編輯消費' : '新增消費';
    if (group.archived || (editing && _original == null)) {
      return Scaffold(
        appBar: AppBar(title: Text(heading)),
        body: Center(child: Text(group.archived ? '群組已封存' : '找不到這筆消費')),
      );
    }
    final members = group.members.where(
      (m) => m.isActive || (_original?.shares.containsKey(m.id) ?? false),
    );
    final payers = group.members.where(
      (m) => m.isActive || _original?.payerId == m.id,
    );
    final categories = {..._categories, _category};
    final participants = members
        .where((m) => _selected.contains(m.id))
        .toList();
    final values = switch (_method) {
      SplitMethod.weight => {
        for (final id in _selected) id: _portions[id] ?? 1,
      },
      SplitMethod.percent => {
        for (final id in _selected) id: _percentages[id] ?? 0,
      },
      _ => const <String, int>{},
    };
    Map<String, int> inputs = values;
    int? amount;
    Map<String, int>? shares;
    String? previewError;
    try {
      amount = Money.parse(_amount);
      if (_method == SplitMethod.exact) {
        if (participants.any(
          (m) => (_exactAmounts[m.id] ?? '').trim().isEmpty,
        )) {
          throw const FormatException('請填寫每位參與者的分攤金額。');
        }
        inputs = {
          for (final member in participants)
            member.id: Money.parse(
              _exactAmounts[member.id] ?? '',
              allowZero: true,
            ),
        };
      }
      // 合計不足或超出的百分比由圖表說明，待調整後才顯示金額。
      if (_method != SplitMethod.percent ||
          _selected.isEmpty ||
          values.values.fold(0, (a, b) => a + b) == 10000) {
        shares = SplitService.divide(
          amount,
          _method,
          _selected.toList(),
          inputs,
        );
      }
    } on FormatException catch (e) {
      previewError = _amount.trim().isEmpty ? '請輸入消費金額。' : errorMessage(e);
    }
    return Scaffold(
      appBar: AppBar(title: Text(heading)),
      body: AbsorbPointer(
        absorbing: _busy,
        child: PageBody(
          children: [
            if (editing && group.repayments.isNotEmpty)
              const Text('群組已有還款紀錄。修改消費會重新計算餘額與還款建議。'),
            TextFormField(
              key: const ValueKey('expense-amount'),
              initialValue: _amount,
              decoration: const InputDecoration(
                labelText: '消費金額',
                prefixText: 'NT\$ ',
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              textInputAction: TextInputAction.next,
              onChanged: (v) => setState(() => _amount = v),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const ValueKey('expense-title'),
              initialValue: _title,
              decoration: const InputDecoration(labelText: '項目名稱'),
              onChanged: (v) => setState(() => _title = v),
            ),
            const SectionTitle('誰先付'),
            DropdownButtonFormField<String>(
              key: const ValueKey('expense-payer'),
              initialValue: _payer,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '付款人'),
              items: [
                for (final m in payers)
                  DropdownMenuItem(
                    value: m.id,
                    child: Text(m.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) => setState(() => _payer = v!),
            ),
            const SectionTitle('誰要分攤'),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final m in members)
                  FilterChip(
                    key: ValueKey('expense-member-${m.id}'),
                    label: Text(m.name),
                    selected: _selected.contains(m.id),
                    onSelected: (selected) {
                      FocusManager.instance.primaryFocus?.unfocus();
                      setState(() {
                        if (selected) {
                          _selected.add(m.id);
                        } else {
                          _selected.remove(m.id);
                        }
                        _startPercentDraft();
                      });
                    },
                  ),
              ],
            ),
            const SectionTitle('分帳方式'),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final entry in _methods.entries)
                  ChoiceChip(
                    key: ValueKey('expense-method-${entry.key.name}'),
                    label: Text(entry.value),
                    selected: _method == entry.key,
                    onSelected: (_) {
                      FocusManager.instance.primaryFocus?.unfocus();
                      setState(() {
                        _method = entry.key;
                        _startPercentDraft();
                      });
                    },
                  ),
              ],
            ),
            const SizedBox(height: 12),
            ExpenseSplitControls(
              key: ValueKey(_method),
              method: _method,
              members: participants,
              amount: amount,
              shares: shares,
              values: values,
              exactDrafts: _exactAmounts,
              onValueChanged: _changeValue,
              onExactChanged: (id, value) =>
                  setState(() => _exactAmounts[id] = value),
              onSplitRemainder: _splitRemainder,
            ),
            if (previewError != null) Text(previewError),
            ExpansionTile(
              key: const ValueKey('expense-more'),
              initiallyExpanded: _moreExpanded,
              onExpansionChanged: (expanded) => _moreExpanded = expanded,
              title: const Text('更多資料'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 12),
              expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LedgerDateField(
                  label: '消費日期',
                  date: _date,
                  onChanged: (v) => setState(() => _date = v),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _category,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '分類'),
                  items: [
                    for (final category in categories)
                      DropdownMenuItem(value: category, child: Text(category)),
                  ],
                  onChanged: (v) => setState(() => _category = v!),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  initialValue: _note,
                  maxLines: 2,
                  minLines: 1,
                  decoration: const InputDecoration(labelText: '備註（選填）'),
                  onChanged: (v) => _note = v,
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (shares != null && _title.trim().isEmpty) const Text('請填寫項目名稱。'),
            FilledButton(
              key: const ValueKey('expense-save'),
              onPressed:
                  _busy ||
                      amount == null ||
                      shares == null ||
                      _title.trim().isEmpty
                  ? null
                  : () => _save(amount!, inputs, shares!),
              child: Text(_busy ? '儲存中…' : '儲存消費'),
            ),
          ],
        ),
      ),
    );
  }
}

class ExpenseDetailScreen extends StatefulWidget {
  const ExpenseDetailScreen({
    super.key,
    required this.groupId,
    required this.expenseId,
  });
  final String groupId, expenseId;

  @override
  State<ExpenseDetailScreen> createState() => _ExpenseDetailScreenState();
}

class _ExpenseDetailScreenState extends State<ExpenseDetailScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _delete(Ledger group, Expense expense) async {
    if (_busy) return;
    final controller = AppScope.of(context);
    setState(() => _busy = true);
    try {
      final message =
          '確定刪除「${expense.title}」及這筆分攤？'
          '${group.repayments.isEmpty ? '' : '既有還款紀錄會保留，餘額及結算建議將重新計算。'}';
      if (!await confirmAction(context, '刪除消費', message, '刪除') || !mounted) {
        return;
      }
      await controller.change(
        (repo) => repo.deleteExpense(group.id, expense.id),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final group = AppScope.of(context).group(widget.groupId);
    final expense = group.expenses
        .where((e) => e.id == widget.expenseId)
        .firstOrNull;
    return Scaffold(
      appBar: AppBar(title: const Text('消費明細')),
      body: expense == null
          ? const Center(child: Text('找不到這筆消費'))
          : PageBody(
              children: [
                Text(
                  expense.title,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                Text(
                  Money.format(expense.amount),
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                Text(
                  '${shortDate(expense.spentAt.toLocal())}　·　${expense.category}',
                ),
                Text('付款人　${group.member(expense.payerId).name}'),
                if (expense.note.isNotEmpty) Text(expense.note),
                SectionTitle('分攤明細 · ${_methods[expense.method]}'),
                Card(
                  child: Column(
                    children: [
                      for (final m in group.members.where(
                        (m) => expense.shares.containsKey(m.id),
                      ))
                        ListTile(
                          title: Text(m.name),
                          subtitle: Text(Money.format(expense.shares[m.id]!)),
                        ),
                    ],
                  ),
                ),
                if (_error != null) Text(_error!),
                if (!group.archived) ...[
                  FilledButton.icon(
                    onPressed: _busy
                        ? null
                        : () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => ExpenseFormScreen(
                                groupId: group.id,
                                expenseId: expense.id,
                              ),
                            ),
                          ),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('編輯消費'),
                  ),
                  TextButton.icon(
                    onPressed: _busy ? null : () => _delete(group, expense),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('刪除消費'),
                  ),
                ],
              ],
            ),
    );
  }
}
