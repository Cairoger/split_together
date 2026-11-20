import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
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

  @override
  Widget build(BuildContext context) {
    final current = AppScope.of(context).data.bankApp;
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
          if (defaultTargetPlatform == TargetPlatform.android)
            ListTile(
              leading: const Icon(Icons.apps_outlined),
              title: const Text('選擇其他已安裝的 App'),
              onTap: busy ? null : () => select(BankLauncher.pickAndroidApp),
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
