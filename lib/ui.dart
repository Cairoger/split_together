import 'package:material_ui/material_ui.dart';

import 'domain.dart';

const appName = 'SplitTogether';
const groupCategories = ['旅遊', '聚餐', '生活', '其他'];

Color balanceColor(ColorScheme colors, int amount) => switch (amount.sign) {
  1 => colors.primary,
  -1 => colors.error,
  _ => colors.onSurfaceVariant,
};

String balanceLabel(int value) => switch (value.compareTo(0)) {
  1 => '應收 +${Money.format(value)}',
  -1 => '應付 −${Money.format(-value)}',
  _ => '已結清 ${Money.format(0)}',
};

String shortDate(DateTime date) {
  final local = date.toLocal();
  return '${local.year}/${local.month.toString().padLeft(2, '0')}/${local.day.toString().padLeft(2, '0')}';
}

String errorMessage(Object e) {
  if (e is FormatException) return e.message;
  if (e is StateError) return e.message;
  if (e is ArgumentError) return e.message.toString();
  return '操作失敗，請確認裝置儲存空間後再試。（${e.runtimeType}）';
}

Future<bool> confirmAction(
  BuildContext context,
  String title,
  String message,
  String action,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
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

Future<T?> openPage<T>(BuildContext context, Widget page) =>
    Navigator.of(context).push<T>(MaterialPageRoute<T>(builder: (_) => page));

IconData categoryIcon(String category) => switch (category) {
  '旅遊' => Icons.luggage_outlined,
  '聚餐' => Icons.restaurant_outlined,
  '生活' => Icons.cottage_outlined,
  _ => Icons.folder_outlined,
};

class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: children,
        ),
      ),
    ),
  );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 22, bottom: 10),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleMedium
          ?.copyWith(fontWeight: FontWeight.bold),
    ),
  );
}

class EmptyCard extends StatelessWidget {
  const EmptyCard(
    this.icon,
    this.title,
    this.message, {
    super.key,
    this.action,
  });
  final IconData icon;
  final String title, message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          CircleAvatar(
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
            child: Icon(icon),
          ),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          if (action != null)
            Padding(padding: const EdgeInsets.only(top: 12), child: action),
        ],
      ),
    ),
  );
}
