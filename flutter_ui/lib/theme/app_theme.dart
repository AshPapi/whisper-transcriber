import 'package:flutter/material.dart';

class AppTheme {
  static const _seedColor = Color(0xFF005FB2);

  static ThemeData light() => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seedColor,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF9F9F9),
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xFFDFE3E4)),
          ),
          color: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          elevation: 0,
          scrolledUnderElevation: 1,
          backgroundColor: Color(0xFFF9F9F9),
          foregroundColor: Color(0xFF2F3334),
          titleTextStyle: TextStyle(
            color: Color(0xFF2F3334),
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        navigationRailTheme: NavigationRailThemeData(
          backgroundColor: const Color(0xFFECEEEE),
          selectedIconTheme: const IconThemeData(color: Color(0xFF005FB2)),
          selectedLabelTextStyle: const TextStyle(
            color: Color(0xFF005FB2),
            fontWeight: FontWeight.w600,
          ),
          unselectedIconTheme: const IconThemeData(color: Color(0xFF5B6061)),
          unselectedLabelTextStyle: const TextStyle(color: Color(0xFF5B6061)),
          indicatorColor: const Color(0xFFD0E4F5),
          useIndicator: true,
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFFAFB3B3)),
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF005FB2),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8)),
          ),
        ),
      );

  static ThemeData dark() => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seedColor,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF1A1D1E),
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xFF2E3235)),
          ),
          color: const Color(0xFF22272A),
        ),
        appBarTheme: const AppBarTheme(
          elevation: 0,
          scrolledUnderElevation: 1,
          backgroundColor: Color(0xFF1A1D1E),
          foregroundColor: Color(0xFFE0E3E4),
          titleTextStyle: TextStyle(
            color: Color(0xFFE0E3E4),
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        navigationRailTheme: NavigationRailThemeData(
          backgroundColor: const Color(0xFF1E2224),
          selectedIconTheme: const IconThemeData(color: Color(0xFF7AB8F5)),
          selectedLabelTextStyle: const TextStyle(
            color: Color(0xFF7AB8F5),
            fontWeight: FontWeight.w600,
          ),
          unselectedIconTheme: const IconThemeData(color: Color(0xFF8C9295)),
          unselectedLabelTextStyle: const TextStyle(color: Color(0xFF8C9295)),
          indicatorColor: const Color(0xFF1A3A5C),
          useIndicator: true,
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF3A3F42)),
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF4D9FD6),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8)),
          ),
        ),
      );
}
