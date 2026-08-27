import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/services/app_controller.dart';

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
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(
                    Icons.foundation,
                    size: 72,
                    color: Color(0xff176b5b),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'DDR001 Levantamientos',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text('Acceso de campo', textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('Campo')),
                      ButtonSegment(value: true, label: Text('Administración')),
                    ],
                    selected: {administrative},
                    onSelectionChanged: app.busy
                        ? null
                        : (value) => setState(() {
                            administrative = value.single;
                            error = null;
                          }),
                  ),
                  const SizedBox(height: 28),
                  if (!administrative)
                    TextField(
                      key: const Key('login_name'),
                      controller: name,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Nombre completo',
                      ),
                    ),
                  if (!administrative) const SizedBox(height: 12),
                  TextField(
                    key: const Key('login_email'),
                    controller: email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(labelText: 'Correo'),
                  ),
                  const SizedBox(height: 12),
                  if (!administrative)
                    TextField(
                      key: const Key('login_phone'),
                      controller: phone,
                      keyboardType: TextInputType.phone,
                      maxLength: 10,
                      decoration: const InputDecoration(labelText: 'Teléfono'),
                    ),
                  if (!administrative) const SizedBox(height: 12),
                  if (!administrative)
                    TextField(
                      key: const Key('login_crew'),
                      controller: crew,
                      decoration: const InputDecoration(labelText: 'Cuadrilla'),
                    ),
                  if (administrative)
                    TextField(
                      key: const Key('admin_password'),
                      controller: password,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Contraseña',
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
                        final result = await app.revokeExistingSession();
                        if (mounted) {
                          setState(
                            () => error =
                                result ??
                                'Sesión anterior cerrada. Inicia nuevamente.',
                          );
                        }
                      },
                      child: const Text('Cerrar sesión del otro dispositivo'),
                    ),
                  const SizedBox(height: 18),
                  FilledButton(
                    key: const Key('login_submit'),
                    onPressed: app.busy
                        ? null
                        : () async {
                            final controller = context.read<AppController>();
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
                            if (mounted) setState(() => error = result);
                          },
                    child: app.busy
                        ? const SizedBox.square(
                            dimension: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('INICIAR SESIÓN'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
