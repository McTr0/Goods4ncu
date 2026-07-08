import 'package:flutter/material.dart';

class AppTheme {
  // Primary palette: campus pine with warm market accents.
  static const Color primary = Color(0xFF0F766E);
  static const Color primaryLight = Color(0xFF2DD4BF);
  static const Color primaryDark = Color(0xFF134E4A);
  static const Color accent = Color(0xFFF97316);
  static const Color accentSoft = Color(0xFFFFEDD5);
  static const Color sand = Color(0xFFFFF7ED);
  static const Color mint = Color(0xFFE6FFFB);

  // Neutral slate scale
  static const Color surface = Color(0xFFFFFBF5);
  static const Color surfaceDark = Color(0xFF0B1413);
  static const Color cardLight = Color(0xFFFFFFFF);
  static const Color cardDark = Color(0xFF13201F);
  static const Color borderLight = Color(0xFFEADFD1);
  static const Color borderDark = Color(0xFF334155);

  // Semantic
  static const Color success = Color(0xFF059669);
  static const Color error = Color(0xFFEF4444);
  static const Color warning = Color(0xFFF59E0B);
  static const Color info = Color(0xFF0284C7);
  static const Color shipped = Color(0xFF6366F1);

  // Text
  static const Color textPrimary = Color(0xFF1C1917);
  static const Color textSecondary = Color(0xFF78716C);
  static const Color textPrimaryDark = Color(0xFFF8FAFC);
  static const Color textSecondaryDark = Color(0xFFA8A29E);

  // Spacing tokens
  static const double sp2 = 2;
  static const double sp4 = 4;
  static const double sp6 = 6;
  static const double sp8 = 8;
  static const double sp12 = 12;
  static const double sp14 = 14;
  static const double sp16 = 16;
  static const double sp20 = 20;
  static const double sp24 = 24;
  static const double sp32 = 32;

  // Radius tokens
  static const double radiusSm = 8;
  static const double radiusMd = 12;
  static const double radiusLg = 16;
  static const double radiusXl = 24;
  static const double radius2xl = 32;

  static const List<BoxShadow> cardShadow = [
    BoxShadow(color: Color(0x120F172A), blurRadius: 28, offset: Offset(0, 14)),
  ];

  static const List<BoxShadow> softShadow = [
    BoxShadow(color: Color(0x0F0F766E), blurRadius: 24, offset: Offset(0, 10)),
  ];

  // Condition badge helpers
  /// Returns the appropriate color for a condition score (1-10).
  static Color conditionColor(int score) {
    if (score >= 9) return success;
    if (score >= 7) return info;
    if (score >= 5) return warning;
    return error;
  }

  /// Returns the Chinese label for a condition score.
  static String conditionLabel(int score) {
    if (score >= 9) return '几乎全新';
    if (score >= 7) return '较好';
    if (score >= 5) return '一般';
    return '较差';
  }

  static ThemeData get light => ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: primary,
      brightness: Brightness.light,
      surface: surface,
      primary: primary,
      secondary: accent,
      tertiary: info,
      error: error,
    ),
    scaffoldBackgroundColor: surface,
    dividerColor: borderLight,
    fontFamily: 'Roboto',
    fontFamilyFallback: const [
      'PingFang SC',
      'Hiragino Sans GB',
      'Noto Sans CJK SC',
      'Heiti SC',
      'Microsoft YaHei',
      'Arial',
    ],
    visualDensity: VisualDensity.standard,
    appBarTheme: const AppBarTheme(
      backgroundColor: surface,
      foregroundColor: textPrimary,
      centerTitle: true,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(
        color: textPrimary,
        fontSize: 18,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.2,
      ),
    ),
    cardTheme: CardThemeData(
      color: cardLight,
      elevation: 0,
      shadowColor: const Color(0x120F172A),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusLg),
        side: const BorderSide(color: borderLight, width: 1),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: cardLight,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusMd),
        borderSide: const BorderSide(color: borderLight),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusMd),
        borderSide: const BorderSide(color: borderLight),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusMd),
        borderSide: const BorderSide(color: primary, width: 2),
      ),
      labelStyle: const TextStyle(color: textSecondary),
      floatingLabelStyle: const TextStyle(
        color: primary,
        fontWeight: FontWeight.w700,
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: sp16,
        vertical: sp16,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        elevation: 2,
        shadowColor: primary.withValues(alpha: 0.28),
        padding: const EdgeInsets.symmetric(horizontal: sp24, vertical: sp16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLg),
        ),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: primary,
        padding: const EdgeInsets.symmetric(horizontal: sp24, vertical: sp16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLg),
        ),
        side: const BorderSide(color: primary),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: primary),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: sand,
      selectedColor: mint,
      labelStyle: const TextStyle(fontSize: 13),
      padding: const EdgeInsets.symmetric(horizontal: sp8, vertical: sp4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusLg),
        side: const BorderSide(color: borderLight),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: textPrimary,
      contentTextStyle: const TextStyle(color: Colors.white),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusLg),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 74,
      backgroundColor: cardLight.withValues(alpha: 0.96),
      elevation: 0,
      indicatorColor: accentSoft,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: selected ? primaryDark : textSecondary,
          size: selected ? 27 : 24,
        );
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          color: selected ? primaryDark : textSecondary,
          fontSize: 12,
          fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
        );
      }),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: cardLight,
      selectedItemColor: primary,
      unselectedItemColor: textSecondary,
      type: BottomNavigationBarType.fixed,
      elevation: 8,
    ),
  );

  static ThemeData get dark => ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: primary,
      brightness: Brightness.dark,
      surface: surfaceDark,
      primary: primaryLight,
      secondary: accent,
      tertiary: info,
      error: error,
    ),
    scaffoldBackgroundColor: surfaceDark,
    dividerColor: borderDark,
    fontFamily: 'Roboto',
    fontFamilyFallback: const [
      'PingFang SC',
      'Hiragino Sans GB',
      'Noto Sans CJK SC',
      'Heiti SC',
      'Microsoft YaHei',
      'Arial',
    ],
    appBarTheme: const AppBarTheme(
      backgroundColor: surfaceDark,
      foregroundColor: textPrimaryDark,
      centerTitle: true,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(
        color: textPrimaryDark,
        fontSize: 18,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.2,
      ),
    ),
    cardTheme: CardThemeData(
      color: cardDark,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusLg),
        side: const BorderSide(color: borderDark, width: 1),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: cardDark,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusMd),
        borderSide: const BorderSide(color: borderDark),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusMd),
        borderSide: const BorderSide(color: borderDark),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusMd),
        borderSide: const BorderSide(color: primary, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: sp16,
        vertical: sp12,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        elevation: 2,
        shadowColor: primary.withValues(alpha: 0.32),
        padding: const EdgeInsets.symmetric(horizontal: sp24, vertical: sp16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLg),
        ),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: primaryLight,
        padding: const EdgeInsets.symmetric(horizontal: sp24, vertical: sp16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLg),
        ),
        side: const BorderSide(color: primaryLight),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 74,
      backgroundColor: cardDark.withValues(alpha: 0.96),
      elevation: 0,
      indicatorColor: primary.withValues(alpha: 0.24),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: selected ? primaryLight : textSecondaryDark,
          size: selected ? 27 : 24,
        );
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          color: selected ? primaryLight : textSecondaryDark,
          fontSize: 12,
          fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
        );
      }),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: cardDark,
      selectedItemColor: primaryLight,
      unselectedItemColor: textSecondaryDark,
      type: BottomNavigationBarType.fixed,
      elevation: 8,
    ),
  );
}
