import 'package:flutter/material.dart';

import '../../domain/construction/construction_models.dart';

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

class SurveyFilterChips extends StatelessWidget {
  const SurveyFilterChips({
    required this.selected,
    required this.onSelected,
    this.keyPrefix = 'survey_filter',
    super.key,
  });

  final SurveyListFilter? selected;
  final ValueChanged<SurveyListFilter?> onSelected;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 46,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      children: [
        FilterChip(
          key: Key('${keyPrefix}_all'),
          label: const Text('Todos'),
          selected: selected == null,
          onSelected: (_) => onSelected(null),
        ),
        ...SurveyListFilter.values.map(
          (filter) => Padding(
            padding: const EdgeInsets.only(left: 8),
            child: FilterChip(
              key: Key('${keyPrefix}_${filter.name}'),
              label: Text(surveyFilterLabel(filter)),
              selected: selected == filter,
              onSelected: (_) => onSelected(filter),
            ),
          ),
        ),
      ],
    ),
  );
}
