import 'package:material_ui/material_ui.dart';

import '../data/repository.dart';
import '../domain.dart';
import '../state.dart';
import '../ui.dart';
import 'group_screens.dart' show editName;
import 'quick_meal_result_screen.dart';

class QuickMealScreen extends StatefulWidget {
  const QuickMealScreen({super.key});

  @override
  State<QuickMealScreen> createState() => _QuickMealScreenState();
}

class _QuickMealScreenState extends State<QuickMealScreen> {
  final _draftId = newId();
  final _createdAt = DateTime.now().toUtc();
  final _attendees = <String>{};
  final _guests = <String, String>{};
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

  Map<String, String> _choices(AppData data) {
    final friends = data.quickMealPeople;
    final ids = <String>{quickMealSelfId};
    for (final meal in data.quickMeals) {
      ids.addAll(meal.people.keys.where(friends.containsKey));
      if (ids.length == friends.length) break;
    }
    ids.addAll(friends.keys);
    final choices = {for (final id in ids) id: friends[id]!};
    final names = {...friends.values, ..._guests.values};
    final used = friends.values.toSet();
    for (final guest in _guests.entries) {
      var label = guest.value;
      if (used.contains(label)) {
        var number = 1;
        do {
          label = '${guest.value}（臨時 ${number++}）';
        } while (names.contains(label) || used.contains(label));
      }
      used.add(label);
      choices[guest.key] = label;
    }
    return choices;
  }

  void _selectAttendee(String id, bool selected) {
    FocusManager.instance.primaryFocus?.unfocus();
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

  Future<void> _addGuest() => editName(
    context,
    title: '新增臨時參與者',
    initial: '',
    helperText: '多人可用頓號或換行分隔，例如「小林、小安」。',
    maxLines: 3,
    save: (value) async {
      final names = value
          .split(RegExp(r'[、，,\r\n]+'))
          .map((name) => name.trim())
          .where((name) => name.isNotEmpty)
          .toList();
      if (names.isEmpty) throw const FormatException('請輸入參與者的名字。');
      setState(() {
        for (final name in names) {
          final id = quickMealGuestId(_draftId, _guests.length + 1);
          _guests[id] = name;
          _attendees.add(id);
        }
        _saveError = null;
      });
    },
  );

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
    FocusManager.instance.primaryFocus?.unfocus();
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
          _saveError = error is FormatException
              ? '${error.message}\n輸入已保留，請再試一次。'
              : '這次儲存失敗，輸入已保留。請確認裝置儲存空間後再試一次。';
        });
      }
      return;
    }
    if (mounted) {
      Navigator.of(context).pushReplacement<void, void>(
        MaterialPageRoute(builder: (_) => QuickMealResultScreen(meal: meal)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final people = _choices(AppScope.of(context).data);
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
    final missing = [
      if (total == null) '有效的帳單總額',
      if (attending.length < 2) '至少兩位出席者',
      if (payer == null) '一位付款人',
    ];
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
    final submit = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_saveError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Semantics(
              liveRegion: true,
              child: Text(
                _saveError!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          ),
        FilledButton(
          key: const ValueKey('meal-save'),
          onPressed: preview == null || _saving ? null : () => _save(preview),
          child: Text(_saving ? '儲存中…' : '儲存並看分帳結果'),
        ),
      ],
    );
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('快速聚餐'),
          actions: [
            TextButton(
              onPressed: _saving
                  ? null
                  : () =>
                        openPage<void>(context, const QuickMealHistoryScreen()),
              child: const Text('聚餐紀錄'),
            ),
          ],
        ),
        body: LayoutBuilder(
          builder: (context, constraints) {
            // 極矮的鍵盤可視區讓按鈕一起捲動，保留欄位與提示的操作空間。
            final pinButton =
                constraints.maxHeight >=
                120 +
                    MediaQuery.textScalerOf(context)
                        .scale(_saveError == null ? 48 : 144);
            return Column(
              children: [
                Expanded(
                  child: PageBody(
                    children: [
                      TextField(
                        key: const ValueKey('meal-amount'),
                        controller: _amount,
                        readOnly: _saving,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        textInputAction: TextInputAction.done,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                        decoration: InputDecoration(
                          labelText: '帳單總額',
                          floatingLabelBehavior: FloatingLabelBehavior.always,
                          hintText: '0',
                          prefixText: r'NT$ ',
                          errorText: amountError,
                          errorMaxLines: 3,
                        ),
                        onChanged: (_) => setState(() {
                          _editedAmount = true;
                          _saveError = null;
                        }),
                      ),
                      const SectionTitle('今天有哪些人'),
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
                      Wrap(
                        spacing: 4,
                        children: [
                          TextButton.icon(
                            key: const ValueKey('meal-add-guest'),
                            onPressed: _saving ? null : _addGuest,
                            icon: const Icon(Icons.person_add_alt_1_outlined),
                            label: const Text('新增臨時參與者'),
                          ),
                          TextButton(
                            key: const ValueKey('meal-add-friend'),
                            onPressed: _saving ? null : _addFriend,
                            child: const Text('新增朋友'),
                          ),
                        ],
                      ),
                      const SectionTitle('誰先付'),
                      if (attending.isEmpty)
                        const Text('先勾選出席的人，再選一位付款人。')
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
                                    : (_) {
                                        FocusManager.instance.primaryFocus
                                            ?.unfocus();
                                        setState(() {
                                          _payerId = person.key;
                                          _payerWasRemoved = false;
                                          _saveError = null;
                                        });
                                      },
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
                      const SizedBox(height: 12),
                      if (missing.isNotEmpty)
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            '還需要${missing.join('、')}。',
                            key: const ValueKey('meal-missing'),
                          ),
                        ),
                      if (!pinButton) submit,
                      if (preview != null)
                        ExpansionTile(
                          key: const ValueKey('meal-preview'),
                          title: const Text('預覽全桌分攤'),
                          children: [MealBreakdown(meal: preview)],
                        ),
                    ],
                  ),
                ),
                if (pinButton)
                  SafeArea(
                    top: false,
                    minimum: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 640),
                      child: SizedBox(width: double.infinity, child: submit),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
