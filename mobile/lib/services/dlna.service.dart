import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/models/cast/cast_manager_state.dart';
import 'package:immich_mobile/models/sessions/session_create_response.model.dart';
import 'package:immich_mobile/repositories/asset_api.repository.dart';
import 'package:immich_mobile/repositories/dlna.repository.dart';
import 'package:immich_mobile/repositories/sessions_api.repository.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:immich_mobile/utils/url_helper.dart';
import 'package:logging/logging.dart';
// ignore: import_rule_openapi, we are only using the AssetMediaSize enum
import 'package:openapi/api.dart';

final dlnaServiceProvider = Provider(
  (ref) => DlnaService(
    ref.watch(dlnaRepositoryProvider),
    ref.watch(sessionsAPIRepositoryProvider),
    ref.watch(assetApiRepositoryProvider),
  ),
);

/// Casts photos and videos to UPnP/DLNA media renderers, such as LG webOS TVs.
///
/// The TV downloads the media directly from the Immich server, so the server
/// URL configured in the app must be reachable from the TV.
class DlnaService {
  final DlnaRepository _dlnaRepository;
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

  void Function(bool)? onConnectionState;
  void Function(Duration)? onCurrentTime;
  void Function(Duration)? onDuration;
  void Function(String)? onReceiverName;
  void Function(CastState)? onCastState;

  DlnaService(this._dlnaRepository, this._sessionsApiService, this._assetApiRepository);

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

  /// The API endpoint the TV should download media from.
  ///
  /// The TV can't use the phone's VPN (e.g. Tailscale), so prefer the local network URL
  /// configured in the networking settings, if any.
  static String castEndpoint() {
    final serverEndpoint = Store.get(StoreKey.serverEndpoint);
    final localEndpoint = SettingsRepository.instance.appConfig.network.localEndpoint?.trim();
    if (localEndpoint == null || localEndpoint.isEmpty) {
      return serverEndpoint;
    }
    final normalized = normalizeServerUrl(localEndpoint);
    return normalized.endsWith('/api') ? normalized : '$normalized/api';
  }

  /// Whether the server URL the TV would use is only reachable through a VPN like Tailscale
  static bool isCastEndpointVpnOnly() {
    final host = Uri.tryParse(castEndpoint())?.host.toLowerCase() ?? '';
    if (host.endsWith('.ts.net') || host.endsWith('.tailscale.net')) {
      return true;
    }
    final parts = host.split('.').map(int.tryParse).toList();
    return parts.length == 4 && parts[0] == 100 && parts[1] != null && parts[1]! >= 64 && parts[1]! < 128;
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
    onReceiverName?.call("");
    onConnectionState?.call(false);

    if (device != null) {
      try {
        await _dlnaRepository.sendAction(device, 'Stop');
      } catch (error) {
        _log.fine('Failed to stop DLNA renderer on disconnect', error);
      }
    }
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
    currentAssetId = asset.id;
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

      final unauthenticatedUrl = asset.isVideo
          ? getPlaybackUrlForRemoteId(asset.id)
          : getThumbnailUrlForRemoteId(asset.id, type: AssetMediaSize.fullsize);
      final serverEndpoint = Store.get(StoreKey.serverEndpoint);
      final endpoint = castEndpoint();
      final url = "${endpoint + unauthenticatedUrl.substring(serverEndpoint.length)}&sessionKey=${_sessionKey?.token}";
      if (isCastEndpointVpnOnly()) {
        _log.warning('The TV probably can not reach $endpoint: set a local network URL in the networking settings');
      }

      final mimeType = await _resolveMimeType(asset, url);
      if (generation != _loadGeneration || _device != device) {
        return;
      }

      final metadata = _buildDidlMetadata(asset, url, mimeType);

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

  Future<String> _resolveMimeType(RemoteAsset asset, String url) async {
    final fromServer = await _dlnaRepository.getContentType(url);
    if (fromServer != null && (fromServer.startsWith('image/') || fromServer.startsWith('video/'))) {
      return fromServer;
    }

    if (!asset.isVideo) {
      // full size previews are generated as JPEG by default
      return 'image/jpeg';
    }

    return await _assetApiRepository.getAssetMIMEType(asset.id) ?? 'video/mp4';
  }

  String _buildDidlMetadata(RemoteAsset asset, String url, String mimeType) {
    final upnpClass = asset.isVideo ? 'object.item.videoItem' : 'object.item.imageItem.photo';
    final dlnaFeatures = asset.isVideo
        ? 'DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000'
        : (mimeType == 'image/jpeg'
              ? 'DLNA.ORG_PN=JPEG_LRG;DLNA.ORG_OP=00;DLNA.ORG_CI=1;DLNA.ORG_FLAGS=00900000000000000000000000000000'
              : '*');
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
