import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/services/app_controller.dart';
import '../../domain/construction/construction_models.dart';
import 'survey_detail_page.dart';

class SurveysPage extends StatefulWidget {
  const SurveysPage({super.key});
  @override
  State<SurveysPage> createState() => _SurveysPageState();
}

class _SurveysPageState extends State<SurveysPage> {
  String search = '';
  SurveyStatus? filter;
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>(),
        items = app.surveys.where((s) {
          final query = search.trim().toLowerCase(),
              matches =
                  query.isEmpty ||
                  s.displayIdentifier.toLowerCase().contains(query) ||
                  (s.accountNumber ?? '').toLowerCase().contains(query);
          return matches && (filter == null || s.status == filter);
        }).toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return Scaffold(
      appBar: AppBar(title: const Text('Mis levantamientos')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              key: const Key('survey_search'),
              onChanged: (v) => setState(() => search = v),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Buscar identificador o cuenta',
              ),
            ),
          ),
          SizedBox(
            height: 46,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                FilterChip(
                  label: const Text('Todos'),
                  selected: filter == null,
                  onSelected: (_) => setState(() => filter = null),
                ),
                ...SurveyStatus.values.map(
                  (s) => Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: FilterChip(
                      label: Text(statusLabel(s)),
                      selected: filter == s,
                      onSelected: (_) => setState(() => filter = s),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: RefreshIndicator(
              onRefresh: app.refreshServer,
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (_, i) {
                  final s = items[i];
                  return Card(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 5,
                    ),
                    child: ListTile(
                      key: Key('survey_${s.id}'),
                      title: Text(
                        s.displayIdentifier,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(
                        '${s.accountNumber ?? 'Sin cuenta'} · ${statusLabel(s.status)} · Etapa ${s.currentStep}/6',
                      ),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(syncIcon(s.syncState), size: 20),
                          const Icon(Icons.chevron_right, size: 20),
                        ],
                      ),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => SurveyDetailPage(surveyId: s.id),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String statusLabel(SurveyStatus status) => switch (status) {
  SurveyStatus.created => 'En proceso',
  SurveyStatus.inProgress => 'En proceso',
  SurveyStatus.executed => 'Ejecutado',
  SurveyStatus.rejected => 'Rechazado',
  SurveyStatus.accepted => 'Aceptado',
  SurveyStatus.delivered => 'Entregado',
};
IconData syncIcon(SyncState state) => switch (state) {
  SyncState.synchronized => Icons.cloud_done,
  SyncState.syncing => Icons.sync,
  SyncState.offline => Icons.cloud_off,
  SyncState.requiresReview => Icons.warning_amber,
  SyncState.pending => Icons.cloud_upload_outlined,
};
