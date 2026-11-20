import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../data/repository.dart';
import '../domain.dart';
import '../state.dart';
import '../ui.dart';
import 'expense_screens.dart' show LedgerDateField;

class SettlementScreen extends StatefulWidget {
  const SettlementScreen({super.key, required this.groupId});
  final String groupId;

  @override
  State<SettlementScreen> createState() => _SettlementScreenState();
}

class _SettlementScreenState extends State<SettlementScreen> {
  bool _deleting = false;
  String? _error;

  String _direction(Ledger group, String from, String to) =>
      '${group.member(from).name} → ${group.member(to).name}';

  Future<void> _copy(Ledger group, List<Transfer> suggestions) async {
    final text = [
      '${group.name}｜建議還款清單',
      for (final t in suggestions)
        '${_direction(group, t.fromId, t.toId)}　${Money.format(t.amount)}',
    ].join('\n');
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已複製還款清單')));
      }
    } catch (_) {
      if (mounted) setState(() => _error = '無法使用剪貼簿，請再試一次。');
    }
  }

  Future<void> _remove(Ledger group, Repayment payment) async {
    if (_deleting) return;
    final controller = AppScope.of(context);
    setState(() {
      _deleting = true;
      _error = null;
    });
    try {
      final direction = _direction(group, payment.fromId, payment.toId);
      if (!await confirmAction(
            context,
            '撤銷還款紀錄',
            '確定撤銷「$direction　${Money.format(payment.amount)}」？餘額會重新計算；如需更正，可再次記錄還款。',
            '撤銷紀錄',
          ) ||
          !mounted) {
        return;
      }
      await controller.change(
        (repo) => repo.deleteRepayment(group.id, payment.id),
      );
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  void _form([Transfer? suggestion]) {
    openPage<void>(
      context,
      _RepaymentForm(groupId: widget.groupId, suggestion: suggestion),
    );
  }

  @override
  Widget build(BuildContext context) {
    final group = AppScope.of(context).group(widget.groupId);
    final balances = BalanceService.balances(group);
    final suggestions = SettlementService.suggest(balances);
    return Scaffold(
      appBar: AppBar(title: const Text('智慧結算')),
      body: PageBody(
        children: [
          Text(group.name, style: Theme.of(context).textTheme.headlineSmall),
          const SectionTitle('還款建議'),
          if (suggestions.isEmpty)
            const Card(
              child: ListTile(
                leading: Icon(Icons.check_circle_outline, color: inkGreen),
                title: Text('所有帳目已結清'),
              ),
            )
          else ...[
            for (final t in suggestions)
              Card(
                child: ListTile(
                  title: Text(_direction(group, t.fromId, t.toId)),
                  subtitle: Text(Money.format(t.amount)),
                  trailing: group.archived
                      ? null
                      : const Icon(Icons.chevron_right),
                  onTap: group.archived ? null : () => _form(t),
                ),
              ),
            const SizedBox(height: 8),
            if (!group.archived)
              FilledButton.icon(
                onPressed: _form,
                icon: const Icon(Icons.add),
                label: const Text('記錄還款'),
              ),
            OutlinedButton.icon(
              onPressed: () => _copy(group, suggestions),
              icon: const Icon(Icons.copy),
              label: const Text('複製還款清單'),
            ),
          ],
          const SectionTitle('成員餘額'),
          Card(
            child: Column(
              children: [
                for (final m in group.members)
                  ListTile(
                    title: Text(m.name),
                    subtitle: Text(
                      balanceLabel(balances[m.id]!),
                      style: TextStyle(
                        color: switch (balances[m.id]!.sign) {
                          -1 => debitRed,
                          1 => inkGreen,
                          _ => muted,
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SectionTitle('還款紀錄'),
          if (_error != null)
            Text(_error!, style: const TextStyle(color: debitRed)),
          if (group.repayments.isEmpty) const Text('尚無還款紀錄。'),
          for (final payment in group.repayments)
            Card(
              child: ListTile(
                title: Text(_direction(group, payment.fromId, payment.toId)),
                subtitle: Text(
                  [
                    '${Money.format(payment.amount)}　·　${shortDate(payment.paidAt)}',
                    if (payment.note.isNotEmpty) payment.note,
                  ].join('\n'),
                ),
                trailing: group.archived
                    ? null
                    : IconButton(
                        tooltip: '撤銷還款紀錄',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: _deleting
                            ? null
                            : () => _remove(group, payment),
                      ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RepaymentForm extends StatefulWidget {
  const _RepaymentForm({required this.groupId, this.suggestion});
  final String groupId;
  final Transfer? suggestion;

  @override
  State<_RepaymentForm> createState() => _RepaymentFormState();
}

class _RepaymentFormState extends State<_RepaymentForm> {
  final _amount = TextEditingController();
  final _id = newId();
  String? _from, _to, _error;
  var _note = '';
  var _date = DateTime.now();
  bool _initialized = false;
  bool _busy = false;

  int _limit(Map<String, int> balances) => math.min(
    Money.maxMinor,
    math.min(-(balances[_from] ?? 0), balances[_to] ?? 0),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final balances = BalanceService.balances(
      AppScope.of(context).group(widget.groupId),
    );
    final suggestion =
        widget.suggestion ?? SettlementService.suggest(balances).firstOrNull;
    _from = suggestion?.fromId;
    _to = suggestion?.toId;
    if (suggestion != null) {
      _amount.text = Money.input(math.min(suggestion.amount, Money.maxMinor));
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _submit(Ledger group) async {
    if (_busy) return;
    final controller = AppScope.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final from = _from!, to = _to!, amount = Money.parse(_amount.text);
      final direction = '${group.member(from).name} → ${group.member(to).name}';
      final ok = await confirmAction(
        context,
        '確認已還款',
        '$direction\n'
            '${shortDate(_date)} 已實際支付 ${Money.format(amount)}？',
        '確認記錄',
      );
      if (!ok || !mounted) return;
      final payment = Repayment(
        id: _id,
        fromId: from,
        toId: to,
        amount: amount,
        paidAt: _date.toUtc(),
        note: _note.trim(),
        createdAt: DateTime.now().toUtc(),
      );
      await controller.change((repo) => repo.addRepayment(group.id, payment));
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final group = AppScope.of(context).group(widget.groupId);
    final balances = BalanceService.balances(group);
    final debtors = group.members.where((m) => balances[m.id]! < 0);
    final creditors = group.members.where((m) => balances[m.id]! > 0);
    final limit = _limit(balances);
    String? invalid;
    try {
      final value = Money.parse(_amount.text);
      if (value > limit) invalid = '還款金額超過可記錄上限。';
    } catch (e) {
      invalid = _amount.text.isEmpty ? '請輸入還款金額。' : errorMessage(e);
    }
    final from = debtors.any((m) => m.id == _from) ? _from : null;
    final to = creditors.any((m) => m.id == _to) ? _to : null;
    return Scaffold(
      appBar: AppBar(title: const Text('記錄還款')),
      body: PageBody(
        children: [
          if (group.archived)
            const Text('群組已封存')
          else if (debtors.isEmpty)
            const Text('所有帳目已結清')
          else ...[
            DropdownButtonFormField<String>(
              initialValue: from,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '付款人'),
              items: [
                for (final m in debtors)
                  DropdownMenuItem(
                    value: m.id,
                    child: Text(m.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                      _from = value;
                      _amount.text = Money.input(_limit(balances));
                    }),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: to,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '收款人'),
              items: [
                for (final m in creditors)
                  DropdownMenuItem(
                    value: m.id,
                    child: Text(m.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                      _to = value;
                      _amount.text = Money.input(_limit(balances));
                    }),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _amount,
              readOnly: _busy,
              decoration: InputDecoration(
                labelText: '還款金額',
                prefixText: 'NT\$ ',
                helperText: '本次最多可記錄 ${Money.format(math.max(0, limit))}',
                helperMaxLines: 2,
                errorText: invalid,
                errorMaxLines: 2,
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            LedgerDateField(
              label: '還款日期',
              date: _date,
              onChanged: _busy ? null : (v) => setState(() => _date = v),
            ),
            const SizedBox(height: 12),
            TextFormField(
              readOnly: _busy,
              initialValue: _note,
              maxLines: 3,
              minLines: 1,
              decoration: const InputDecoration(labelText: '備註（選填）'),
              onChanged: (v) => _note = v,
            ),
            const SizedBox(height: 20),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: debitRed)),
            FilledButton(
              onPressed: _busy || invalid != null || from == null || to == null
                  ? null
                  : () => _submit(group),
              child: Text(_busy ? '處理中…' : '儲存還款'),
            ),
          ],
        ],
      ),
    );
  }
}
