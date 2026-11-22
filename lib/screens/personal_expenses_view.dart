import 'package:material_ui/material_ui.dart';

import '../domain.dart';
import '../state.dart';
import '../ui.dart';
import 'quick_meal_result_screen.dart';

class PersonalExpensesView extends StatelessWidget {
  const PersonalExpensesView({super.key});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final expenses = AppScope.of(context).data.personalExpenses(now);
    final theme = Theme.of(context);
    return PageBody(
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '本月總額 · ${now.year} 年 ${now.month} 月',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  Money.format(expenses.monthTotal),
                  style: theme.textTheme.headlineMedium,
                ),
              ],
            ),
          ),
        ),
        const SectionTitle('全部支出明細'),
        if (expenses.meals.isEmpty)
          const EmptyCard(
            Icons.receipt_long_outlined,
            '還沒有支出紀錄',
            '在聚餐結果點『記入我的支出』，就會出現在這裡',
          ),
        for (final meal in expenses.meals)
          Card(
            child: ListTile(
              key: ValueKey('personal-expense-${meal.id}'),
              title: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  const Text('快速聚餐'),
                  Text(
                    Money.format(meal.selfShare),
                    style: theme.textTheme.titleMedium,
                  ),
                ],
              ),
              subtitle: Text('${shortDate(meal.createdAt)} · 餐飲'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () =>
                  openPage<void>(context, QuickMealResultScreen(meal: meal)),
            ),
          ),
      ],
    );
  }
}
