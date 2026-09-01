import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/services/app_controller.dart';
import '../features/auth/login_page.dart';
import '../features/shell/main_shell.dart';

class LevantamientosApp extends StatelessWidget {
  const LevantamientosApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'DDR001 Levantamientos',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff2848b8),
        primary: const Color(0xff2848b8),
        surface: Colors.white,
        brightness: Brightness.light,
      ),
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xfff6f8fc),
      appBarTheme: const AppBarTheme(
        elevation: 0,
        backgroundColor: Color(0xff2848b8),
        foregroundColor: Colors.white,
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 1,
        shadowColor: const Color(0x220f172a),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: Color(0xffdce4f0)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 15,
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xffdce4f0)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    ),
    home: Consumer<AppController>(
      builder: (_, state, _) => state.session == null
          ? const LoginPage()
          : MainShell(key: MainShell.shellKey),
    ),
  );
}
