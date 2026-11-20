import '../data/ledger_backup.dart';
import '../data/repository.dart';
import 'drive_backup_gateway.dart';

class RestorePreview {
  RestorePreview._(this.account, this.snapshot);
  final String account;
  final LedgerBackup snapshot;
}

class BackupReceipt {
  const BackupReceipt(this.latest, {required this.cleanupPending});
  final DateTime latest;
  final bool cleanupPending;
}

class LedgerBackupService {
  const LedgerBackupService(this.repo, this.drive);
  final SplitRepository repo;
  final DriveBackupGateway drive;

  Future<List<DriveBackupFile>> versions(String account) async {
    // 分頁期間其他裝置也可能備份。同一個檔案只能算作一個版本。
    final byId = <String, DriveBackupFile>{
      for (final file in await drive.list(account)) file.id: file,
    };
    final files = byId.values.toList();
    files.sort((a, b) {
      final byTime = b.createdAt.compareTo(a.createdAt);
      return byTime != 0 ? byTime : b.id.compareTo(a.id);
    });
    return files;
  }

  Future<BackupReceipt> backUp(String account) async {
    final snapshot = await repo.createBackup(DateTime.now().toUtc());
    final uploaded = await drive.upload(account, await snapshot.encode());
    var latest = uploaded.createdAt;
    // Drive 已回覆上傳成功。之後清理失敗仍須保留這次成功時間。
    try {
      await drive.rememberLatest(account, latest);
      final files = await versions(account);
      if (!files.any((f) => f.id == uploaded.id)) {
        return BackupReceipt(latest, cleanupPending: true);
      }
      latest = files.first.createdAt;
      await drive.rememberLatest(account, latest);
      for (final old in files.skip(2)) {
        await drive.delete(account, old.id);
      }
      return BackupReceipt(latest, cleanupPending: false);
    } catch (_) {
      return BackupReceipt(latest, cleanupPending: true);
    }
  }

  Future<void> requireEmpty() async {
    if (!await repo.isLedgerEmpty()) {
      throw const FormatException(nonEmptyLedgerMessage);
    }
  }

  Future<RestorePreview> preview(String account, String fileId) async {
    await requireEmpty();
    final bytes = await drive.download(account, fileId);
    return RestorePreview._(account, await LedgerBackup.decode(bytes));
  }

  Future<void> restore(RestorePreview preview) async {
    if (await drive.currentAccount() != preview.account) {
      throw const FormatException('Google 帳戶已變更，請重新選擇備份。');
    }
    // Repository 會在同一筆寫入交易內再確認帳本為空。
    await repo.restoreBackup(preview.snapshot);
  }
}
