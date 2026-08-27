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
        seedColor: const Color(0xff176b5b),
        brightness: Brightness.light,
      ),
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xfff5f7f6),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    home: Consumer<AppController>(
      builder: (_, state, _) => state.session == null
          ? const LoginPage()
          : MainShell(key: MainShell.shellKey),
    ),
  );
}
