import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:logging/logging.dart';

final dlnaProxyRepositoryProvider = Provider((ref) {
  final proxy = DlnaProxyRepository(() => SettingsRepository.instance.appConfig.network.customHeaders);
  ref.onDispose(() => unawaited(proxy.stop()));
  return proxy;
});

class _ProxyEntry {
  final Uri? upstream;
  final Uint8List? bytes;
  final String mimeType;
  final String dlnaFeatures;
  final bool isVideo;

  const _ProxyEntry(this.upstream, this.mimeType, this.dlnaFeatures, this.isVideo, {this.bytes});
}

/// A tiny HTTP server on the phone that relays media from the Immich server to a DLNA TV.
///
/// TVs often can't load media straight from the server: the server may only be reachable
/// through the phone's VPN (e.g. Tailscale), need custom headers, or answer with redirects,
/// which many renderers (LG included) don't follow. The phone fetches the media the same way
/// the app does and serves it on the local network with the headers DLNA renderers expect.
class DlnaProxyRepository {
  /// Extra headers configured in the networking settings (e.g. for a reverse proxy)
  final Map<String, String> Function() _extraHeaders;

  /// Plain dart:io client: the media URLs carry a session key, and the VPN (if any) is system wide.
  /// The app's native client isn't used here, as streaming large videos through it from a
  /// background relay was a crash risk.
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 15);
  final _log = Logger('DlnaProxyRepository');
  final _random = Random.secure();

  HttpServer? _server;
  final _entries = <String, _ProxyEntry>{};
  final _order = <String>[];

  DlnaProxyRepository(this._extraHeaders);

  /// Makes [upstream] available to the renderer at [rendererHost] and returns the URL to give it
  Future<String> publish({
    required Uri upstream,
    required String mimeType,
    required String dlnaFeatures,
    required bool isVideo,
    required String rendererHost,
  }) async {
    return _register(_ProxyEntry(upstream, mimeType, dlnaFeatures, isVideo), rendererHost);
  }

  /// Serves [bytes] (e.g. a zoomed crop rendered on the phone) to the renderer at [rendererHost]
  Future<String> publishBytes({
    required Uint8List bytes,
    required String mimeType,
    required String dlnaFeatures,
    required String rendererHost,
  }) {
    return _register(_ProxyEntry(null, mimeType, dlnaFeatures, false, bytes: bytes), rendererHost);
  }

  /// Downloads [url] fully, following redirects
  Future<Uint8List> fetchBytes(Uri url) async {
    final response = await _open('GET', url).timeout(const Duration(seconds: 30));
    if (response.statusCode >= 400) {
      await response.drain<void>();
      throw HttpException('GET ${url.path} answered ${response.statusCode}', uri: url);
    }
    return _readAll(response);
  }

  static Future<Uint8List> _readAll(Stream<List<int>> stream) =>
      stream.fold<BytesBuilder>(BytesBuilder(copy: false), (b, d) => b..add(d)).then((b) => b.takeBytes());

  Future<String> _register(_ProxyEntry entry, String rendererHost) async {
    final server = _server ??= await _start();
    final address = await _localAddressFor(rendererHost);
    if (address == null) {
      throw const SocketException('No local network address found for the DLNA proxy');
    }

    final token = List.generate(16, (_) => _random.nextInt(16).toRadixString(16)).join();
    _entries[token] = entry;
    _order.add(token);
    // keep a few entries around: TVs re-request media while it's on screen
    while (_order.length > 4) {
      _entries.remove(_order.removeAt(0));
    }

    final extension = _extensionFor(entry.mimeType);
    return 'http://${address.address}:${server.port}/$token/media$extension';
  }

  /// Returns the content type the server answers with for [url], following redirects
  Future<String?> probeContentType(Uri url) async {
    try {
      final response = await _open('HEAD', url).timeout(const Duration(seconds: 15));
      await response.drain<void>();
      if (response.statusCode >= 400) {
        _log.warning('HEAD ${url.path} answered ${response.statusCode}');
        return null;
      }
      return response.headers.contentType?.mimeType.toLowerCase();
    } catch (error) {
      _log.warning('Failed to probe ${url.path}', error);
      return null;
    }
  }

  static void _setDlnaHeaders(HttpResponse response, _ProxyEntry entry) {
    response.headers.contentType = ContentType.parse(entry.mimeType);
    response.headers.set('transferMode.dlna.org', entry.isVideo ? 'Streaming' : 'Interactive');
    response.headers.set('contentFeatures.dlna.org', entry.dlnaFeatures);
  }

  Future<HttpClientResponse> _open(String method, Uri url, {String? range}) async {
    final request = await _client.openUrl(method, url);
    request.followRedirects = true;
    request.maxRedirects = 5;
    // get the bytes exactly as stored, so Content-Length stays valid
    request.headers.removeAll(HttpHeaders.acceptEncodingHeader);
    _extraHeaders().forEach(request.headers.set);
    if (range != null) {
      request.headers.set(HttpHeaders.rangeHeader, range);
    }
    return request.close();
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _entries.clear();
    _order.clear();
    try {
      await server?.close(force: true);
    } catch (error) {
      _log.fine('Failed to close DLNA proxy', error);
    }
  }

  Future<HttpServer> _start() async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    server.autoCompress = false;
    server.listen(
      (request) => unawaited(_handle(request)),
      onError: (Object error, StackTrace stackTrace) => _log.warning('DLNA proxy server error', error, stackTrace),
    );
    _log.info('DLNA proxy listening on port ${server.port}');
    return server;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final segments = request.uri.pathSegments;
      final entry = segments.isEmpty ? null : _entries[segments.first];
      if (entry == null || (request.method != 'GET' && request.method != 'HEAD')) {
        response.statusCode = entry == null ? HttpStatus.notFound : HttpStatus.methodNotAllowed;
        await response.close();
        return;
      }

      final bytes = entry.bytes;
      if (bytes != null) {
        _setDlnaHeaders(response, entry);
        response.statusCode = HttpStatus.ok;
        response.contentLength = bytes.length;
        if (request.method == 'GET') {
          response.add(bytes);
        }
        await response.close();
        return;
      }

      final range = request.headers.value(HttpHeaders.rangeHeader);
      _log.fine('${request.method} from ${request.connectionInfo?.remoteAddress.address} range=$range');

      final upstream = await _open(
        entry.isVideo ? request.method : 'GET',
        entry.upstream!,
        range: entry.isVideo ? range : null,
      );

      if (upstream.statusCode >= 400) {
        _log.warning('Upstream ${entry.upstream!.path} answered ${upstream.statusCode}');
        response.statusCode = upstream.statusCode;
        await upstream.drain<void>();
        await response.close();
        return;
      }

      _setDlnaHeaders(response, entry);

      if (!entry.isVideo) {
        // TVs want a Content-Length for photos, so buffer them (a few MB at most)
        final bytes = await _readAll(upstream);
        response.statusCode = HttpStatus.ok;
        response.contentLength = bytes.length;
        if (request.method == 'GET') {
          response.add(bytes);
        }
        await response.close();
        return;
      }

      response.statusCode = upstream.statusCode;
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      final contentRange = upstream.headers.value(HttpHeaders.contentRangeHeader);
      if (contentRange != null) {
        response.headers.set(HttpHeaders.contentRangeHeader, contentRange);
      }
      final contentLength = upstream.contentLength;
      if (contentLength >= 0) {
        response.contentLength = contentLength;
      }

      if (request.method == 'HEAD') {
        await upstream.drain<void>();
      } else {
        await response.addStream(upstream);
      }
      await response.close();
    } catch (error, stackTrace) {
      // the TV closing the connection mid-stream (seek, stop) also ends up here
      _log.fine('DLNA proxy request failed', error, stackTrace);
      try {
        response.statusCode = HttpStatus.badGateway;
      } catch (_) {
        // headers already sent
      }
      try {
        await response.close();
      } catch (_) {}
    }
  }

  /// Picks the phone's address on the same network as the TV, skipping VPN tunnels
  Future<InternetAddress?> _localAddressFor(String rendererHost) async {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
    final candidates = <InternetAddress>[];
    for (final interface in interfaces) {
      final name = interface.name.toLowerCase();
      if (_vpnInterfacePrefixes.any(name.startsWith)) {
        continue;
      }
      candidates.addAll(interface.addresses.where((a) => !a.isLoopback && !a.isLinkLocal && !_isCgnat(a)));
    }

    final target = InternetAddress.tryParse(rendererHost)?.rawAddress;
    if (target != null && target.length == 4) {
      // longest common prefix wins (same subnet as the TV)
      candidates.sort((a, b) => _commonPrefix(b.rawAddress, target).compareTo(_commonPrefix(a.rawAddress, target)));
    }
    return candidates.firstOrNull;
  }

  static int _commonPrefix(List<int> a, List<int> b) {
    var bits = 0;
    for (var i = 0; i < 4; i++) {
      final diff = a[i] ^ b[i];
      if (diff == 0) {
        bits += 8;
        continue;
      }
      var mask = 0x80;
      while (mask > 0 && (diff & mask) == 0) {
        bits++;
        mask >>= 1;
      }
      break;
    }
    return bits;
  }

  static const _vpnInterfacePrefixes = ['tun', 'tap', 'ppp', 'wg', 'tailscale', 'utun', 'ipsec', 'rmnet', 'ccmni'];

  static bool _isCgnat(InternetAddress address) {
    final bytes = address.rawAddress;
    return bytes.length == 4 && bytes[0] == 100 && (bytes[1] & 0xC0) == 64;
  }

  static String _extensionFor(String mimeType) => switch (mimeType) {
    'image/jpeg' => '.jpg',
    'image/png' => '.png',
    'image/gif' => '.gif',
    'image/webp' => '.webp',
    'video/mp4' => '.mp4',
    'video/quicktime' => '.mov',
    'video/webm' => '.webm',
    'video/x-matroska' => '.mkv',
    _ => '',
  };
}
