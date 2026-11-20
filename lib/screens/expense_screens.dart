import 'package:material_ui/material_ui.dart';

import '../data/repository.dart';
import '../domain.dart';
import '../state.dart';
import '../ui.dart';

const _methods = {
  SplitMethod.equal: '平均',
  SplitMethod.exact: '指定金額',
  SplitMethod.percent: '百分比',
  SplitMethod.weight: '權重',
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
  final _drafts = <SplitMethod, Map<String, String>>{};
  final _selected = <String>{};
  late final String _id;
  late final DateTime _createdAt;
  Expense? _original;
  late String _title, _amount, _payer, _category, _note;
  late DateTime _date;
  late SplitMethod _method;
  bool _initialized = false;
  bool _busy = false;
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
    if (old != null && _method != SplitMethod.equal) {
      _drafts[_method] = {
        for (final id in _selected)
          id: switch (_method) {
            SplitMethod.exact => Money.input(old.shares[id]!),
            SplitMethod.percent => Money.input(old.inputs[id]!),
            SplitMethod.weight => old.inputs[id]!.toString(),
            SplitMethod.equal => '',
          },
      };
    }
  }

  String _draft(String id) =>
      _drafts[_method]?[id] ?? (_method == SplitMethod.weight ? '1' : '');

  Map<String, int> _inputs() {
    if (_method == SplitMethod.equal) return {};
    final inputs = <String, int>{};
    for (final id in _selected) {
      final raw = _draft(id).trim();
      if (_method == SplitMethod.weight) {
        final value = int.tryParse(raw);
        if (!RegExp(r'^[0-9]+$').hasMatch(raw) ||
            value == null ||
            value < 1 ||
            value > 10000) {
          throw const FormatException('請為每位參與者填寫 1 至 10000 的整數權重。');
        }
        inputs[id] = value;
      } else {
        if (_method == SplitMethod.percent &&
            !RegExp(r'^[0-9]+(?:\.[0-9]{1,2})?$').hasMatch(raw)) {
          throw const FormatException('請填寫各人的百分比，最多至小數第二位。');
        }
        if (raw.isEmpty) throw const FormatException('請填寫每位參與者的分攤數值。');
        inputs[id] = Money.parse(raw, allowZero: true);
      }
    }
    if (_selected.isNotEmpty && _method == SplitMethod.percent) {
      final difference =
          10000 - inputs.values.fold<int>(0, (sum, value) => sum + value);
      if (difference != 0) {
        final units = '${Money.input(difference.abs())}%';
        throw FormatException('${difference > 0 ? '尚差' : '超出'} $units，請調整分攤。');
      }
    }
    return inputs;
  }

  Future<void> _save() async {
    if (_busy) return;
    final controller = AppScope.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final amount = Money.parse(_amount);
      final inputs = _inputs();
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
        shares: SplitService.divide(
          amount,
          _method,
          _selected.toList(),
          inputs,
        ),
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
    Map<String, int>? shares;
    String? previewError;
    try {
      final amount = Money.parse(_amount);
      shares = SplitService.divide(
        amount,
        _method,
        _selected.toList(),
        _inputs(),
      );
    } catch (e) {
      previewError = _amount.trim().isEmpty ? '請輸入消費金額。' : errorMessage(e);
    }

    final inputLabel = switch (_method) {
      SplitMethod.exact => '分攤金額',
      SplitMethod.percent => '百分比',
      SplitMethod.weight => '權重',
      SplitMethod.equal => '',
    };
    return Scaffold(
      appBar: AppBar(title: Text(heading)),
      body: AbsorbPointer(
        absorbing: _busy,
        child: PageBody(
          children: [
            if (editing && group.repayments.isNotEmpty)
              const Text('群組已有還款紀錄。修改消費會重新計算餘額與還款建議。'),
            TextFormField(
              initialValue: _title,
              decoration: const InputDecoration(labelText: '項目名稱'),
              textInputAction: TextInputAction.next,
              onChanged: (v) => setState(() => _title = v),
            ),
            const SizedBox(height: 12),
            TextFormField(
              initialValue: _amount,
              decoration: const InputDecoration(
                labelText: '消費金額',
                prefixText: 'NT\$ ',
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (v) => setState(() => _amount = v),
            ),
            const SizedBox(height: 12),
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
            DropdownButtonFormField<String>(
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
            const SizedBox(height: 12),
            TextFormField(
              initialValue: _note,
              maxLines: 2,
              minLines: 1,
              decoration: const InputDecoration(labelText: '備註（選填）'),
              onChanged: (v) => _note = v,
            ),
            const SectionTitle('分帳方式'),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final entry in _methods.entries)
                  ChoiceChip(
                    label: Text(entry.value),
                    selected: _method == entry.key,
                    onSelected: (_) => setState(() => _method = entry.key),
                  ),
              ],
            ),
            const SectionTitle('參與者'),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final m in members)
                  FilterChip(
                    label: Text(m.name),
                    selected: _selected.contains(m.id),
                    onSelected: (selected) => setState(() {
                      if (selected) {
                        _selected.add(m.id);
                      } else {
                        _selected.remove(m.id);
                      }
                    }),
                  ),
              ],
            ),
            if (_method != SplitMethod.equal)
              for (final m in members.where((m) => _selected.contains(m.id)))
                Padding(
                  key: ValueKey((_method, m.id)),
                  padding: const EdgeInsets.only(top: 10),
                  child: TextFormField(
                    initialValue: _draft(m.id),
                    decoration: InputDecoration(
                      labelText: '${m.name}的$inputLabel',
                      prefixText: _method == SplitMethod.exact ? 'NT\$ ' : null,
                      suffixText: _method == SplitMethod.percent ? '%' : null,
                    ),
                    keyboardType: TextInputType.numberWithOptions(
                      decimal: _method != SplitMethod.weight,
                    ),
                    onChanged: (v) =>
                        setState(() => (_drafts[_method] ??= {})[m.id] = v),
                  ),
                ),
            const SectionTitle('分帳預覽'),
            if (previewError != null) Text(previewError),
            if (shares != null)
              Card(
                child: Column(
                  children: [
                    for (final m in members.where(
                      (m) => _selected.contains(m.id),
                    ))
                      ListTile(
                        title: Text(m.name),
                        subtitle: Text(Money.format(shares[m.id]!)),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (shares != null && _title.trim().isEmpty) const Text('請填寫項目名稱。'),
            FilledButton(
              onPressed: _busy || shares == null || _title.trim().isEmpty
                  ? null
                  : _save,
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
