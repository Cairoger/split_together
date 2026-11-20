import 'package:flutter/services.dart';

const _shareChannel = MethodChannel('split_together/meal_share');

Future<void> shareMealText(String text) =>
    _shareChannel.invokeMethod<void>('shareText', text);
