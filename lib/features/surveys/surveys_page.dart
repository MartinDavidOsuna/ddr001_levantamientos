import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/services/app_controller.dart';
import '../../core/widgets/branded_app_bar_title.dart';
import '../../domain/construction/construction_models.dart';
import 'survey_detail_page.dart';

class SurveysPage extends StatefulWidget {
  const SurveysPage({super.key});
  @override
  State<SurveysPage> createState() => _SurveysPageState();
}

enum SurveyListFilter { inProgress, executed, rejected, accepted, delivered }

bool surveyMatchesFilter(BaseSurvey survey, SurveyListFilter? filter) =>
    switch (filter) {
      null => true,
      SurveyListFilter.inProgress =>
        survey.status == SurveyStatus.created ||
            survey.status == SurveyStatus.inProgress,
      SurveyListFilter.executed => survey.status == SurveyStatus.executed,
      SurveyListFilter.rejected => survey.status == SurveyStatus.rejected,
      SurveyListFilter.accepted => survey.status == SurveyStatus.accepted,
      SurveyListFilter.delivered => survey.status == SurveyStatus.delivered,
    };

String surveyFilterLabel(SurveyListFilter filter) => switch (filter) {
  SurveyListFilter.inProgress => 'En proceso',
  SurveyListFilter.executed => 'Ejecutados',
  SurveyListFilter.rejected => 'Rechazados',
  SurveyListFilter.accepted => 'Entregables',
  SurveyListFilter.delivered => 'Entregados',
};

class _SurveysPageState extends State<SurveysPage> {
  String search = '';
  SurveyListFilter? filter;
  bool refreshing = false;

  Future<void> _refresh(AppController app, {bool showFeedback = false}) async {
    if (refreshing) return;
    setState(() => refreshing = true);
    try {
      await app.refreshServer();
      if (!mounted || !showFeedback) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            app.apiReachable
                ? 'Listado actualizado.'
                : 'Sin conexión con el servidor. Se conservan los datos locales.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>(),
        items = app.visibleSurveys.where((s) {
          final query = search.trim().toLowerCase(),
              matches =
                  query.isEmpty ||
                  s.displayIdentifier.toLowerCase().contains(query) ||
                  (s.accountNumber ?? '').toLowerCase().contains(query);
          return matches && surveyMatchesFilter(s, filter);
        }).toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return Scaffold(
      appBar: AppBar(
        title: BrandedAppBarTitle(
          (app.profile?.role ?? ConstructionRole.contractor).surveyListTitle,
        ),
        actions: [
          TextButton.icon(
            key: const Key('survey_refresh'),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.onPrimary,
            ),
            onPressed: refreshing
                ? null
                : () => _refresh(app, showFeedback: true),
            icon: refreshing
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            label: const Text('Actualizar'),
          ),
        ],
      ),
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
                ...SurveyListFilter.values.map(
                  (s) => Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: FilterChip(
                      label: Text(surveyFilterLabel(s)),
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
              onRefresh: () => _refresh(app),
              child: ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
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
                        '${s.accountNumber ?? 'Sin cuenta'} · ${surveyStatusLabel(s.status)} · Etapa ${s.currentStep}/6'
                        '${app.profile?.role.isReviewer == true ? '\nContratista: ${s.contractorName}' : ''}',
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

IconData syncIcon(SyncState state) => switch (state) {
  SyncState.synchronized => Icons.cloud_done,
  SyncState.syncing => Icons.sync,
  SyncState.offline => Icons.cloud_off,
  SyncState.requiresReview => Icons.warning_amber,
  SyncState.pending => Icons.cloud_upload_outlined,
};
