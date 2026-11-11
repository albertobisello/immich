import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/models/cast/cast_manager_state.dart';
import 'package:immich_mobile/models/sessions/session_create_response.model.dart';
import 'package:immich_mobile/repositories/asset_api.repository.dart';
import 'package:immich_mobile/repositories/dlna.repository.dart';
import 'package:immich_mobile/repositories/dlna_proxy.repository.dart';
import 'package:immich_mobile/repositories/sessions_api.repository.dart';
import 'package:immich_mobile/utils/cast_crop.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:logging/logging.dart';
// ignore: import_rule_openapi, we are only using the AssetMediaSize enum
import 'package:openapi/api.dart';

final dlnaServiceProvider = Provider(
  (ref) => DlnaService(
    ref.watch(dlnaRepositoryProvider),
    ref.watch(dlnaProxyRepositoryProvider),
    ref.watch(sessionsAPIRepositoryProvider),
    ref.watch(assetApiRepositoryProvider),
  ),
);

/// Casts photos and videos to UPnP/DLNA media renderers, such as LG webOS TVs.
///
/// The TV downloads the media from a small relay on the phone ([DlnaProxyRepository]),
/// so it works even when the server is only reachable through the phone's VPN.
class DlnaService {
  final DlnaRepository _dlnaRepository;
  final DlnaProxyRepository _dlnaProxyRepository;
  final SessionsAPIRepository _sessionsApiService;
  final AssetApiRepository _assetApiRepository;

  final _log = Logger('DlnaService');

  DlnaDevice? _device;
  SessionCreateResponse? _sessionKey;
  String? currentAssetId;
  bool _isVideo = false;
  Timer? _pollingTimer;
  bool _polling = false;
  int _loadGeneration = 0;

  // Zoom mirroring for photos
  RemoteAsset? _currentAsset;
  ({String url, String metadata})? _fullImage;
  String? _sourceUrl;
  ({String assetId, Uint8List bytes})? _sourceCache;
  int _cropGeneration = 0;
  bool _showingCrop = false;

  void Function(bool)? onConnectionState;
  void Function(Duration)? onCurrentTime;
  void Function(Duration)? onDuration;
  void Function(String)? onReceiverName;
  void Function(CastState)? onCastState;

  DlnaService(this._dlnaRepository, this._dlnaProxyRepository, this._sessionsApiService, this._assetApiRepository);

  bool get isConnected => _device != null;

  Future<List<(String, CastDestinationType, dynamic)>> getDevices() async {
    final devices = await _dlnaRepository.listDestinations(extraHosts: manualHosts);
    return devices.map(_toDestination).toList(growable: false);
  }

  (String, CastDestinationType, dynamic) _toDestination(DlnaDevice device) =>
      (device.name, CastDestinationType.dlna, device);

  /// Addresses of TVs added by hand, for networks where multicast discovery doesn't work
  List<String> get manualHosts =>
      (Store.tryGet(StoreKey.castManualDevices) ?? '').split(',').where((h) => h.isNotEmpty).toList();

  /// Looks for a renderer at [host] (IP address, hostname or description URL) and remembers it if found
  Future<List<(String, CastDestinationType, dynamic)>> addManualDevice(String host) async {
    final trimmed = host.trim();
    if (trimmed.isEmpty) {
      return const [];
    }

    final devices = await _dlnaRepository.listDestinations(extraHosts: [trimmed], timeout: const Duration(seconds: 2));
    final targetHost = Uri.tryParse(trimmed)?.host;
    final matching = devices
        .where((d) => d.location.host == trimmed || d.location.toString() == trimmed || d.location.host == targetHost)
        .toList();

    if (matching.isNotEmpty) {
      final hosts = {...manualHosts, trimmed};
      await Store.put(StoreKey.castManualDevices, hosts.join(','));
    }
    return matching.map(_toDestination).toList(growable: false);
  }

  Future<void> connect(DlnaDevice device) async {
    // DLNA has no session: the renderer is "connected" as soon as it is selected
    onReceiverName?.call(device.name);
    _device = device;
    onCastState?.call(CastState.idle);
    onConnectionState?.call(true);
  }

  Future<void> disconnect() async {
    final device = _device;
    _stopPolling();
    _device = null;
    currentAssetId = null;
    _currentAsset = null;
    _sourceCache = null;
    onReceiverName?.call("");
    onConnectionState?.call(false);

    if (device != null) {
      try {
        await _dlnaRepository.sendAction(device, 'Stop');
      } catch (error) {
        _log.fine('Failed to stop DLNA renderer on disconnect', error);
      }
    }
    await _dlnaProxyRepository.stop();
  }

  bool _isSessionValid() {
    final expiresAt = _sessionKey?.expiresAt;
    if (expiresAt == null) {
      return false;
    }
    final bufferedExpiration = DateTime.parse(expiresAt).subtract(const Duration(minutes: 1));
    return bufferedExpiration.isAfter(DateTime.now());
  }

  Future<void> loadMedia(RemoteAsset asset, bool reload) async {
    final device = _device;
    if (device == null) {
      return;
    } else if (asset.id == currentAssetId && !reload) {
      return;
    }

    final generation = ++_loadGeneration;
    _cropGeneration++;
    currentAssetId = asset.id;
    _currentAsset = asset;
    _fullImage = null;
    _sourceUrl = null;
    _showingCrop = false;
    _isVideo = asset.isVideo;
    _stopPolling();
    onCastState?.call(CastState.buffering);
    onCurrentTime?.call(Duration.zero);
    onDuration?.call(Duration.zero);

    try {
      if (!_isSessionValid()) {
        // TVs don't refresh tokens, so make it last for a long movie
        _sessionKey = await _sessionsApiService.createSession(
          "Cast",
          "DLNA",
          duration: const Duration(hours: 3).inSeconds,
        );
      }

      final media = await _resolveMedia(asset);
      if (generation != _loadGeneration || _device != device) {
        return;
      }

      final dlnaFeatures = asset.isVideo ? _videoFeatures : _imageFeatures;
      final url = await _dlnaProxyRepository.publish(
        upstream: Uri.parse(media.url),
        mimeType: media.mimeType,
        dlnaFeatures: dlnaFeatures,
        isVideo: asset.isVideo,
        rendererHost: device.location.host,
      );
      _log.info('Casting ${asset.id} (${media.mimeType}) to ${device.name} via $url');
      final metadata = _buildDidlMetadata(asset, url, media.mimeType, dlnaFeatures);
      if (!asset.isVideo) {
        _fullImage = (url: url, metadata: metadata);
        _sourceUrl = media.url;
      }

      await _setUri(device, url, metadata);

      if (generation != _loadGeneration) {
        return;
      }

      await _dlnaRepository.sendAction(device, 'Play', {'Speed': '1'});
      _startPolling();
    } catch (error, stackTrace) {
      _log.warning('Failed to cast asset ${asset.id} via DLNA', error, stackTrace);
      if (generation == _loadGeneration) {
        currentAssetId = null;
        onCastState?.call(CastState.idle);
      }
    }
  }

  Future<void> _setUri(DlnaDevice device, String url, String metadata) async {
    try {
      await _dlnaRepository.sendAction(device, 'SetAVTransportURI', {
        'CurrentURI': url,
        'CurrentURIMetaData': metadata,
      });
    } on DlnaSoapException {
      // Some renderers (LG included) refuse a new URI while playing, stop and retry
      await _dlnaRepository.sendAction(device, 'Stop');
      await _dlnaRepository.sendAction(device, 'SetAVTransportURI', {
        'CurrentURI': url,
        'CurrentURIMetaData': metadata,
      });
    }
  }

  /// Mirrors the phone's zoom on the TV: DLNA renderers can't zoom, so the visible part of the
  /// photo is cropped on the phone and sent as a new image. A null [crop] restores the whole photo.
  Future<void> showCrop(String assetId, Rect? crop) async {
    final device = _device;
    final asset = _currentAsset;
    final fullImage = _fullImage;
    final sourceUrl = _sourceUrl;
    if (device == null || asset == null || asset.id != assetId || fullImage == null || sourceUrl == null) {
      return;
    }

    final generation = ++_cropGeneration;
    final loadGeneration = _loadGeneration;
    bool stale() => generation != _cropGeneration || loadGeneration != _loadGeneration || _device != device;

    try {
      if (crop == null) {
        if (_showingCrop) {
          _showingCrop = false;
          await _setUri(device, fullImage.url, fullImage.metadata);
          if (!stale()) {
            await _dlnaRepository.sendAction(device, 'Play', {'Speed': '1'});
          }
        }
        return;
      }

      final cached = _sourceCache;
      final Uint8List source;
      if (cached != null && cached.assetId == asset.id) {
        source = cached.bytes;
      } else {
        source = await _dlnaProxyRepository.fetchBytes(Uri.parse(sourceUrl));
        _sourceCache = (assetId: asset.id, bytes: source);
      }
      if (stale()) {
        return;
      }

      final jpeg = await renderCastCrop(source, crop);
      if (stale()) {
        return;
      }

      final url = await _dlnaProxyRepository.publishBytes(
        bytes: jpeg,
        mimeType: 'image/jpeg',
        dlnaFeatures: _imageFeatures,
        rendererHost: device.location.host,
      );
      _log.fine('Showing crop $crop of ${asset.id} on ${device.name} (${jpeg.length} bytes)');
      _showingCrop = true;
      await _setUri(device, url, _buildDidlMetadata(asset, url, 'image/jpeg', _imageFeatures));
      if (!stale()) {
        await _dlnaRepository.sendAction(device, 'Play', {'Speed': '1'});
      }
    } catch (error, stackTrace) {
      _log.warning('Failed to show zoomed photo on the TV', error, stackTrace);
    }
  }

  static const _videoFeatures = 'DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000';
  static const _imageFeatures = 'DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=00D00000000000000000000000000000';
  static const _tvImageTypes = {'image/jpeg', 'image/png'};

  String _authenticated(String url) => "$url&sessionKey=${_sessionKey?.token}";

  /// Picks the media URL and its real content type.
  ///
  /// For photos the full size endpoint redirects to the original when the browser can display it,
  /// which may be a format the TV doesn't support (WebP, AVIF, GIF...): fall back to the JPEG preview.
  Future<({String url, String mimeType})> _resolveMedia(RemoteAsset asset) async {
    if (asset.isVideo) {
      final url = _authenticated(getPlaybackUrlForRemoteId(asset.id));
      final probed = await _dlnaProxyRepository.probeContentType(Uri.parse(url));
      final mimeType = probed != null && probed.startsWith('video/')
          ? probed
          : await _assetApiRepository.getAssetMIMEType(asset.id) ?? 'video/mp4';
      return (url: url, mimeType: mimeType);
    }

    final fullsize = _authenticated(getThumbnailUrlForRemoteId(asset.id, type: AssetMediaSize.fullsize));
    final fullsizeType = await _dlnaProxyRepository.probeContentType(Uri.parse(fullsize));
    if (fullsizeType != null && _tvImageTypes.contains(fullsizeType)) {
      return (url: fullsize, mimeType: fullsizeType);
    }

    _log.info('Full size image of ${asset.id} is $fullsizeType, casting the preview instead');
    final preview = _authenticated(getThumbnailUrlForRemoteId(asset.id, type: AssetMediaSize.preview));
    final previewType = await _dlnaProxyRepository.probeContentType(Uri.parse(preview));
    return (url: preview, mimeType: previewType ?? 'image/jpeg');
  }

  String _buildDidlMetadata(RemoteAsset asset, String url, String mimeType, String dlnaFeatures) {
    final upnpClass = asset.isVideo ? 'object.item.videoItem' : 'object.item.imageItem.photo';
    final duration = asset.isVideo && asset.duration > Duration.zero
        ? ' duration="${_formatTime(asset.duration)}.000"'
        : '';
    final title = DlnaRepository.escapeXml(asset.name);

    return '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" '
        'xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/">'
        '<item id="${DlnaRepository.escapeXml(asset.id)}" parentID="0" restricted="1">'
        '<dc:title>$title</dc:title>'
        '<upnp:class>$upnpClass</upnp:class>'
        '<res protocolInfo="http-get:*:$mimeType:$dlnaFeatures"$duration>${DlnaRepository.escapeXml(url)}</res>'
        '</item>'
        '</DIDL-Lite>';
  }

  void _startPolling() {
    _stopPolling();
    _pollingTimer = Timer.periodic(const Duration(seconds: 1), (_) => unawaited(_poll()));
    unawaited(_poll());
  }

  void _stopPolling() {
    _pollingTimer?.cancel();
    _pollingTimer = null;
  }

  Future<void> _poll() async {
    final device = _device;
    if (device == null) {
      _stopPolling();
      return;
    }
    if (_polling) {
      return;
    }
    _polling = true;

    try {
      final transport = await _dlnaRepository.sendAction(device, 'GetTransportInfo');
      final castState = switch (transport['CurrentTransportState']) {
        'PLAYING' => CastState.playing,
        'PAUSED_PLAYBACK' || 'PAUSED_RECORDING' => CastState.paused,
        'TRANSITIONING' => CastState.buffering,
        _ => CastState.idle,
      };
      onCastState?.call(castState);

      if (_isVideo) {
        final position = await _dlnaRepository.sendAction(device, 'GetPositionInfo');
        final duration = _parseTime(position['TrackDuration']);
        final relTime = _parseTime(position['RelTime']);
        if (duration != null && duration > Duration.zero) {
          onDuration?.call(duration);
        }
        if (relTime != null) {
          onCurrentTime?.call(relTime);
        }
      } else if (castState != CastState.buffering) {
        // photos don't change state once displayed
        _stopPolling();
      }
    } catch (error) {
      _log.fine('DLNA status polling failed', error);
    } finally {
      _polling = false;
    }
  }

  Future<void> _send(String action, [Map<String, String> arguments = const {}]) async {
    final device = _device;
    if (device == null) {
      return;
    }
    try {
      await _dlnaRepository.sendAction(device, action, arguments);
    } catch (error, stackTrace) {
      _log.warning('DLNA action $action failed', error, stackTrace);
    }
  }

  void play() {
    unawaited(_send('Play', {'Speed': '1'}).then((_) => _startPolling()));
  }

  void pause() {
    unawaited(_send('Pause'));
  }

  void seekTo(Duration position) {
    unawaited(_send('Seek', {'Unit': 'REL_TIME', 'Target': _formatTime(position)}));
  }

  void stop() {
    _loadGeneration++;
    _stopPolling();
    currentAssetId = null;
    _currentAsset = null;
    unawaited(_send('Stop'));
  }

  static String _formatTime(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  /// Parses UPnP time strings like `0:01:23`, `00:01:23.456` or `NOT_IMPLEMENTED`
  static Duration? _parseTime(String? value) {
    if (value == null) {
      return null;
    }
    final parts = value.trim().split(':');
    if (parts.length != 3) {
      return null;
    }
    final hours = int.tryParse(parts[0]);
    final minutes = int.tryParse(parts[1]);
    final seconds = double.tryParse(parts[2]);
    if (hours == null || minutes == null || seconds == null) {
      return null;
    }
    return Duration(hours: hours, minutes: minutes, milliseconds: (seconds * 1000).round());
  }
}
