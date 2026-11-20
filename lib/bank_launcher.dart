import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'domain.dart';

abstract final class BankLauncher {
  static const _channel = MethodChannel('split_together/bank_launcher');

  static bool supportsDirectOpen(BankAppChoice choice) {
    if (kIsWeb) return false;
    final id = choice.id;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => !id.startsWith('ios-shortcut:'),
      TargetPlatform.iOS =>
        id == 'com.chinatrust.mobilebank' ||
            id == 'tw.com.taishinbank.mobile' ||
            id.startsWith('ios-shortcut:'),
      _ => false,
    };
  }

  static bool get canListAndroidApps =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<List<BankAppChoice>> listAndroidApps() async {
    if (!canListAndroidApps) return const [];
    final entries = await _channel.invokeListMethod<Object?>('listApps');
    final choices = <String, BankAppChoice>{};
    for (final entry in entries ?? const []) {
      if (entry is! Map) continue;
      final id = entry['id'];
      final label = entry['label'];
      if (id is! String || id.isEmpty || label is! String || label.isEmpty) {
        continue;
      }
      choices.putIfAbsent(id, () => BankAppChoice(id: id, label: label));
    }
    return choices.values.toList(growable: false);
  }

  static Future<Uint8List?> androidAppIcon(String id) async {
    if (!canListAndroidApps) return null;
    return _channel.invokeMethod<Uint8List>('appIcon', id);
  }

  static Future<bool> isAndroidAppAvailable(String id) async {
    if (!canListAndroidApps) return false;
    return await _channel.invokeMethod<bool>('isAppAvailable', id) ?? false;
  }

  static Future<bool> open(BankAppChoice choice) async {
    if (!supportsDirectOpen(choice)) return false;
    return await _channel.invokeMethod<bool>('openApp', choice.id) ?? false;
  }

  static Future<bool> openOfficialPage(BankAppChoice choice) async {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      return false;
    }
    return await _channel.invokeMethod<bool>('openOfficialPage', choice.id) ??
        false;
  }

  static Future<void> copyAccount(String number) async {
    await _channel.invokeMethod<void>('copyAccount', number);
  }
}
