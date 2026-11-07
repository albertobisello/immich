import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/models/cast/cast_manager_state.dart';
import 'package:immich_mobile/repositories/dlna.repository.dart';
import 'package:immich_mobile/services/dlna.service.dart';
import 'package:immich_mobile/services/gcast.service.dart';

final castProvider = StateNotifierProvider<CastNotifier, CastManagerState>(
  (ref) => CastNotifier(
    ref.watch(gCastServiceProvider),
    ref.watch(dlnaServiceProvider),
  ),
);

class CastNotifier extends StateNotifier<CastManagerState> {
  // more cast providers can be added here (ie Fcast)
  final GCastService _gCastService;
  final DlnaService _dlnaService;

  /// The protocol of the receiver currently in use
  CastDestinationType _activeType = CastDestinationType.googleCast;

  List<(String, CastDestinationType, dynamic)> discovered = List.empty();

  CastNotifier(this._gCastService, this._dlnaService)
    : super(
        const CastManagerState(
          isCasting: false,
          currentTime: Duration.zero,
          duration: Duration.zero,
          receiverName: '',
          castState: CastState.idle,
        ),
      ) {
    _gCastService.onConnectionState = _guard(
      CastDestinationType.googleCast,
      _onConnectionState,
    );
    _gCastService.onCurrentTime = _guard(
      CastDestinationType.googleCast,
      _onCurrentTime,
    );
    _gCastService.onDuration = _guard(
      CastDestinationType.googleCast,
      _onDuration,
    );
    _gCastService.onReceiverName = _guard(
      CastDestinationType.googleCast,
      _onReceiverName,
    );
    _gCastService.onCastState = _guard(
      CastDestinationType.googleCast,
      _onCastState,
    );

    _dlnaService.onConnectionState = _guard(
      CastDestinationType.dlna,
      _onConnectionState,
    );
    _dlnaService.onCurrentTime = _guard(
      CastDestinationType.dlna,
      _onCurrentTime,
    );
    _dlnaService.onDuration = _guard(CastDestinationType.dlna, _onDuration);
    _dlnaService.onReceiverName = _guard(
      CastDestinationType.dlna,
      _onReceiverName,
    );
    _dlnaService.onCastState = _guard(CastDestinationType.dlna, _onCastState);
  }

  /// Only forwards updates coming from the receiver type currently in use
  void Function(T) _guard<T>(
    CastDestinationType type,
    void Function(T) callback,
  ) {
    return (value) {
      if (_activeType == type && mounted) {
        callback(value);
      }
    };
  }

  void _onConnectionState(bool isCasting) {
    state = state.copyWith(isCasting: isCasting);
  }

  void _onCurrentTime(Duration currentTime) {
    state = state.copyWith(currentTime: currentTime);
  }

  void _onDuration(Duration duration) {
    state = state.copyWith(duration: duration);
  }

  void _onReceiverName(String receiverName) {
    state = state.copyWith(receiverName: receiverName);
  }

  void _onCastState(CastState castState) {
    state = state.copyWith(castState: castState);
  }

  void loadMedia(RemoteAsset asset, bool reload) {
    switch (_activeType) {
      case CastDestinationType.googleCast:
        unawaited(_gCastService.loadMedia(asset, reload));
      case CastDestinationType.dlna:
        unawaited(_dlnaService.loadMedia(asset, reload));
    }
  }

  Future<void> connect(CastDestinationType type, dynamic device) async {
    _activeType = type;
    switch (type) {
      case CastDestinationType.googleCast:
        await _gCastService.connect(device);
      case CastDestinationType.dlna:
        await _dlnaService.connect(device as DlnaDevice);
    }
  }

  Future<List<(String, CastDestinationType, dynamic)>> getDevices() async {
    if (discovered.isEmpty) {
      final results = await Future.wait([
        _gCastService.getDevices().catchError(
          (_) => <(String, CastDestinationType, dynamic)>[],
        ),
        _dlnaService.getDevices().catchError(
          (_) => <(String, CastDestinationType, dynamic)>[],
        ),
      ]);
      discovered = results.expand((devices) => devices).toList(growable: false);
    }

    return discovered;
  }

  void toggle() {
    switch (state.castState) {
      case CastState.playing:
        pause();
      case CastState.paused:
        play();
      default:
    }
  }

  void play() {
    switch (_activeType) {
      case CastDestinationType.googleCast:
        _gCastService.play();
      case CastDestinationType.dlna:
        _dlnaService.play();
    }
  }

  void pause() {
    switch (_activeType) {
      case CastDestinationType.googleCast:
        _gCastService.pause();
      case CastDestinationType.dlna:
        _dlnaService.pause();
    }
  }

  void seekTo(Duration position) {
    switch (_activeType) {
      case CastDestinationType.googleCast:
        _gCastService.seekTo(position);
      case CastDestinationType.dlna:
        _dlnaService.seekTo(position);
    }
  }

  void stop() {
    switch (_activeType) {
      case CastDestinationType.googleCast:
        _gCastService.stop();
      case CastDestinationType.dlna:
        _dlnaService.stop();
    }
  }

  Future<void> disconnect() async {
    switch (_activeType) {
      case CastDestinationType.googleCast:
        await _gCastService.disconnect();
      case CastDestinationType.dlna:
        await _dlnaService.disconnect();
    }
  }
}
