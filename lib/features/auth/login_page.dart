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
  final name = TextEditingController(),
      email = TextEditingController(),
      phone = TextEditingController(),
      crew = TextEditingController(),
      password = TextEditingController();
  bool administrative = false;
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

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xff2848b8), Color(0xff1d377e)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
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
                    const SizedBox(height: 18),
                    Text(
                      'DDR001 Levantamientos',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Acceso de campo',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xffe8edff)),
                    ),
                    const SizedBox(height: 22),
                    Card(
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.all(22),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SegmentedButton<bool>(
                              segments: const [
                                ButtonSegment(
                                  value: false,
                                  icon: Icon(Icons.engineering_outlined),
                                  label: Text('Campo'),
                                ),
                                ButtonSegment(
                                  value: true,
                                  icon: Icon(
                                    Icons.admin_panel_settings_outlined,
                                  ),
                                  label: Text('Administración'),
                                ),
                              ],
                              selected: {administrative},
                              onSelectionChanged: app.busy
                                  ? null
                                  : (value) => setState(() {
                                      administrative = value.single;
                                      error = null;
                                    }),
                            ),
                            const SizedBox(height: 24),
                            if (!administrative)
                              TextField(
                                key: const Key('login_name'),
                                controller: name,
                                textCapitalization: TextCapitalization.words,
                                decoration: const InputDecoration(
                                  labelText: 'Nombre completo',
                                  prefixIcon: Icon(Icons.person_outline),
                                ),
                              ),
                            if (!administrative) const SizedBox(height: 12),
                            TextField(
                              key: const Key('login_email'),
                              controller: email,
                              keyboardType: TextInputType.emailAddress,
                              decoration: const InputDecoration(
                                labelText: 'Correo',
                                prefixIcon: Icon(Icons.email_outlined),
                              ),
                            ),
                            const SizedBox(height: 12),
                            if (!administrative)
                              TextField(
                                key: const Key('login_phone'),
                                controller: phone,
                                keyboardType: TextInputType.phone,
                                maxLength: 10,
                                decoration: const InputDecoration(
                                  labelText: 'Teléfono',
                                  prefixIcon: Icon(Icons.phone_outlined),
                                ),
                              ),
                            if (!administrative) const SizedBox(height: 12),
                            if (!administrative)
                              TextField(
                                key: const Key('login_crew'),
                                controller: crew,
                                decoration: const InputDecoration(
                                  labelText: 'Cuadrilla',
                                  prefixIcon: Icon(Icons.groups_outlined),
                                ),
                              ),
                            if (administrative)
                              TextField(
                                key: const Key('admin_password'),
                                controller: password,
                                obscureText: true,
                                decoration: const InputDecoration(
                                  labelText: 'Contraseña',
                                  prefixIcon: Icon(Icons.lock_outline),
                                ),
                              ),
                            if (error != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Text(
                                  error!,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                ),
                              ),
                            if (app.pendingTakeoverToken != null)
                              TextButton(
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
                              onPressed: app.busy
                                  ? null
                                  : () async {
                                      final controller = context
                                          .read<AppController>();
                                      final result = administrative
                                          ? await controller.adminLogin(
                                              email: email.text,
                                              password: password.text,
                                            )
                                          : await controller.login(
                                              name: name.text,
                                              email: email.text,
                                              phone: phone.text,
                                              crew: crew.text,
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
      ),
    );
  }
}
