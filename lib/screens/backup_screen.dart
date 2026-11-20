import 'package:material_ui/material_ui.dart';

import '../services/drive_backup_gateway.dart';
import '../services/ledger_backup_service.dart';
import '../state.dart';
import '../ui.dart';

String _dateTime(DateTime instant) {
  final local = instant.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${shortDate(local)} ${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

class BackupScreen extends StatefulWidget {
  const BackupScreen({
    super.key,
    this.gateway = const AndroidDriveBackupGateway(),
  });
  final DriveBackupGateway gateway;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  String? account, activity, message;
  DateTime? latest;
  bool queried = false;

  DriveBackupGateway get drive => widget.gateway;
  LedgerBackupService get service =>
      LedgerBackupService(AppScope.of(context).repo, drive);

  @override
  void initState() {
    super.initState();
    if (drive.isSupported) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _run('讀取備份資訊…', _open);
      });
    }
  }

  void _clearAccount() {
    account = null;
    latest = null;
    queried = false;
  }

  Future<void> _readIdentity() async {
    final selected = await drive.currentAccount();
    if (selected != account) _clearAccount();
    account = selected;
    if (selected != null) {
      latest ??= await drive.lastKnownBackup(selected);
    }
  }

  Future<String?> _open() async {
    await _readIdentity();
    final selected = account;
    if (selected != null && mounted) await _versions(selected);
    return null;
  }

  Future<List<DriveBackupFile>> _versions(String selected) async {
    final files = await service.versions(selected);
    latest = files.firstOrNull?.createdAt;
    queried = true;
    await drive.rememberLatest(selected, latest);
    return files;
  }

  Future<void> _run(String label, Future<String?> Function() action) async {
    if (activity != null) return;
    setState(() {
      activity = label;
      message = null;
    });
    try {
      message = await action();
    } catch (error) {
      message = switch (error) {
        DriveBackupException() => error.message,
        FormatException() => error.message,
        _ => '操作未完成，請確認網路連線及裝置儲存空間後再試。',
      };
      try {
        await _readIdentity();
      } catch (_) {
        _clearAccount();
      }
    } finally {
      if (mounted) setState(() => activity = null);
    }
  }

  Future<String?> _connect() async {
    setState(_clearAccount);
    if (await drive.connect() == null) {
      await _readIdentity();
      return '已取消連結。';
    }
    return _open();
  }

  Future<String?> _disconnect() async {
    await drive.disconnect();
    _clearAccount();
    return '已解除連結。本機帳目與 Drive 上的備份都已保留。';
  }

  Future<String?> _backup() async {
    final selected = account!;
    final confirmed = await _confirm(
      '將帳本備份到 Google Drive？',
      '目的帳戶：$selected\n\n上傳群組、成員、消費與分攤、還款、聚餐歷史及常用朋友，包含名稱與帳目備註。'
          '銀行收款欄位、登入權杖及裝置設定均排除。新手機需重新設定銀行收款資料。',
      '確認備份',
    );
    if (!confirmed || !mounted) return null;
    final receipt = await service.backUp(selected);
    // 整理期間也可能需要重新授權；不要把成功時間掛到別的帳戶。
    try {
      await _readIdentity();
    } catch (_) {
      _clearAccount();
    }
    if (selected != account) return '這次備份已成功。請重新連結帳戶以查看備份。';
    latest = receipt.latest;
    queried = true;
    return receipt.cleanupPending ? '這次備份已成功，舊版本尚未整理。下次備份成功時會再整理。' : '備份成功。';
  }

  Future<String?> _restore() async {
    final selected = account!;
    final controller = AppScope.of(context);
    final backups = service;
    await backups.requireEmpty();
    if (!mounted) return null;
    final files = await _versions(selected);
    if (files.isEmpty) return '這個帳戶尚無可還原的備份。';
    if (!mounted) return null;
    final choice = await showDialog<DriveBackupFile>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('選擇備份'),
        children: [
          for (final (i, file) in files.indexed)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, file),
              child: Text(
                '${i == 0 ? '最新備份' : '較早備份'}　${_dateTime(file.createdAt)}',
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return null;
    final preview = await backups.preview(selected, choice.id);
    if (!mounted) return null;
    final data = preview.snapshot.data;
    final members = data.groups.fold(0, (n, g) => n + g.members.length);
    final expenses = data.groups.fold(0, (n, g) => n + g.expenses.length);
    final repayments = data.groups.fold(0, (n, g) => n + g.repayments.length);
    final keepGoing = await _confirm(
      '還原預覽',
      '帳本快照　${_dateTime(preview.snapshot.createdAt)}\n\n'
          '群組　${data.groups.length} 個\n群組成員　$members 位\n'
          '消費　$expenses 筆\n還款　$repayments 筆\n'
          '快速聚餐　${data.quickMeals.length} 餐\n常用朋友（含封存）　${data.friends.length} 位',
      '繼續',
    );
    if (!keepGoing || !mounted) return null;
    final confirmed = await _confirm(
      '確認還原到這台裝置？',
      '將「$selected」所選的備份寫入本機空帳本。銀行收款資料需在這台裝置重新設定。',
      '確認還原',
    );
    if (!confirmed || !mounted) return null;
    await backups.restore(preview);
    await controller.initialize();
    return '還原完成，可回到首頁查看帳本。';
  }

  Future<bool> _confirm(String title, String summary, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          scrollable: true,
          content: Text(summary),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    final enabled = activity == null;
    final selected = account;
    return PopScope(
      canPop: enabled,
      child: Scaffold(
        appBar: AppBar(title: const Text('備份與還原')),
        body: PageBody(
          children: [
            const SectionTitle('Google Drive 手動備份'),
            const Text('帳本平時儲存在這台裝置。登入後，只有點選「立即備份」並確認才會上傳。'),
            if (!drive.isSupported)
              const Card(
                child: ListTile(
                  leading: Icon(Icons.phone_android),
                  title: Text('目前僅支援 Android'),
                  subtitle: Text('這台裝置仍可照常使用離線帳本。'),
                ),
              )
            else ...[
              const SizedBox(height: 16),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.account_circle_outlined),
                  title: Text(selected ?? '尚未連結 Google 帳戶'),
                  subtitle: selected == null
                      ? null
                      : Text(
                          latest != null
                              ? '上次成功備份　${_dateTime(latest!)}'
                              : queried
                              ? '這個帳戶尚無備份'
                              : '上次成功備份時間尚未取得',
                        ),
                ),
              ),
              if (selected == null)
                FilledButton.icon(
                  onPressed: enabled ? () => _run('連結中…', _connect) : null,
                  icon: const Icon(Icons.link),
                  label: const Text('連結 Google 帳戶'),
                )
              else ...[
                FilledButton.icon(
                  onPressed: enabled ? () => _run('備份中…', _backup) : null,
                  icon: const Icon(Icons.cloud_upload_outlined),
                  label: const Text('立即備份'),
                ),
                OutlinedButton.icon(
                  onPressed: enabled ? () => _run('準備還原…', _restore) : null,
                  icon: const Icon(Icons.cloud_download_outlined),
                  label: const Text('從備份還原'),
                ),
                const Text('保留最近兩次成功備份。只有空帳本可以還原；有群組、聚餐或常用朋友時會保留本機資料。'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: enabled
                          ? () => _run('切換帳戶中…', _connect)
                          : null,
                      child: const Text('切換 Google 帳戶'),
                    ),
                    TextButton(
                      onPressed: enabled
                          ? () => _run('解除連結中…', _disconnect)
                          : null,
                      child: const Text('解除連結'),
                    ),
                  ],
                ),
              ],
              if (activity != null) ...[
                const LinearProgressIndicator(),
                Text(activity!),
              ],
              if (message != null)
                Semantics(
                  liveRegion: true,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(message!),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
