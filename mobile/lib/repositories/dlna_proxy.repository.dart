import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:logging/logging.dart';

final dlnaProxyRepositoryProvider = Provider((ref) {
  final proxy = DlnaProxyRepository(() => NetworkRepository.client);
  ref.onDispose(() => unawaited(proxy.stop()));
  return proxy;
});

class _ProxyEntry {
  final Uri upstream;
  final String mimeType;
  final String dlnaFeatures;
  final bool isVideo;

  const _ProxyEntry(this.upstream, this.mimeType, this.dlnaFeatures, this.isVideo);
}

/// A tiny HTTP server on the phone that relays media from the Immich server to a DLNA TV.
///
/// TVs often can't load media straight from the server: the server may only be reachable
/// through the phone's VPN (e.g. Tailscale), need custom headers, or answer with redirects,
/// which many renderers (LG included) don't follow. The phone fetches the media the same way
/// the app does and serves it on the local network with the headers DLNA renderers expect.
class DlnaProxyRepository {
  final http.Client Function() _clientFactory;
  final _log = Logger('DlnaProxyRepository');
  final _random = Random.secure();

  HttpServer? _server;
  final _entries = <String, _ProxyEntry>{};
  final _order = <String>[];

  DlnaProxyRepository(this._clientFactory);

  /// Makes [upstream] available to the renderer at [rendererHost] and returns the URL to give it
  Future<String> publish({
    required Uri upstream,
    required String mimeType,
    required String dlnaFeatures,
    required bool isVideo,
    required String rendererHost,
  }) async {
    final server = _server ??= await _start();
    final address = await _localAddressFor(rendererHost);
    if (address == null) {
      throw const SocketException('No local network address found for the DLNA proxy');
    }

    final token = List.generate(16, (_) => _random.nextInt(16).toRadixString(16)).join();
    _entries[token] = _ProxyEntry(upstream, mimeType, dlnaFeatures, isVideo);
    _order.add(token);
    // keep a few entries around: TVs re-request media while it's on screen
    while (_order.length > 4) {
      _entries.remove(_order.removeAt(0));
    }

    final extension = _extensionFor(mimeType);
    return 'http://${address.address}:${server.port}/$token/media$extension';
  }

  /// Returns the content type the server answers with for [url], following redirects
  Future<String?> probeContentType(Uri url) async {
    try {
      final request = http.Request('HEAD', url)
        ..followRedirects = true
        ..maxRedirects = 5;
      final response = await _clientFactory().send(request).timeout(const Duration(seconds: 10));
      await response.stream.drain<void>();
      if (response.statusCode >= 400) {
        _log.warning('HEAD ${url.path} answered ${response.statusCode}');
        return null;
      }
      return response.headers['content-type']?.split(';').first.trim().toLowerCase();
    } catch (error) {
      _log.warning('Failed to probe ${url.path}', error);
      return null;
    }
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _entries.clear();
    _order.clear();
    await server?.close(force: true);
  }

  Future<HttpServer> _start() async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    server.autoCompress = false;
    server.listen((request) => unawaited(_handle(request)));
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

      final range = request.headers.value(HttpHeaders.rangeHeader);
      _log.fine('${request.method} from ${request.connectionInfo?.remoteAddress.address} range=$range');

      final upstreamRequest = http.Request(entry.isVideo ? request.method : 'GET', entry.upstream)
        ..followRedirects = true
        ..maxRedirects = 5;
      if (range != null && entry.isVideo) {
        upstreamRequest.headers[HttpHeaders.rangeHeader] = range;
      }
      final upstream = await _clientFactory().send(upstreamRequest);

      if (upstream.statusCode >= 400) {
        _log.warning('Upstream ${entry.upstream.path} answered ${upstream.statusCode}');
        response.statusCode = upstream.statusCode;
        await upstream.stream.drain<void>();
        await response.close();
        return;
      }

      response.headers.contentType = ContentType.parse(entry.mimeType);
      response.headers.set('transferMode.dlna.org', entry.isVideo ? 'Streaming' : 'Interactive');
      response.headers.set('contentFeatures.dlna.org', entry.dlnaFeatures);

      if (!entry.isVideo) {
        // TVs want a Content-Length for photos, so buffer them (a few MB at most)
        final bytes = await upstream.stream.toBytes();
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
      final contentRange = upstream.headers[HttpHeaders.contentRangeHeader];
      if (contentRange != null) {
        response.headers.set(HttpHeaders.contentRangeHeader, contentRange);
      }
      final contentLength = upstream.contentLength;
      if (contentLength != null && contentLength >= 0) {
        response.contentLength = contentLength;
      }

      if (request.method == 'HEAD') {
        await upstream.stream.drain<void>();
      } else {
        await response.addStream(upstream.stream);
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
