import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/app_controller.dart';
import '../../shared/widgets/app_brand_logo.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  static const _blue = Color(0xff2848b8);
  static const _silver = Color(0xffcbd1dd);
  final name = TextEditingController();
  final email = TextEditingController();
  final phone = TextEditingController();
  final crew = TextEditingController();
  final password = TextEditingController();
  String? error;

  @override
  void dispose() {
    name.dispose();
    email.dispose();
    phone.dispose();
    crew.dispose();
    password.dispose();
    super.dispose();
  }

  InputDecoration _decoration(String label, IconData icon) => InputDecoration(
    labelText: label,
    labelStyle: const TextStyle(color: _silver),
    floatingLabelStyle: const TextStyle(color: Colors.white),
    prefixIcon: Icon(icon, color: _silver),
    filled: true,
    fillColor: const Color(0xff243f9e),
    counterStyle: const TextStyle(color: _silver),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Color(0xff8e9bc0)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Colors.white, width: 1.5),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final inputStyle = Theme.of(
      context,
    ).textTheme.bodyLarge?.copyWith(color: _silver);
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 54),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Center(
                          child: AppBrandLogo(
                            variant: AppBrandLogoVariant.horizontal,
                            width: 230,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'DDR001 Levantamientos',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(
                                color: _blue,
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Acceso seguro',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: _blue),
                        ),
                        const SizedBox(height: 20),
                        Card(
                          color: _blue,
                          margin: EdgeInsets.zero,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(22),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                TextField(
                                  key: const Key('login_email'),
                                  controller: email,
                                  style: inputStyle,
                                  cursorColor: Colors.white,
                                  keyboardType: TextInputType.emailAddress,
                                  autofillHints: const [AutofillHints.email],
                                  decoration: _decoration(
                                    'Correo',
                                    Icons.email_outlined,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  key: const Key('login_password'),
                                  controller: password,
                                  style: inputStyle,
                                  cursorColor: Colors.white,
                                  obscureText: true,
                                  autofillHints: const [AutofillHints.password],
                                  decoration: _decoration(
                                    'Contraseña',
                                    Icons.lock_outline,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  key: const Key('login_name'),
                                  controller: name,
                                  style: inputStyle,
                                  cursorColor: Colors.white,
                                  textCapitalization: TextCapitalization.words,
                                  autofillHints: const [AutofillHints.name],
                                  decoration: _decoration(
                                    'Nombre completo',
                                    Icons.person_outline,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  key: const Key('login_phone'),
                                  controller: phone,
                                  style: inputStyle,
                                  cursorColor: Colors.white,
                                  keyboardType: TextInputType.phone,
                                  maxLength: 10,
                                  autofillHints: const [
                                    AutofillHints.telephoneNumber,
                                  ],
                                  decoration: _decoration(
                                    'Teléfono',
                                    Icons.phone_outlined,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  key: const Key('login_crew'),
                                  controller: crew,
                                  style: inputStyle,
                                  cursorColor: Colors.white,
                                  decoration: _decoration(
                                    'Cuadrilla',
                                    Icons.groups_outlined,
                                  ),
                                ),
                                if (error != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 12),
                                    child: Text(
                                      error!,
                                      key: const Key('login_error'),
                                      style: const TextStyle(
                                        color: Color(0xffffd5d5),
                                      ),
                                    ),
                                  ),
                                if (app.pendingTakeoverToken != null)
                                  TextButton(
                                    style: TextButton.styleFrom(
                                      foregroundColor: Colors.white,
                                    ),
                                    onPressed: () async {
                                      final result = await app
                                          .revokeExistingSession();
                                      if (mounted) {
                                        setState(
                                          () => error =
                                              result ??
                                              'Sesión anterior cerrada. Inicia nuevamente.',
                                        );
                                      }
                                    },
                                    child: const Text(
                                      'Cerrar sesión del otro dispositivo',
                                    ),
                                  ),
                                const SizedBox(height: 18),
                                FilledButton(
                                  key: const Key('login_submit'),
                                  style: FilledButton.styleFrom(
                                    backgroundColor: Colors.white,
                                    foregroundColor: _blue,
                                  ),
                                  onPressed: app.busy
                                      ? null
                                      : () async {
                                          final result = await context
                                              .read<AppController>()
                                              .login(
                                                name: name.text,
                                                email: email.text,
                                                phone: phone.text,
                                                crew: crew.text,
                                                password: password.text,
                                              );
                                          if (mounted) {
                                            setState(() => error = result);
                                          }
                                        },
                                  child: app.busy
                                      ? const SizedBox.square(
                                          dimension: 22,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: _blue,
                                          ),
                                        )
                                      : const Text('INICIAR SESIÓN'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 5,
              child: IgnorePointer(
                child: Text(
                  '${app.packageInfo.version}+${app.packageInfo.buildNumber}',
                  key: const Key('login_version'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xfff1f3f8),
                    fontSize: 11,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
