import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

class SurveyGalleryPhoto {
  const SurveyGalleryPhoto({
    required this.id,
    this.localPath,
    this.loadOriginal,
    this.onDelete,
  });

  final String id;
  final String? localPath;
  final Future<Uint8List> Function()? loadOriginal;
  final VoidCallback? onDelete;
}

class SurveyPhotoGallery extends StatefulWidget {
  const SurveyPhotoGallery({
    super.key,
    required this.title,
    required this.photos,
    required this.initialIndex,
  });

  final String title;
  final List<SurveyGalleryPhoto> photos;
  final int initialIndex;

  @override
  State<SurveyPhotoGallery> createState() => _SurveyPhotoGalleryState();
}

class _SurveyPhotoGalleryState extends State<SurveyPhotoGallery> {
  late final PageController _controller;
  late int _index;
  bool _zoomMode = false;
  double _headerDrag = 0;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _move(int offset) => _controller.animateToPage(
    _index + offset,
    duration: const Duration(milliseconds: 200),
    curve: Curves.easeOutCubic,
  );

  @override
  Widget build(BuildContext context) => Dismissible(
    key: const Key('gallery_swipe_close'),
    direction: _zoomMode ? DismissDirection.none : DismissDirection.up,
    resizeDuration: null,
    dismissThresholds: const {DismissDirection.up: .15},
    onDismissed: (_) => Navigator.pop(context),
    child: Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.sizeOf(context).height * .8,
        child: Column(
          children: [
            GestureDetector(
              key: const Key('gallery_header'),
              behavior: HitTestBehavior.opaque,
              onVerticalDragStart: (_) => _headerDrag = 0,
              onVerticalDragUpdate: (details) =>
                  _headerDrag += details.delta.dy,
              onVerticalDragEnd: (_) {
                if (_headerDrag < -60) Navigator.pop(context);
              },
              child: Padding(
                padding: const EdgeInsets.only(left: 16, top: 16 * 1.2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.title,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontSize:
                                  (Theme.of(
                                        context,
                                      ).textTheme.titleMedium?.fontSize ??
                                      16) *
                                  1.15,
                            ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Cerrar',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
            ),
            if (_zoomMode)
              TextButton.icon(
                key: const Key('gallery_exit_zoom'),
                onPressed: () => setState(() => _zoomMode = false),
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Volver al carrusel'),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                _zoomMode
                    ? 'Pellizca para ampliar o reducir · Arrastra para mover\nDesliza el título hacia arriba para cerrar'
                    : 'Toca para ampliar · Desliza hacia arriba para cerrar',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Expanded(
              child: PageView.builder(
                key: const Key('survey_photo_pager'),
                controller: _controller,
                physics: _zoomMode
                    ? const NeverScrollableScrollPhysics()
                    : const ClampingScrollPhysics(),
                itemCount: widget.photos.length,
                onPageChanged: (index) => setState(() {
                  _index = index;
                  _zoomMode = false;
                }),
                itemBuilder: (context, index) => _GalleryImage(
                  key: ValueKey(widget.photos[index].id),
                  photo: widget.photos[index],
                  active: index == _index,
                  zoomMode: _zoomMode && index == _index,
                  onEnterZoom: () => setState(() => _zoomMode = true),
                ),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  key: const Key('gallery_previous'),
                  tooltip: 'Foto anterior',
                  onPressed: _index > 0 && !_zoomMode ? () => _move(-1) : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                Text(
                  '${_index + 1} de ${widget.photos.length}',
                  key: const Key('gallery_position'),
                ),
                IconButton(
                  key: const Key('gallery_next'),
                  tooltip: 'Foto siguiente',
                  onPressed: _index < widget.photos.length - 1 && !_zoomMode
                      ? () => _move(1)
                      : null,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
            if (widget.photos[_index].onDelete != null)
              TextButton.icon(
                onPressed: () {
                  final delete = widget.photos[_index].onDelete!;
                  Navigator.pop(context);
                  delete();
                },
                icon: const Icon(Icons.delete),
                label: const Text('Eliminar'),
              ),
          ],
        ),
      ),
    ),
  );
}

class _GalleryImage extends StatefulWidget {
  const _GalleryImage({
    super.key,
    required this.photo,
    required this.active,
    required this.zoomMode,
    required this.onEnterZoom,
  });
  final SurveyGalleryPhoto photo;
  final bool active;
  final bool zoomMode;
  final VoidCallback onEnterZoom;

  @override
  State<_GalleryImage> createState() => _GalleryImageState();
}

class _GalleryImageState extends State<_GalleryImage> {
  final _transform = TransformationController();
  Future<Uint8List>? _original;
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    if (widget.active && widget.photo.loadOriginal != null) {
      _original ??= widget.photo.loadOriginal!();
    }
  }

  @override
  void didUpdateWidget(covariant _GalleryImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.zoomMode && !widget.zoomMode) {
      _transform.value = Matrix4.identity();
    }
    _load();
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _scale(double factor, Size viewport) {
    final oldScale = _transform.value.getMaxScaleOnAxis();
    final scale = (oldScale * factor).clamp(1.0, 4.0);
    if (scale == 1) {
      _transform.value = Matrix4.identity();
      return;
    }
    final ratio = scale / oldScale;
    final offset = _transform.value.getTranslation();
    _transform.value = Matrix4.diagonal3Values(scale, scale, 1)
      ..setTranslationRaw(
        viewport.width / 2 - (viewport.width / 2 - offset.x) * ratio,
        viewport.height / 2 - (viewport.height / 2 - offset.y) * ratio,
        0,
      );
  }

  Widget _image(ImageProvider provider) => LayoutBuilder(
    builder: (context, constraints) {
      final image = Center(
        child: Image(
          image: ResizeImage(
            provider,
            width: 2048,
            height: 2048,
            policy: ResizeImagePolicy.fit,
          ),
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) =>
              const Text('Imagen no disponible temporalmente'),
        ),
      );
      if (!widget.zoomMode) {
        return GestureDetector(
          key: const Key('gallery_enter_zoom'),
          behavior: HitTestBehavior.opaque,
          onTap: widget.onEnterZoom,
          child: image,
        );
      }
      return Column(
        children: [
          Expanded(
            child: InteractiveViewer(
              key: const Key('gallery_zoom_viewer'),
              transformationController: _transform,
              minScale: 1,
              maxScale: 4,
              child: image,
            ),
          ),
          ValueListenableBuilder<Matrix4>(
            valueListenable: _transform,
            builder: (context, matrix, _) {
              final scale = matrix.getMaxScaleOnAxis();
              final viewport = Size(
                constraints.maxWidth,
                constraints.maxHeight - 48,
              );
              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    key: const Key('gallery_zoom_out'),
                    tooltip: 'Reducir',
                    onPressed: scale > 1.01
                        ? () => _scale(1 / 1.5, viewport)
                        : null,
                    icon: const Icon(Icons.remove),
                  ),
                  Text(
                    '${(scale * 100).round()}%',
                    key: const Key('gallery_zoom_percent'),
                  ),
                  IconButton(
                    key: const Key('gallery_zoom_in'),
                    tooltip: 'Ampliar',
                    onPressed: scale < 4 ? () => _scale(1.5, viewport) : null,
                    icon: const Icon(Icons.add),
                  ),
                  TextButton(
                    onPressed: () => _transform.value = Matrix4.identity(),
                    child: const Text('Restablecer'),
                  ),
                ],
              );
            },
          ),
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    if (!widget.active && _original == null && widget.photo.localPath == null) {
      return const SizedBox.expand();
    }
    if (widget.photo.localPath != null) {
      return _image(FileImage(File(widget.photo.localPath!)));
    }
    return FutureBuilder<Uint8List>(
      future: _original,
      builder: (context, snapshot) {
        if (snapshot.hasData) return _image(MemoryImage(snapshot.data!));
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Imagen no disponible temporalmente'),
                TextButton(
                  onPressed: () => setState(() {
                    _original = widget.photo.loadOriginal!();
                  }),
                  child: const Text('Reintentar'),
                ),
              ],
            ),
          );
        }
        return const Center(child: CircularProgressIndicator());
      },
    );
  }
}
