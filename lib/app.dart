import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';
import 'data/repository.dart';
import 'domain.dart';
import 'screens/home_screen.dart';
import 'state.dart';
import 'ui.dart';

class SplitTogetherApp extends StatefulWidget {
  const SplitTogetherApp({super.key, required this.repository});
  final SplitRepository repository;

  @override
  State<SplitTogetherApp> createState() => _SplitTogetherAppState();
}

class _SplitTogetherAppState extends State<SplitTogetherApp> {
  late final controller = AppController(widget.repository)..initialize();

  @override
  void dispose() {
    controller.dispose();
    widget.repository.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppScope(
    controller: controller,
    child: Builder(
      builder: (context) {
        final c = AppScope.of(context);
        return MaterialApp(
          title: appName,
          debugShowCheckedModeBanner: false,
          locale: const Locale('zh', 'TW'),
          supportedLocales: const [Locale('zh', 'TW')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: lightTheme,
          darkTheme: darkTheme,
          themeMode: c.ready && c.data.appearance == AppAppearance.dark
              ? ThemeMode.dark
              : ThemeMode.light,
          builder: (context, navigator) {
            if (c.error != null || !c.ready) {
              return Scaffold(
                body: SafeArea(
                  child: Center(
                    child: c.error == null
                        ? const CircularProgressIndicator(
                            semanticsLabel: '正在讀取帳本',
                          )
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('無法讀取本機帳本'),
                              Text(errorMessage(c.error!)),
                              FilledButton(
                                onPressed: c.initialize,
                                child: const Text('重新讀取'),
                              ),
                            ],
                          ),
                  ),
                ),
              );
            }
            return navigator!;
          },
          home: const HomeScreen(),
        );
      },
    ),
  );
}
