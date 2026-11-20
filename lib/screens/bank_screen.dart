import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform, Uint8List;
import 'package:material_ui/material_ui.dart';

import '../bank_apps.dart';
import '../bank_launcher.dart';
import '../domain.dart';
import '../state.dart';
import '../ui.dart';

class BankAppScreen extends StatefulWidget {
  const BankAppScreen({super.key});

  @override
  State<BankAppScreen> createState() => _BankAppScreenState();
}

class _BankAppScreenState extends State<BankAppScreen> {
  bool busy = false;
  String? error;
  Future<List<BankAppChoice>>? installed;
  final search = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (BankLauncher.canListAndroidApps) {
      installed = BankLauncher.listAndroidApps();
    }
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> select(
    Future<BankAppChoice?> Function() choose, {
    bool allowClear = false,
  }) async {
    if (busy) return;
    final c = AppScope.of(context);
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final choice = await choose();
      if ((choice == null && !allowClear) || !mounted) return;
      if (choice != null &&
          BankLauncher.canListAndroidApps &&
          !await BankLauncher.isAndroidAppAvailable(choice.id)) {
        if (mounted) {
          setState(() => error = '這個 App 已無法開啟，未變更預設選擇。');
        }
        return;
      }
      if (!mounted) return;
      await c.change((r) => r.setBankApp(choice));
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) setState(() => error = '無法選取或儲存轉帳 App，請再試一次。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<BankAppChoice?> shortcut() async {
    String name = '';
    final existing = AppScope.of(context).data.bankApp;
    if (existing != null && existing.id.startsWith('ios-shortcut:')) {
      name = existing.id.substring('ios-shortcut:'.length);
    }
    return showDialog<BankAppChoice>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) {
          final trimmed = name.trim();
          final valid =
              trimmed.isNotEmpty &&
              trimmed.runes.length <= 100 &&
              !RegExp(r'[\x00-\x1F\x7F]').hasMatch(trimmed);
          return AlertDialog(
            scrollable: true,
            title: const Text('使用我的捷徑'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '先在 iPhone「捷徑」新增「打開 App」動作，選擇你的銀行 App，再於此填入相同的捷徑名稱。',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  initialValue: name,
                  maxLength: 100,
                  onChanged: (v) => update(() => name = v),
                  decoration: const InputDecoration(labelText: '捷徑名稱'),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: valid
                    ? () => Navigator.pop(
                        ctx,
                        BankAppChoice(
                          id: 'ios-shortcut:$trimmed',
                          label: trimmed,
                        ),
                      )
                    : null,
                child: const Text('使用捷徑'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _androidPicker(BankAppChoice? current) {
    final colors = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !busy,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('我的轉帳 App'),
          bottom: busy
              ? const PreferredSize(
                  preferredSize: Size.fromHeight(4),
                  child: LinearProgressIndicator(),
                )
              : null,
        ),
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: TextField(
                  controller: search,
                  enabled: !busy,
                  onChanged: (_) => setState(() {}),
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    labelText: '搜尋已安裝的 App',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: search.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清除搜尋',
                            onPressed: busy
                                ? null
                                : () => setState(search.clear),
                            icon: const Icon(Icons.clear),
                          ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(error!, style: TextStyle(color: colors.error)),
                  ),
                ),
              Expanded(
                child: FutureBuilder<List<BankAppChoice>>(
                  future: installed,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('無法讀取已安裝的 App。'),
                            TextButton(
                              onPressed: () => setState(() {
                                installed = BankLauncher.listAndroidApps();
                              }),
                              child: const Text('重試'),
                            ),
                          ],
                        ),
                      );
                    }
                    final apps = snapshot.requireData;
                    final knownIds = bankApps.map((app) => app.id).toSet();
                    final labelCounts = <String, int>{};
                    for (final app in apps) {
                      final label = app.label.toLowerCase();
                      labelCounts.update(
                        label,
                        (value) => value + 1,
                        ifAbsent: () => 1,
                      );
                    }
                    final query = search.text.trim().toLowerCase();
                    final visible = apps.where((app) {
                      final label = app.label.toLowerCase();
                      return label.contains(query) ||
                          (labelCounts[label]! > 1 &&
                              app.id.toLowerCase().contains(query));
                    }).toList();
                    final recommended = visible.where(
                      (app) => knownIds.contains(app.id),
                    );
                    final others = visible.where(
                      (app) => !knownIds.contains(app.id),
                    );
                    final rows = <Object>[
                      if (recommended.isNotEmpty) ...['常用銀行', ...recommended],
                      if (others.isNotEmpty) ...['其他已安裝的 App', ...others],
                    ];
                    if (rows.isEmpty) {
                      return Center(
                        child: Text(
                          apps.isEmpty ? '沒有可選擇的 App。' : '找不到符合的 App。',
                        ),
                      );
                    }
                    return ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      itemCount: rows.length,
                      itemBuilder: (context, index) {
                        final row = rows[index];
                        if (row is String) {
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                            child: Text(
                              row,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          );
                        }
                        final app = row as BankAppChoice;
                        final selected = app.id == current?.id;
                        return ListTile(
                          key: ValueKey(app.id),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          selected: selected,
                          selectedTileColor: colors.secondaryContainer,
                          selectedColor: colors.onSecondaryContainer,
                          leading: _InstalledAppIcon(id: app.id),
                          title: Text(
                            app.label,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: labelCounts[app.label.toLowerCase()]! > 1
                              ? Text(
                                  app.id,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                )
                              : null,
                          trailing: selected
                              ? const Icon(
                                  Icons.check_circle,
                                  semanticLabel: '已選取',
                                )
                              : null,
                          onTap: busy
                              ? null
                              : () {
                                  FocusScope.of(context).unfocus();
                                  select(() async => app);
                                },
                        );
                      },
                      findChildIndexCallback: (key) {
                        if (key is! ValueKey<String>) return null;
                        final index = rows.indexWhere(
                          (row) => row is BankAppChoice && row.id == key.value,
                        );
                        return index < 0 ? null : index;
                      },
                    );
                  },
                ),
              ),
              if (current != null)
                TextButton(
                  onPressed: busy
                      ? null
                      : () => select(() async => null, allowClear: true),
                  child: const Text('清除預設選擇'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = AppScope.of(context).data.bankApp;
    if (BankLauncher.canListAndroidApps) return _androidPicker(current);
    final choices = [
      ...bankApps,
      if (current != null && !bankApps.any((b) => b.id == current.id)) current,
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('我的轉帳 App')),
      body: PageBody(
        children: [
          const Text('選擇你自己用來轉帳的 App。朋友的收款銀行可以不同。'),
          const SectionTitle('選擇 App'),
          for (final choice in choices)
            Card(
              child: ListTile(
                title: Text(choice.label),
                selected: choice.id == current?.id,
                leading: const Icon(Icons.account_balance_outlined),
                trailing: choice.id == current?.id
                    ? const Icon(Icons.check, semanticLabel: '已選取')
                    : null,
                subtitle:
                    defaultTargetPlatform == TargetPlatform.iOS &&
                        !BankLauncher.supportsDirectOpen(choice)
                    ? const Text('從 App Store 開啟，或使用自己的捷徑')
                    : null,
                onTap: busy ? null : () => select(() async => choice),
              ),
            ),
          if (defaultTargetPlatform == TargetPlatform.iOS)
            ListTile(
              leading: const Icon(Icons.launch),
              title: const Text('使用我的捷徑'),
              onTap: busy ? null : () => select(shortcut),
            ),
          if (current != null)
            TextButton(
              onPressed: busy
                  ? null
                  : () => select(() async => null, allowClear: true),
              child: const Text('清除預設選擇'),
            ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    );
  }
}

class _InstalledAppIcon extends StatefulWidget {
  const _InstalledAppIcon({required this.id});
  final String id;

  @override
  State<_InstalledAppIcon> createState() => _InstalledAppIconState();
}

class _InstalledAppIconState extends State<_InstalledAppIcon> {
  late final Future<Uint8List?> image = BankLauncher.androidAppIcon(widget.id);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget fallback() => ColoredBox(
      color: colors.surfaceContainerHighest,
      child: Icon(
        Icons.apps_outlined,
        color: colors.onSurfaceVariant,
        size: 22,
      ),
    );
    return SizedBox.square(
      dimension: 40,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: FutureBuilder<Uint8List?>(
          future: image,
          builder: (context, snapshot) => snapshot.data == null
              ? fallback()
              : Image.memory(
                  snapshot.data!,
                  fit: BoxFit.contain,
                  excludeFromSemantics: true,
                  errorBuilder: (context, error, stack) => fallback(),
                ),
        ),
      ),
    );
  }
}

class RecipientBankCard extends StatefulWidget {
  const RecipientBankCard({super.key, required this.member});
  final Member member;
  @override
  State<RecipientBankCard> createState() => _RecipientBankCardState();
}

class _RecipientBankCardState extends State<RecipientBankCard> {
  bool busy = false;
  String? status;

  Future<void> copy(String id) async {
    if (busy) return;
    final repository = AppScope.of(context).repo;
    setState(() {
      busy = true;
      status = null;
    });
    try {
      final number = await repository.readFriendAccount(id);
      if (number == null) throw StateError('missing');
      if (!mounted) return;
      await copyAccount(number);
      if (mounted) setState(() => status = '已複製收款帳號');
    } catch (_) {
      if (mounted) setState(() => status = '無法複製帳號，請到常用朋友確認收款資料。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> launch(BankAppChoice? selected) async {
    if (busy) return;
    if (selected == null) {
      await openPage<void>(context, const BankAppScreen());
      return;
    }
    setState(() {
      busy = true;
      status = null;
    });
    try {
      if (!BankLauncher.supportsDirectOpen(selected)) {
        if (!await BankLauncher.openOfficialPage(selected) && mounted) {
          setState(() => status = '無法開啟商店頁面，請手動打開銀行 App。');
        }
        return;
      }
      if (await BankLauncher.open(selected) || !mounted) return;
      if (bankApps.any((b) => b.id == selected.id)) {
        final viewStore = await confirmAction(
          context,
          '無法開啟${selected.label}',
          '請確認手機已安裝此 App。也可以前往官方商店頁面查看。',
          '前往商店',
        );
        if (viewStore &&
            mounted &&
            !await BankLauncher.openOfficialPage(selected) &&
            mounted) {
          setState(() => status = '無法開啟商店頁面，請手動打開銀行 App。');
        }
      } else {
        setState(() => status = '無法開啟所選項目，請在「我的轉帳 App」重新選取。');
      }
    } catch (_) {
      if (mounted) setState(() => status = '無法開啟選定項目，請手動打開銀行 App。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = AppScope.of(context).data;
    final friend = data.friends
        .where((f) => f.id == widget.member.friendId)
        .firstOrNull;
    final bankCode = friend?.bankCode;
    final lastFour = friend?.lastFour;
    final choice = data.bankApp;
    final launchLabel = choice == null
        ? '選擇我的轉帳 App'
        : choice.id.startsWith('ios-shortcut:')
        ? '執行捷徑：${choice.label}'
        : BankLauncher.supportsDirectOpen(choice)
        ? '開啟${choice.label}'
        : '從 App Store 查看${choice.label}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.member.name}的收款資料',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              bankCode != null && lastFour != null
                  ? '${bankLabel(bankCode)} · 末四碼 $lastFour'
                  : '尚未儲存收款帳號',
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                if (friend != null && lastFour != null)
                  OutlinedButton.icon(
                    onPressed: busy ? null : () => copy(friend.id),
                    icon: const Icon(Icons.copy),
                    label: const Text('複製收款帳號'),
                  ),
                OutlinedButton.icon(
                  onPressed: busy ? null : () => launch(choice),
                  icon: const Icon(Icons.open_in_new),
                  label: Text(launchLabel),
                ),
              ],
            ),
            if (status != null)
              Semantics(liveRegion: true, child: Text(status!)),
            const SizedBox(height: 6),
            const Text('實際轉帳後，再於下方儲存還款紀錄。'),
          ],
        ),
      ),
    );
  }
}
