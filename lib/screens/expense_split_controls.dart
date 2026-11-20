import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:material_ui/material_ui.dart';

import '../domain.dart';

class ExpenseSplitControls extends StatefulWidget {
  const ExpenseSplitControls({
    super.key,
    required this.method,
    required this.members,
    required this.amount,
    required this.shares,
    required this.values,
    required this.exactDrafts,
    required this.onValueChanged,
    required this.onExactChanged,
    required this.onSplitRemainder,
  });

  final SplitMethod method;
  final List<Member> members;
  final int? amount;
  final Map<String, int>? shares;
  final Map<String, int> values;
  final Map<String, String> exactDrafts;
  final void Function(String, int) onValueChanged;
  final void Function(String, String) onExactChanged;
  final ValueChanged<String> onSplitRemainder;

  @override
  State<ExpenseSplitControls> createState() => _ExpenseSplitControlsState();
}

class _ExpenseSplitControlsState extends State<ExpenseSplitControls> {
  String? _expanded;

  @override
  void didUpdateWidget(covariant ExpenseSplitControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.method != oldWidget.method ||
        !widget.members.any((m) => m.id == _expanded)) {
      _expanded = null;
    }
  }

  Future<void> _editValue(Member member) async {
    final method = widget.method;
    final isPercent = method == SplitMethod.percent;
    final oldValue = widget.values[member.id]!;
    FocusManager.instance.primaryFocus?.unfocus();
    final value = await showDialog<int>(
      context: context,
      builder: (_) => _ValueDialog(
        name: member.name,
        isPercent: isPercent,
        initialValue: oldValue,
      ),
    );
    if (value != null &&
        mounted &&
        widget.method == method &&
        widget.members.any((m) => m.id == member.id)) {
      widget.onValueChanged(member.id, value);
    }
  }

  Widget _weightButtons(Member member) {
    final id = member.id;
    final value = widget.values[id]!;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        IconButton.outlined(
          key: ValueKey('weight-minus-$id'),
          tooltip: '減少${member.name}的份數',
          icon: const Icon(Icons.remove),
          onPressed: value > 1
              ? () => widget.onValueChanged(id, value - 1)
              : null,
        ),
        TextButton(
          key: ValueKey('weight-value-$id'),
          onPressed: () => _editValue(member),
          child: Text(
            '$value 份',
            semanticsLabel: '輸入${member.name}的份數，目前 $value 份',
          ),
        ),
        IconButton.outlined(
          key: ValueKey('weight-plus-$id'),
          tooltip: '增加${member.name}的份數',
          icon: const Icon(Icons.add),
          onPressed: value < 10000
              ? () => widget.onValueChanged(id, value + 1)
              : null,
        ),
      ],
    );
  }

  Widget _percentButtons(Member member, String label) {
    final id = member.id;
    final expanded = _expanded == id;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Tooltip(
          message: '精確輸入至小數第二位',
          child: TextButton(
            key: ValueKey('percent-value-$id'),
            onPressed: () => _editValue(member),
            child: Text(
              label,
              semanticsLabel: '輸入${member.name}的百分比，目前 $label',
            ),
          ),
        ),
        IconButton.outlined(
          key: ValueKey('percent-toggle-$id'),
          tooltip: '${expanded ? '收合' : '展開'}${member.name}的百分比滑桿',
          icon: Icon(expanded ? Icons.expand_less : Icons.tune),
          onPressed: () => setState(() => _expanded = expanded ? null : id),
        ),
      ],
    );
  }

  Widget _memberRow(Member member, Color? color, String? percentLabel) {
    final id = member.id;
    final shares = widget.shares;
    final theme = Theme.of(context);
    return Padding(
      key: ValueKey((widget.method, id)),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 4,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (color != null) ...[
                        _Swatch(color),
                        const SizedBox(width: 8),
                      ],
                      Flexible(
                        child: Text(
                          member.name,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                    ],
                  ),
                  if (shares != null)
                    Text(
                      Money.format(shares[id]!),
                      key: ValueKey('split-share-$id'),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                ],
              ),
              if (widget.method == SplitMethod.weight) _weightButtons(member),
              if (percentLabel != null) _percentButtons(member, percentLabel),
            ],
          ),
          if (widget.method == SplitMethod.exact) ...[
            const SizedBox(height: 6),
            TextFormField(
              key: ValueKey('split-exact-$id'),
              initialValue: widget.exactDrafts[id] ?? '',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: '${member.name}的分攤金額',
                prefixText: r'NT$ ',
              ),
              onChanged: (v) => widget.onExactChanged(id, v),
            ),
          ],
          if (widget.method == SplitMethod.percent && _expanded == id) ...[
            Semantics(
              label: '${member.name}的百分比，每格 1%',
              child: Slider(
                key: ValueKey('percent-slider-$id'),
                min: 0,
                max: 100,
                divisions: 100,
                value: widget.values[id]! / 100,
                label: percentLabel,
                semanticFormatterCallback: (v) =>
                    '${Money.input((v * 100).round())}%',
                onChanged: (v) => widget.onValueChanged(id, (v * 100).round()),
              ),
            ),
            if (widget.members.length > 2)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: ValueKey('percent-remainder-$id'),
                  onPressed: () => widget.onSplitRemainder(id),
                  child: Text('保留${member.name}的 $percentLabel，其餘人平分'),
                ),
              ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.members.isEmpty) return const SizedBox.shrink();
    final method = widget.method;
    final byWeight = method == SplitMethod.weight;
    final byPercent = method == SplitMethod.percent;
    final theme = Theme.of(context);
    final colors = theme.brightness == Brightness.dark
        ? const [
            Color(0xff78cfba),
            Color(0xffe0ad68),
            Color(0xff96b6ee),
            Color(0xffdb9dc3),
            Color(0xffb4c580),
          ]
        : const [
            Color(0xff167561),
            Color(0xffb87920),
            Color(0xff597bb4),
            Color(0xffa66390),
            Color(0xff7d873a),
          ];
    final parts = [
      if (byWeight || byPercent)
        for (final (i, m) in widget.members.indexed)
          (value: widget.values[m.id]!, color: colors[i % colors.length]),
    ];
    final total = parts.fold(0, (sum, part) => sum + part.value);
    final showHundredths =
        byPercent && parts.any((part) => part.value % 100 != 0);
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (byWeight) ...[
              const SizedBox(height: 8),
              Text('總份數 $total 份', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              ClipRRect(
                key: const ValueKey('weight-bar'),
                borderRadius: BorderRadius.circular(6),
                child: Row(
                  children: [
                    for (final part in parts)
                      Expanded(
                        flex: part.value,
                        child: ColoredBox(
                          color: part.color,
                          child: const SizedBox(height: 10),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (byPercent)
              _PercentSummary(
                amount: widget.amount,
                parts: parts,
                total: total,
              ),
            for (final (i, member) in widget.members.indexed) ...[
              if (i > 0 || byWeight || byPercent) const Divider(height: 1),
              _memberRow(
                member,
                parts.isEmpty ? null : parts[i].color,
                byPercent
                    ? _percentLabel(parts[i].value, showHundredths)
                    : null,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _percentLabel(int basisPoints, bool showHundredths) {
  if (!showHundredths) return '${basisPoints ~/ 100}%';
  final hundredths = (basisPoints % 100).toString().padLeft(2, '0');
  return '${basisPoints ~/ 100}.$hundredths%';
}

class _ValueDialog extends StatefulWidget {
  const _ValueDialog({
    required this.name,
    required this.isPercent,
    required this.initialValue,
  });
  final String name;
  final bool isPercent;
  final int initialValue;

  @override
  State<_ValueDialog> createState() => _ValueDialogState();
}

class _ValueDialogState extends State<_ValueDialog> {
  late final TextEditingController _controller;
  late int? _value;

  @override
  void initState() {
    super.initState();
    _value = widget.initialValue;
    final text = widget.isPercent
        ? Money.input(widget.initialValue)
        : widget.initialValue.toString();
    _controller = TextEditingController.fromValue(
      TextEditingValue(
        text: text,
        selection: TextSelection(baseOffset: 0, extentOffset: text.length),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int? _parse(String raw) {
    if (widget.isPercent) {
      try {
        final value = Money.parse(raw, allowZero: true);
        return value <= 10000 ? value : null;
      } on FormatException {
        return null;
      }
    }
    if (!RegExp(r'^[0-9]+$').hasMatch(raw.trim())) return null;
    final value = int.tryParse(raw.trim());
    return value != null && value >= 1 && value <= 10000 ? value : null;
  }

  @override
  Widget build(BuildContext context) {
    final unit = widget.isPercent ? '百分比' : '份數';
    final range = widget.isPercent ? '0 至 100%，最多兩位小數' : '1 至 10,000 的整數';
    return AlertDialog(
      scrollable: true,
      title: Text('${widget.name}的$unit'),
      content: TextFormField(
        key: const ValueKey('split-precise-input'),
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.numberWithOptions(
          decimal: widget.isPercent,
        ),
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          labelText: unit,
          suffixText: widget.isPercent ? '%' : '份',
          helperText: _value != null ? range : null,
          helperMaxLines: 3,
          errorText: _value == null ? '請輸入$range' : null,
          errorMaxLines: 3,
        ),
        onChanged: (raw) => setState(() => _value = _parse(raw)),
        onFieldSubmitted: (_) {
          if (_value != null) Navigator.pop(context, _value);
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _value == null
              ? null
              : () => Navigator.pop(context, _value),
          child: const Text('套用'),
        ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch(this.color);
  final Color color;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    child: const SizedBox.square(dimension: 10),
  );
}

typedef _Part = ({int value, Color color});

class _PercentSummary extends StatelessWidget {
  const _PercentSummary({
    required this.amount,
    required this.parts,
    required this.total,
  });
  final int? amount;
  final List<_Part> parts;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final remaining = 10000 - total;
    final excess = remaining < 0 ? '${Money.input(-remaining)}%' : null;
    final dark = theme.brightness == Brightness.dark;
    final gray = dark ? Colors.grey.shade600 : Colors.grey.shade400;
    final warningRing = dark ? Colors.orange.shade200 : Colors.orange.shade300;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 166),
            child: AspectRatio(
              aspectRatio: 1,
              child: CustomPaint(
                key: const ValueKey('percent-donut'),
                painter: _DonutPainter([
                  if (excess != null)
                    (value: 10000, color: warningRing)
                  else ...[
                    ...parts,
                    if (remaining > 0) (value: remaining, color: gray),
                  ],
                ]),
                child: Padding(
                  padding: const EdgeInsets.all(23),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (excess == null)
                          Text('帳單總額', style: theme.textTheme.labelMedium),
                        Text(
                          excess != null
                              ? '超出 $excess'
                              : amount == null
                              ? '—'
                              : Money.format(amount!),
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          if (excess != null)
            Text('請從任一人減少共 $excess', textAlign: TextAlign.center)
          else if (remaining > 0)
            Wrap(
              spacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _Swatch(gray),
                Text('尚未分配 ${Money.input(remaining)}%'),
              ],
            )
          else
            const Text('已分配 100%'),
        ],
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  const _DonutPainter(this.parts);
  final List<_Part> parts;

  @override
  void paint(Canvas canvas, Size size) {
    final width = size.shortestSide * 0.1;
    final rect = (Offset.zero & size).deflate(width / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    var start = -math.pi / 2;
    for (final part in parts) {
      if (part.value == 0) continue;
      final sweep = 2 * math.pi * part.value / 10000;
      canvas.drawArc(rect, start, sweep, false, paint..color = part.color);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter oldDelegate) =>
      !listEquals(parts, oldDelegate.parts);
}
