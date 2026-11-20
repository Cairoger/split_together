import '../data/ledger_backup.dart';
import '../data/repository.dart';
import 'backup_file_picker.dart';

class LedgerBackupService {
  const LedgerBackupService(this.repo, this.picker);
  final SplitRepository repo;
  final BackupFilePicker picker;

  Future<bool> exportFile() async {
    final backup = await repo.createBackup(DateTime.now().toUtc());
    final local = backup.createdAt.toLocal();
    final stamp = local.toIso8601String().split('.').first.replaceAll(':', '-');
    return picker.save('SplitTogether_$stamp.json', await backup.encode());
  }

  Future<LedgerBackup?> pickForRestore() async {
    if (!await repo.isLedgerEmpty()) {
      throw const FormatException(nonEmptyLedgerMessage);
    }
    final bytes = await picker.open();
    if (bytes == null) return null;
    return LedgerBackup.decode(bytes);
  }
}
