import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../../core/services/app_controller.dart';
import '../../core/widgets/branded_app_bar_title.dart';
import '../../domain/construction/construction_models.dart';
import '../surveys/survey_detail_page.dart';
import '../surveys/survey_filters.dart';
import 'map_status_legend.dart';

class ConstructionMapPage extends StatefulWidget {
  const ConstructionMapPage({super.key});

  @override
  State<ConstructionMapPage> createState() => _ConstructionMapPageState();
}

class _ConstructionMapPageState extends State<ConstructionMapPage> {
  SurveyListFilter? filter;

  static const colors = {
    SurveyStatus.created: Color(0xff2878b5),
    SurveyStatus.inProgress: Color(0xff2878b5),
    SurveyStatus.executed: Color(0xffe07a1f),
    SurveyStatus.rejected: Color(0xffc93434),
    SurveyStatus.accepted: Color(0xff5b4bb7),
    SurveyStatus.delivered: Color(0xff238653),
  };
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>(),
        points = app.visibleSurveys
            .where(
              (survey) =>
                  survey.canonicalLocation != null &&
                  surveyMatchesFilter(survey, filter),
            )
            .toList();
    return Scaffold(
      appBar: AppBar(
        title: BrandedAppBarTitle(
          app.profile?.role.isReviewer == true
              ? 'Mapa de bases'
              : 'Mis bases en mapa',
        ),
      ),
      body: Column(
        children: [
          SurveyFilterChips(
            keyPrefix: 'map_filter',
            selected: filter,
            onSelected: (value) => setState(() => filter = value),
          ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: points.isEmpty
                      ? const Center(
                          child: Text(
                            'Los levantamientos con ubicación aparecerán aquí.',
                          ),
                        )
                      : FlutterMap(
                          options: MapOptions(
                            initialCenter: LatLng(
                              points.first.canonicalLocation!.latitude,
                              points.first.canonicalLocation!.longitude,
                            ),
                            initialZoom: 13,
                          ),
                          children: [
                            TileLayer(
                              urlTemplate:
                                  'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                              userAgentPackageName:
                                  'com.aquafim.ddr001levantamientos',
                              errorTileCallback: (_, _, _) {},
                            ),
                            MarkerLayer(
                              markers: points
                                  .map(
                                    (s) => Marker(
                                      point: LatLng(
                                        s.canonicalLocation!.latitude,
                                        s.canonicalLocation!.longitude,
                                      ),
                                      width: 52,
                                      height: 52,
                                      child: Tooltip(
                                        message:
                                            '${s.displayIdentifier}\n'
                                            '${s.accountNumber ?? 'Sin cuenta'} · ${surveyStatusLabel(s.status)}\n'
                                            'Etapa ${s.currentStep} · ${s.updatedAt.toLocal()}\n'
                                            '${app.profile?.role.isReviewer == true ? 'Contratista: ${s.contractorName}' : ''}',
                                        child: IconButton(
                                          key: Key('map_survey_${s.id}'),
                                          icon: Icon(
                                            Icons.location_pin,
                                            size: 44,
                                            color: colors[s.status],
                                          ),
                                          onPressed: () => Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) => SurveyDetailPage(
                                                surveyId: s.id,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  )
                                  .toList(),
                            ),
                          ],
                        ),
                ),
                const Positioned(top: 10, left: 10, child: MapStatusLegend()),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: !app.online
          ? const FloatingActionButton.small(
              onPressed: null,
              child: Icon(Icons.cloud_off),
            )
          : null,
    );
  }
}
