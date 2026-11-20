import 'package:material_ui/material_ui.dart';

import 'data/repository.dart';
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
    child: MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'TW'),
      supportedLocales: const [Locale('zh', 'TW')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: inkGreen)
            .copyWith(primary: inkGreen, surface: Colors.white),
        scaffoldBackgroundColor: const Color(0xFFF6F8F7),
        appBarTheme: const AppBarThemeData(
          backgroundColor: Color(0xFFF6F8F7),
          foregroundColor: Color(0xFF183C31),
          centerTitle: false,
          scrolledUnderElevation: 0,
        ),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 0,
          margin: const EdgeInsets.symmetric(vertical: 4),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: Color(0xFFDDE7E1)),
          ),
        ),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Colors.white,
          indicatorColor: paleGreen,
        ),
        inputDecorationTheme: const InputDecorationThemeData(
          border: OutlineInputBorder(),
          filled: true,
          fillColor: Colors.white,
        ),
      ),
      builder: (context, navigator) {
        final c = AppScope.of(context);
        if (c.error != null || !c.ready) {
          return Scaffold(
            body: SafeArea(
              child: Center(
                child: c.error == null
                    ? const CircularProgressIndicator(semanticsLabel: '正在讀取帳本')
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
    ),
  );
}
