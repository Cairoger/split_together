import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:split_together/app.dart';
import 'package:split_together/data/memory_repository.dart';
import 'package:split_together/domain.dart';

Future<void> openApp(WidgetTester tester, MemorySplitRepository repo) async {
  await tester.pumpWidget(SplitTogetherApp(repository: repo));
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, String label) async {
  final target = find.text(label);
  if (target.evaluate().isEmpty) {
    final scrollable = find
        .descendant(
          of: find.byType(ListView).first,
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(target, 180, scrollable: scrollable);
  }
  if (target.hitTestable().evaluate().isEmpty) {
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }
  await tester.tap(target);
  await tester.pumpAndSettle();
}

ThemeData themeAt(WidgetTester tester, Finder target) =>
    Theme.of(tester.element(target));

void main() {
  testWidgets('外觀即時套用到首頁、表單與對話框，重開後仍可切回光亮模式', (tester) async {
    final repo = MemorySplitRepository();
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await openApp(tester, repo);

    final summary = find.text('我的淨餘額');
    expect(themeAt(tester, summary).brightness, Brightness.light);
    expect(
      themeAt(tester, summary).scaffoldBackgroundColor,
      const Color(0xFFF6F8F7),
    );

    await tap(tester, '設定');
    await tap(tester, '黑暗模式');
    final settings = find.text('外觀');
    expect(settings, findsOneWidget);
    expect(themeAt(tester, settings).brightness, Brightness.dark);
    expect((await repo.load()).appearance, AppAppearance.dark);

    await tap(tester, '我的預設名稱');
    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    expect(themeAt(tester, dialog).brightness, Brightness.dark);
    await tap(tester, '取消');
    await tap(tester, '首頁');
    final dark = themeAt(tester, summary);
    expect(dark.scaffoldBackgroundColor, const Color(0xFF101A17));
    expect(dark.colorScheme.surface, const Color(0xFF192823));
    expect(dark.colorScheme.primary, const Color(0xFF71DFB9));
    expect(dark.colorScheme.error, const Color(0xFFFFAAA2));

    await tap(tester, '建立群組');
    await tap(tester, '儲存群組');
    final error = find.text('請輸入群組名稱');
    expect(themeAt(tester, error).brightness, Brightness.dark);
    expect(tester.widget<Text>(error).style?.color, dark.colorScheme.error);

    // Recreate the whole widget tree so a local settings switch cannot
    // accidentally satisfy the launch assertion.
    await tester.pumpWidget(const SizedBox.shrink());
    await openApp(tester, repo);
    expect(themeAt(tester, summary).brightness, Brightness.dark);
    await tap(tester, '設定');
    await tap(tester, '光亮模式');
    expect(themeAt(tester, settings).brightness, Brightness.light);
    expect((await repo.load()).appearance, AppAppearance.light);
  });

  testWidgets('重複點擊只送出一次外觀設定，寫入失敗可留在原模式重試', (tester) async {
    final repo = _DelayedAppearanceRepository();
    await openApp(tester, repo);
    await tap(tester, '設定');
    final dark = find.text('黑暗模式');
    if (dark.hitTestable().evaluate().isEmpty) {
      await tester.ensureVisible(dark);
      await tester.pumpAndSettle();
    }
    await tester.tap(dark);
    await tester.pump();
    await tester.tap(dark);
    await tester.pump();
    expect(repo.calls, 1);

    repo.firstSave.completeError(const FormatException('外觀設定儲存失敗'));
    await tester.pumpAndSettle();
    expect(find.textContaining('外觀設定儲存失敗'), findsOneWidget);
    expect(themeAt(tester, find.text('外觀')).brightness, Brightness.light);
    expect((await repo.load()).appearance, AppAppearance.light);
    await tap(tester, '黑暗模式');
    expect(repo.calls, 2);
    expect(themeAt(tester, find.text('外觀')).brightness, Brightness.dark);
  });
}

class _DelayedAppearanceRepository extends MemorySplitRepository {
  final firstSave = Completer<void>();
  int calls = 0;

  @override
  Future<void> setAppearance(AppAppearance value) async {
    calls++;
    if (calls == 1) await firstSave.future;
    await super.setAppearance(value);
  }
}
