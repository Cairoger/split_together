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

  static Future<BankAppChoice?> pickAndroidApp() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    final selected = await _channel.invokeMapMethod<String, String>('pickApp');
    final id = selected?['id'];
    final label = selected?['label'];
    if (id == null || label == null) return null;
    return BankAppChoice(id: id, label: label);
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
