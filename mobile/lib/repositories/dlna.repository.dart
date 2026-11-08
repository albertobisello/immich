import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:xml/xml.dart';

final dlnaRepositoryProvider = Provider((_) => DlnaRepository());

/// A UPnP/DLNA media renderer (e.g. an LG webOS TV, Samsung, Sony, Kodi...)
class DlnaDevice {
  final String name;
  final String udn;
  final Uri location;
  final Uri avTransportControlUrl;
  final String avTransportServiceType;

  const DlnaDevice({
    required this.name,
    required this.udn,
    required this.location,
    required this.avTransportControlUrl,
    required this.avTransportServiceType,
  });
}

class DlnaSoapException implements Exception {
  final String action;
  final int statusCode;
  final String body;

  const DlnaSoapException(this.action, this.statusCode, this.body);

  @override
  String toString() => 'DlnaSoapException($action, $statusCode): $body';
}

/// Low level UPnP AV client: SSDP discovery and AVTransport SOAP actions
class DlnaRepository {
  static const _ssdpAddress = '239.255.255.250';
  static const _ssdpPort = 1900;
  static const _searchTargets = [
    'urn:schemas-upnp-org:device:MediaRenderer:1',
    'urn:schemas-upnp-org:service:AVTransport:1',
  ];
  static const _requestTimeout = Duration(seconds: 5);

  final _log = Logger('DlnaRepository');
  final http.Client _client = http.Client();

  /// Discovers media renderers on the local network.
  ///
  /// [extraHosts] are addresses entered by the user: they are queried with a unicast M-SEARCH,
  /// which also works when multicast doesn't (mesh repeaters, VPNs, routed subnets). An entry
  /// can also be the full URL of the device description (`http://...`).
  Future<List<DlnaDevice>> listDestinations({
    Duration timeout = const Duration(seconds: 3),
    Iterable<String> extraHosts = const [],
  }) async {
    final locations = <String>{};
    final sockets = <RawDatagramSocket>[];

    for (final host in extraHosts) {
      if (host.startsWith('http://') || host.startsWith('https://')) {
        locations.add(host);
      }
    }

    try {
      // A socket per Wi-Fi/Ethernet interface: with a VPN (e.g. Tailscale) active, the default
      // multicast route can point to the VPN tunnel, where SSDP packets are silently dropped.
      final interfaces = await _lanInterfaces();
      for (final address in interfaces) {
        final socket = await _openSocket(address, locations);
        if (socket != null) {
          sockets.add(socket);
        }
      }
      // Fallback socket using the system's default route
      final defaultSocket = await _openSocket(null, locations);
      if (defaultSocket != null) {
        sockets.add(defaultSocket);
      }

      final unicastTargets = <InternetAddress>[];
      for (final host in extraHosts) {
        if (host.startsWith('http://') || host.startsWith('https://')) {
          continue;
        }
        final address =
            InternetAddress.tryParse(host) ??
            (await InternetAddress.lookup(host).catchError((_) => <InternetAddress>[])).firstOrNull;
        if (address != null && address.type == InternetAddressType.IPv4) {
          unicastTargets.add(address);
        }
      }

      final multicast = InternetAddress(_ssdpAddress);
      // UDP is unreliable, send each search a few times
      for (var i = 0; i < 3; i++) {
        for (final st in _searchTargets) {
          for (final socket in sockets) {
            _send(socket, multicast, '$_ssdpAddress:$_ssdpPort', st);
          }
          for (final target in sockets.isEmpty ? const <InternetAddress>[] : unicastTargets) {
            _send(sockets.last, target, '${target.address}:$_ssdpPort', st);
          }
        }
        await Future.delayed(const Duration(milliseconds: 300));
      }

      await Future.delayed(timeout);
    } catch (error, stackTrace) {
      _log.warning('SSDP discovery failed', error, stackTrace);
    } finally {
      for (final socket in sockets) {
        socket.close();
      }
    }

    _log.info('SSDP discovery found ${locations.length} UPnP device description(s)');

    final devices = await Future.wait(locations.map(_fetchDevice));
    final byUdn = <String, DlnaDevice>{};
    for (final device in devices.whereType<DlnaDevice>()) {
      byUdn.putIfAbsent(device.udn, () => device);
    }
    _log.info('Found ${byUdn.length} DLNA media renderer(s): ${byUdn.values.map((d) => d.name).join(', ')}');
    return byUdn.values.toList(growable: false);
  }

  /// IPv4 addresses of the local network interfaces, skipping VPN tunnels
  Future<List<InternetAddress>> _lanInterfaces() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      final result = <InternetAddress>[];
      for (final interface in interfaces) {
        final name = interface.name.toLowerCase();
        if (_vpnInterfacePrefixes.any(name.startsWith)) {
          continue;
        }
        for (final address in interface.addresses) {
          if (!address.isLoopback && !address.isLinkLocal && !_isCgnat(address)) {
            result.add(address);
          }
        }
      }
      _log.fine('SSDP interfaces: ${result.map((a) => a.address).join(', ')}');
      return result;
    } catch (error) {
      _log.fine('Failed to list network interfaces', error);
      return const [];
    }
  }

  static const _vpnInterfacePrefixes = ['tun', 'tap', 'ppp', 'wg', 'tailscale', 'utun', 'ipsec', 'rmnet', 'ccmni'];

  /// Tailscale uses 100.64.0.0/10
  static bool _isCgnat(InternetAddress address) {
    final bytes = address.rawAddress;
    return bytes.length == 4 && bytes[0] == 100 && (bytes[1] & 0xC0) == 64;
  }

  Future<RawDatagramSocket?> _openSocket(InternetAddress? interfaceAddress, Set<String> locations) async {
    try {
      final socket = await RawDatagramSocket.bind(interfaceAddress ?? InternetAddress.anyIPv4, 0);
      socket.multicastHops = 4;
      if (interfaceAddress != null) {
        try {
          socket.setRawOption(
            RawSocketOption(
              RawSocketOption.levelIPv4,
              RawSocketOption.IPv4MulticastInterface,
              interfaceAddress.rawAddress,
            ),
          );
        } catch (error) {
          _log.fine('Failed to set multicast interface ${interfaceAddress.address}', error);
        }
      }

      socket.listen((event) {
        if (event != RawSocketEvent.read) {
          return;
        }
        final datagram = socket.receive();
        if (datagram == null) {
          return;
        }
        final location = _parseLocation(utf8.decode(datagram.data, allowMalformed: true));
        if (location != null) {
          locations.add(location);
        }
      });
      return socket;
    } catch (error) {
      _log.fine('Failed to open SSDP socket on ${interfaceAddress?.address ?? 'default route'}', error);
      return null;
    }
  }

  void _send(RawDatagramSocket socket, InternetAddress destination, String host, String st) {
    final message =
        'M-SEARCH * HTTP/1.1\r\n'
        'HOST: $host\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 2\r\n'
        'ST: $st\r\n'
        'USER-AGENT: Android UPnP/1.1 Immich/1.0\r\n'
        '\r\n';
    try {
      socket.send(utf8.encode(message), destination, _ssdpPort);
    } catch (error) {
      _log.fine('Failed to send M-SEARCH to ${destination.address}', error);
    }
  }

  String? _parseLocation(String response) {
    for (final line in const LineSplitter().convert(response)) {
      final separator = line.indexOf(':');
      if (separator <= 0) {
        continue;
      }
      if (line.substring(0, separator).trim().toLowerCase() == 'location') {
        final value = line.substring(separator + 1).trim();
        return value.isEmpty ? null : value;
      }
    }
    return null;
  }

  Future<DlnaDevice?> _fetchDevice(String locationString) async {
    try {
      final location = Uri.parse(locationString);
      final response = await _client.get(location).timeout(_requestTimeout);
      if (response.statusCode != 200) {
        return null;
      }

      final document = XmlDocument.parse(utf8.decode(response.bodyBytes, allowMalformed: true));
      final urlBase = _firstText(document, 'URLBase');
      final baseUri = urlBase != null && urlBase.isNotEmpty ? Uri.parse(urlBase) : location;

      for (final device in document.findAllElements('device', namespaceUri: '*')) {
        final deviceType = _childText(device, 'deviceType') ?? '';
        final service = device
            .findElements('serviceList', namespaceUri: '*')
            .expand((list) => list.findElements('service', namespaceUri: '*'))
            .where((s) => (_childText(s, 'serviceType') ?? '').contains(':service:AVTransport:'))
            .firstOrNull;

        if (service == null || !deviceType.contains('MediaRenderer')) {
          continue;
        }

        final controlUrl = _childText(service, 'controlURL');
        if (controlUrl == null) {
          continue;
        }

        return DlnaDevice(
          name: _childText(device, 'friendlyName') ?? location.host,
          udn: _childText(device, 'UDN') ?? locationString,
          location: location,
          avTransportControlUrl: baseUri.resolve(controlUrl),
          avTransportServiceType: _childText(service, 'serviceType')!,
        );
      }
    } catch (error, stackTrace) {
      _log.fine('Failed to read UPnP device description at $locationString', error, stackTrace);
    }
    return null;
  }

  String? _firstText(XmlNode node, String name) =>
      node.findAllElements(name, namespaceUri: '*').firstOrNull?.innerText.trim();

  String? _childText(XmlElement node, String name) =>
      node.findElements(name, namespaceUri: '*').firstOrNull?.innerText.trim();

  /// Sends an AVTransport action and returns the child elements of the response as a map
  Future<Map<String, String>> sendAction(
    DlnaDevice device,
    String action, [
    Map<String, String> arguments = const {},
  ]) async {
    final serviceType = device.avTransportServiceType;
    final args = {
      'InstanceID': '0',
      ...arguments,
    }.entries.map((e) => '<${e.key}>${_escape(e.value)}</${e.key}>').join();

    final body =
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body><u:$action xmlns:u="$serviceType">$args</u:$action></s:Body>'
        '</s:Envelope>';

    final response = await _client
        .post(
          device.avTransportControlUrl,
          headers: {'Content-Type': 'text/xml; charset="utf-8"', 'SOAPACTION': '"$serviceType#$action"'},
          body: utf8.encode(body),
        )
        .timeout(_requestTimeout);

    final responseBody = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (response.statusCode != 200) {
      throw DlnaSoapException(action, response.statusCode, responseBody);
    }

    final result = <String, String>{};
    try {
      final document = XmlDocument.parse(responseBody);
      final actionResponse = document.findAllElements('${action}Response', namespaceUri: '*').firstOrNull;
      for (final element in actionResponse?.childElements ?? const <XmlElement>[]) {
        result[element.localName] = element.innerText;
      }
    } catch (_) {
      // some renderers return malformed bodies for actions without output
    }
    return result;
  }

  /// Makes a HEAD request to detect the content type the server will return for [url]
  Future<String?> getContentType(String url) async {
    try {
      final response = await _client.head(Uri.parse(url)).timeout(_requestTimeout);
      if (response.statusCode >= 400) {
        return null;
      }
      return response.headers['content-type']?.split(';').first.trim();
    } catch (_) {
      return null;
    }
  }

  static String _escape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  static String escapeXml(String value) => _escape(value);
}
