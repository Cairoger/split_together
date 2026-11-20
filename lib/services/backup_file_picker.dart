import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/ledger_backup.dart';

abstract interface class BackupFilePicker {
  bool get isSupported;
  Future<bool> save(String filename, Uint8List bytes);
  Future<Uint8List?> open();
}

class AndroidBackupFilePicker implements BackupFilePicker {
  const AndroidBackupFilePicker();

  static const _channel = MethodChannel('split_together/backup_file_picker');
  static const _tooLarge = FormatException('備份檔超過 32 MiB，請選擇較小的備份檔。');

  @override
  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<T?> _invoke<T>(String method, [Object? args]) async {
    if (!isSupported) throw const FormatException('目前僅 Android 支援系統備份檔案選擇器。');
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      throw const FormatException('無法開啟系統檔案選擇器，請確認 App 版本。');
    } on PlatformException catch (error) {
      throw switch (error.code) {
        'too-large' => _tooLarge,
        'busy' => const FormatException('請先完成目前的選檔操作。'),
        'interrupted' => const FormatException('檔案操作已中斷，請再試一次。'),
        'no-picker' => const FormatException('無法開啟 Android 系統檔案選擇器。'),
        _ => FormatException(
          method == 'save' ? '無法寫入備份檔，請檢查儲存空間或選擇其他位置。' : '無法讀取所選檔案，請確認檔案可用後再試。',
        ),
      };
    }
  }

  @override
  Future<bool> save(String filename, Uint8List bytes) async {
    if (bytes.length > LedgerBackup.maxBytes) throw _tooLarge;
    return await _invoke<bool>('save', {
          'filename': filename,
          'bytes': bytes,
        }) ??
        false;
  }

  @override
  Future<Uint8List?> open() async {
    final bytes = await _invoke<Uint8List>('open');
    if (bytes != null && bytes.length > LedgerBackup.maxBytes) throw _tooLarge;
    return bytes;
  }
}
