import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

final lightTheme = _buildTheme(Brightness.light);
final darkTheme = _buildTheme(Brightness.dark);

ThemeData _buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final background = dark ? const Color(0xFF101A17) : const Color(0xFFF6F8F7);
  final primary = dark ? const Color(0xFF71DFB9) : const Color(0xFF145C48);
  final colors = ColorScheme.fromSeed(
    seedColor: primary,
    brightness: brightness,
    primary: primary,
    onPrimary: dark ? const Color(0xFF10392C) : Colors.white,
    surface: dark ? const Color(0xFF192823) : Colors.white,
    onSurface: dark ? const Color(0xFFE6F2EC) : const Color(0xFF183C31),
    onSurfaceVariant: dark ? const Color(0xFFB4C9BE) : const Color(0xFF52675F),
    error: dark ? const Color(0xFFFFAAA2) : const Color(0xFFA13632),
    onError: dark ? const Color(0xFF5A1917) : Colors.white,
    outlineVariant: dark ? const Color(0xFF364A41) : const Color(0xFFDDE7E1),
    primaryContainer: dark ? const Color(0xFF244B3D) : const Color(0xFFE2F1E9),
    onPrimaryContainer: dark
        ? const Color(0xFFABEFD1)
        : const Color(0xFF145C48),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: colors,
    scaffoldBackgroundColor: background,
    appBarTheme: AppBarThemeData(
      backgroundColor: background,
      foregroundColor: colors.onSurface,
      centerTitle: false,
      scrolledUnderElevation: 0,
      systemOverlayStyle:
          (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
              .copyWith(
                statusBarColor: Colors.transparent,
                systemNavigationBarColor: colors.surface,
                systemNavigationBarIconBrightness: dark
                    ? Brightness.light
                    : Brightness.dark,
              ),
    ),
    cardTheme: CardThemeData(
      color: colors.surface,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: colors.outlineVariant),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: colors.surface,
      indicatorColor: colors.primaryContainer,
    ),
    inputDecorationTheme: InputDecorationThemeData(
      border: const OutlineInputBorder(),
      filled: true,
      fillColor: colors.surface,
    ),
  );
}
