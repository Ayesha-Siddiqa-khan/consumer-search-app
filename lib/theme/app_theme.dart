import 'package:flutter/material.dart';

class AppTheme {
  // Brand Colors - Government of Punjab eLGCDD Palette
  static const Color primaryGreen = Color(0xFF1B5E20);
  static const Color darkGreen = Color(0xFF0F3E13);
  static const Color lightGreen = Color(0xFF2E7D32);
  static const Color accentEmerald = Color(0xFF00897B);
  static const Color goldAccent = Color(0xFFC5A059);

  // Surface & Neutral Colors
  static const Color bgLight = Color(0xFFF4F6F8);
  static const Color surfaceLight = Colors.white;
  static const Color borderLight = Color(0xFFCFD8DC);
  static const Color tableHeaderGreen = Color(0xFF2E7D32);
  static const Color tableText = Color(0xFF1E293B);

  // Table Row Colors (Government Portal)
  static const Color tableRowEven = Color(0xFFFFFFFF);
  static const Color tableRowOdd = Color(0xFFF8F9FA);
  static const Color tableRowHover = Color(0xFFF1F5F9);
  static const Color tableRowPaid = Color(0xFFE8F5E9); // Light green for paid bill rows
  static const Color tableRowPaidHover = Color(0xFFDCEDC8); // Slightly darker tint on hover
  static const Color tableBorder = Color(0xFFE5E7EB);
  static const Color tableHeaderText = Color(0xFFFFFFFF);

  // Column Accent Colors
  static const Color billAmountTeal = Color(0xFF0F766E);
  static const Color afterDueOrange = Color(0xFFC2410C);
  static const Color connNoBlue = Color(0xFF2563EB);

  // Status Colors (Clean Text-Only)
  static const Color statusActive = Color(0xFF15803D);
  static const Color statusInactive = Color(0xFFB91C1C);
  static const Color statusNewDemand = Color(0xFF334155);

  // Legacy Status Badges (kept for compatibility)
  static const Color statusActiveBg = Color(0xFFE8F5E9);
  static const Color statusActiveText = statusActive;

  static const Color statusInactiveBg = Color(0xFFFFEBEE);
  static const Color statusInactiveText = statusInactive;

  static const Color statusSuspendedBg = Color(0xFFFFF3E0);
  static const Color statusSuspendedText = Color(0xFFE65100);

  static const Color statusNewDemandBg = Color(0xFFE3F2FD);
  static const Color statusNewDemandText = statusNewDemand;

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primaryGreen,
        primary: primaryGreen,
        secondary: accentEmerald,
        surface: surfaceLight,
      ),
      scaffoldBackgroundColor: bgLight,
      fontFamily: 'Segoe UI',
      appBarTheme: const AppBarTheme(
        backgroundColor: primaryGreen,
        foregroundColor: Colors.white,
        elevation: 1,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.3,
        ),
      ),
      cardTheme: CardThemeData(
        color: surfaceLight,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: Color(0xFFE0E0E0), width: 1),
        ),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: Color(0xFFBDBDBD)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: Color(0xFFCCCCCC)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: primaryGreen, width: 1.5),
        ),
        labelStyle: const TextStyle(fontSize: 13, color: Color(0xFF555555)),
        hintStyle: const TextStyle(fontSize: 13, color: Color(0xFF9E9E9E)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryGreen,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
          ),
          textStyle: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primaryGreen,
          side: const BorderSide(color: primaryGreen),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
          ),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
