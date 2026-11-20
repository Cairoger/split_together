import 'package:material_ui/material_ui.dart';

import '../data/ledger_backup.dart';
import '../services/backup_file_picker.dart';
import '../services/ledger_backup_service.dart';
import '../state.dart';
import '../ui.dart';

class BackupScreen extends StatefulWidget {
  const BackupScreen({
    super.key,
    this.picker = const AndroidBackupFilePicker(),
  });
  final BackupFilePicker picker;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  String? activity, message;
  LedgerBackupService get service =>
      LedgerBackupService(AppScope.of(context).repo, widget.picker);

  Future<void> _run(String label, Future<String> Function() action) async {
    if (activity != null) return;
    setState(() {
      activity = label;
      message = null;
    });
    try {
      message = await action();
    } on FormatException catch (error) {
      message = error.message;
    } catch (_) {
      message = '操作未完成，請確認檔案位置及裝置儲存空間後再試。';
    } finally {
      if (mounted) setState(() => activity = null);
    }
  }

  Future<String> _export() async =>
      await service.exportFile() ? '已匯出備份檔。' : '已取消匯出。';

  Future<String> _restore() async {
    final controller = AppScope.of(context);
    final preview = await service.pickForRestore();
    if (preview == null || !mounted) return '已取消還原。';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('還原預覽'),
        scrollable: true,
        content: Text(_summary(preview)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('確認還原'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return '已取消還原。';
    // Repository 會在同一筆交易內再次檢查本機帳本是否為空。
    await controller.change((repo) => repo.restoreBackup(preview));
    return '還原完成，可回到首頁查看帳本。';
  }

  String _summary(LedgerBackup snapshot) {
    final local = snapshot.createdAt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final time =
        '${shortDate(local)} ${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
    final data = snapshot.data;
    final members = data.groups.fold(0, (n, g) => n + g.members.length);
    final expenses = data.groups.fold(0, (n, g) => n + g.expenses.length);
    final repayments = data.groups.fold(0, (n, g) => n + g.repayments.length);
    return '備份時間　$time\n\n'
        '群組　${data.groups.length} 個\n群組成員　$members 位\n'
        '消費　$expenses 筆\n還款　$repayments 筆\n'
        '快速聚餐　${data.quickMeals.length} 餐\n常用朋友（含封存）　${data.friends.length} 位\n\n'
        '確認後，這些資料會寫入本機空帳本。';
  }

  @override
  Widget build(BuildContext context) {
    final enabled = activity == null;
    return PopScope(
      canPop: enabled,
      child: Scaffold(
        appBar: AppBar(title: const Text('備份與還原')),
        body: PageBody(
          children: [
            if (!widget.picker.isSupported)
              const Card(
                child: ListTile(
                  leading: Icon(Icons.phone_android),
                  title: Text('檔案備份目前僅支援 Android'),
                ),
              )
            else ...[
              const SectionTitle('手動檔案備份'),
              const Text('備份檔是未加密的 JSON，內含姓名、金額及備註，請妥善保存。銀行收款欄位與裝置設定不會匯出。'),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: enabled ? () => _run('匯出中…', _export) : null,
                icon: const Icon(Icons.file_download_outlined),
                label: const Text('匯出備份檔'),
              ),
              const SizedBox(height: 12),
              const Text('一般版與 Preview 可互相還原相容的備份檔。請在空帳本選檔，再核對備份日期及筆數。'),
              OutlinedButton.icon(
                onPressed: enabled ? () => _run('準備還原…', _restore) : null,
                icon: const Icon(Icons.restore_outlined),
                label: const Text('從備份檔還原'),
              ),
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
