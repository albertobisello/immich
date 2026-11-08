import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/models/cast/cast_manager_state.dart';
import 'package:immich_mobile/providers/cast.provider.dart';
import 'package:immich_mobile/services/dlna.service.dart';

class CastDialog extends ConsumerStatefulWidget {
  const CastDialog({super.key});

  @override
  ConsumerState<CastDialog> createState() => _CastDialogState();
}

class _CastDialogState extends ConsumerState<CastDialog> {
  late Future<List<(String, CastDestinationType, dynamic)>> _devices;

  @override
  void initState() {
    super.initState();
    _devices = ref.read(castProvider.notifier).getDevices();
  }

  void _refresh() {
    final notifier = ref.read(castProvider.notifier);
    notifier.clearDiscovered();
    setState(() => _devices = notifier.getDevices());
  }

  Future<void> _addByAddress() async {
    final controller = TextEditingController();
    final address = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.t.cast_add_tv_by_ip),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(hintText: context.t.cast_tv_ip_hint),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text(context.t.cancel)),
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(controller.text), child: Text(context.t.add)),
        ],
      ),
    );
    controller.dispose();

    if (address == null || address.trim().isEmpty || !mounted) {
      return;
    }

    final notifier = ref.read(castProvider.notifier);
    final search = notifier.addManualDevice(address).then((found) {
      if (!found && mounted) {
        context.scaffoldMessenger.showSnackBar(SnackBar(content: Text(context.t.cast_tv_not_found_at_address)));
      }
      return notifier.getDevices();
    });
    setState(() => _devices = search);
  }

  @override
  Widget build(BuildContext context) {
    final castManager = ref.watch(castProvider);

    bool isCurrentDevice(String deviceName) {
      return castManager.receiverName == deviceName && castManager.isCasting;
    }

    bool isDeviceConnecting(String deviceName) {
      return castManager.receiverName == deviceName && !castManager.isCasting;
    }

    return AlertDialog(
      title: Row(
        children: [
          Expanded(
            child: Text(context.t.cast, style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          IconButton(icon: const Icon(Icons.refresh), tooltip: context.t.refresh, onPressed: _refresh),
        ],
      ),
      content: SizedBox(
        width: 250,
        height: 250,
        child: FutureBuilder<List<(String, CastDestinationType, dynamic)>>(
          future: _devices,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Text(context.t.error_saving_image(error: snapshot.error.toString()));
            } else if (snapshot.connectionState != ConnectionState.done || !snapshot.hasData) {
              return const SizedBox(height: 48, child: Center(child: CircularProgressIndicator()));
            }

            final vpnWarning = DlnaService.isCastEndpointVpnOnly()
                ? Padding(
                    padding: const EdgeInsets.only(top: 12.0),
                    child: Text(
                      context.t.cast_server_vpn_warning,
                      style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.error),
                    ),
                  )
                : null;

            if (snapshot.data!.isEmpty) {
              return SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [Text(context.t.no_cast_devices_found), ?vpnWarning],
                ),
              );
            }

            final devices = snapshot.data!;
            final connected = devices.where((d) => isCurrentDevice(d.$1)).toList();
            final others = devices.where((d) => !isCurrentDevice(d.$1)).toList();

            final List<dynamic> sectionedList = [];

            if (connected.isNotEmpty) {
              sectionedList.add(context.t.connected_device);
              sectionedList.addAll(connected);
            }

            if (others.isNotEmpty) {
              sectionedList.add(context.t.discovered_devices);
              sectionedList.addAll(others);
            }

            if (vpnWarning != null) {
              sectionedList.add(vpnWarning);
            }

            return ListView.builder(
              shrinkWrap: true,
              itemCount: sectionedList.length,
              itemBuilder: (context, index) {
                final item = sectionedList[index];

                if (item is Widget) {
                  return item;
                } else if (item is String) {
                  // It's a section header
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8.0),
                    child: Text(item, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  );
                } else {
                  final (deviceName, type, deviceObj) = item as (String, CastDestinationType, dynamic);

                  return ListTile(
                    title: Text(
                      deviceName,
                      style: TextStyle(color: isCurrentDevice(deviceName) ? context.colorScheme.primary : null),
                    ),
                    leading: Icon(
                      type == CastDestinationType.googleCast ? Icons.cast : Icons.tv,
                      color: isCurrentDevice(deviceName) ? context.colorScheme.primary : null,
                    ),
                    trailing: isCurrentDevice(deviceName)
                        ? Icon(Icons.check, color: context.colorScheme.primary)
                        : isDeviceConnecting(deviceName)
                        ? const CircularProgressIndicator()
                        : null,
                    onTap: () async {
                      if (isDeviceConnecting(deviceName)) {
                        return;
                      }

                      if (castManager.isCasting) {
                        await ref.read(castProvider.notifier).disconnect();
                      }

                      if (!isCurrentDevice(deviceName)) {
                        unawaited(ref.read(castProvider.notifier).connect(type, deviceObj));
                      }
                    },
                  );
                }
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: _addByAddress,
          child: Text(context.t.cast_add_tv_by_ip, style: TextStyle(color: context.colorScheme.primary)),
        ),
        if (castManager.isCasting)
          TextButton(
            onPressed: () => ref.read(castProvider.notifier).disconnect(),
            child: Text(
              context.t.stop_casting,
              style: TextStyle(color: context.colorScheme.secondary, fontWeight: FontWeight.bold),
            ),
          ),
        TextButton(
          onPressed: () => context.pop(),
          child: Text(
            context.t.close,
            style: TextStyle(color: context.colorScheme.primary, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}
