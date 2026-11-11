import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/providers/cast.provider.dart';
import 'package:immich_mobile/widgets/photo_view/photo_view.dart';

/// Mirrors the zoom and pan of the photo on screen to a DLNA TV, which can't zoom by itself.
///
/// Renders nothing: it only watches the [PhotoView] controller and, once the gesture settles,
/// tells the cast provider which part of the photo is visible.
class CastZoomSync extends ConsumerStatefulWidget {
  final String assetId;
  final PhotoViewControllerBase? controller;
  final Size viewportSize;

  const CastZoomSync({super.key, required this.assetId, required this.controller, required this.viewportSize});

  @override
  ConsumerState<CastZoomSync> createState() => _CastZoomSyncState();
}

class _CastZoomSyncState extends ConsumerState<CastZoomSync> {
  static const _settleDelay = Duration(milliseconds: 500);

  StreamSubscription<PhotoViewControllerValue>? _subscription;
  Timer? _debounce;
  Rect? _lastSent;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _attach(widget.controller);
  }

  @override
  void didUpdateWidget(CastZoomSync oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller || oldWidget.assetId != widget.assetId) {
      _detach();
      _lastSent = null;
      _zoomed = false;
      _attach(widget.controller);
    }
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  void _attach(PhotoViewControllerBase? controller) {
    _subscription = controller?.outputStateStream.listen(_onValue);
  }

  void _detach() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    _debounce?.cancel();
    _debounce = null;
  }

  void _onValue(PhotoViewControllerValue value) {
    final boundaries = widget.controller?.scaleBoundaries;
    final scale = value.scale;
    if (boundaries == null || scale == null) {
      return;
    }

    final zoomed = scale > boundaries.initialScale * 1.05;
    // nothing to do while the photo stays at its initial size
    if (!zoomed && !_zoomed) {
      return;
    }
    _zoomed = zoomed;

    final crop = zoomed ? _visibleRect(boundaries.childSize, boundaries.outerSize, scale, value.position) : null;
    _debounce?.cancel();
    _debounce = Timer(_settleDelay, () => _send(crop));
  }

  /// The visible part of the photo, in normalized coordinates (0..1)
  Rect? _visibleRect(Size childSize, Size outerSize, double scale, Offset position) {
    final width = childSize.width * scale;
    final height = childSize.height * scale;
    if (width <= 0 || height <= 0) {
      return null;
    }

    final viewport = outerSize.isEmpty ? widget.viewportSize : outerSize;
    // top-left corner of the photo on screen
    final left = viewport.width / 2 + position.dx - width / 2;
    final top = viewport.height / 2 + position.dy - height / 2;

    final rect = Rect.fromLTRB(
      (-left / width).clamp(0.0, 1.0),
      (-top / height).clamp(0.0, 1.0),
      ((viewport.width - left) / width).clamp(0.0, 1.0),
      ((viewport.height - top) / height).clamp(0.0, 1.0),
    );
    return rect.width >= 0.99 && rect.height >= 0.99 ? null : rect;
  }

  void _send(Rect? crop) {
    if (!mounted) {
      return;
    }
    final last = _lastSent;
    if (crop == last || (crop != null && last != null && _isClose(crop, last))) {
      return;
    }
    _lastSent = crop;
    ref.read(castProvider.notifier).setZoom(widget.assetId, crop);
  }

  static bool _isClose(Rect a, Rect b) =>
      (a.left - b.left).abs() < 0.005 &&
      (a.top - b.top).abs() < 0.005 &&
      (a.right - b.right).abs() < 0.005 &&
      (a.bottom - b.bottom).abs() < 0.005;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
