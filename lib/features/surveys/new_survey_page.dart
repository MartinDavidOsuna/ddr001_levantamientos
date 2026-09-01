import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/services/app_controller.dart';
import '../../core/widgets/branded_app_bar_title.dart';
import 'survey_detail_page.dart';

class NewSurveyPage extends StatefulWidget {
  const NewSurveyPage({super.key});
  @override
  State<NewSurveyPage> createState() => _NewSurveyPageState();
}

class _NewSurveyPageState extends State<NewSurveyPage> {
  final controller = TextEditingController();
  final accountController = TextEditingController();
  String? error;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const BrandedAppBarTitle('Nuevo levantamiento')),
    body: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Paso 0 · Creación',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('display_identifier'),
            controller: controller,
            autofocus: true,
            maxLength: 180,
            decoration: const InputDecoration(
              labelText: 'Identificador de la base *',
              hintText: 'Ej. Losa parcela 18',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('account_number'),
            controller: accountController,
            maxLength: 50,
            decoration: const InputDecoration(
              labelText: 'Número de cuenta (opcional)',
              hintText: 'Ej. 890',
            ),
          ),
          const Text(
            'Puede dejarse vacío y ser asignado posteriormente por un residente.',
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const Spacer(),
          FilledButton(
            key: const Key('create_survey'),
            onPressed: () async {
              try {
                final survey = await context.read<AppController>().createSurvey(
                  controller.text,
                  accountNumber: accountController.text,
                );
                if (context.mounted) {
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SurveyDetailPage(surveyId: survey.id),
                    ),
                  );
                }
              } catch (e) {
                setState(
                  () => error = e.toString().replaceFirst('Bad state: ', ''),
                );
              }
            },
            child: const Text('CREAR Y CONTINUAR'),
          ),
        ],
      ),
    ),
  );
}
