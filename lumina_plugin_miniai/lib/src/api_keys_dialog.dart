import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:lumina_plugin_miniai/src/settings/provider_settings.dart';

/// Plugins ▸ MiniAI ▸ API Keys…: every provider's key source and
/// the stored keys, masked, with Remove.
Future<void> showApiKeysDialog(BuildContext context, ProviderSettings settings) async {
  await showOverlay<void>(
    context,
    const DialogConfiguration(),
    builder: (dialog) => ApiKeysDialog(settings: settings, close: () => closeOverlay(dialog)),
  ).future;
}

class ApiKeysDialog extends StatelessWidget {
  const ApiKeysDialog({super.key, required this.settings, required this.close});

  final ProviderSettings settings;
  final VoidCallback close;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.mutedForeground;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final stored = {for (final (id, masked) in settings.storedKeys) id: masked};
        final rows = [
          for (final p in settings.providers) (p.id, p.name, settings.keySource(p)),
          // A key whose provider was removed still sits in the store.
          for (final id in stored.keys)
            if (!settings.providers.any((p) => p.id == id)) (id, id, 'stored'),
        ];
        return AlertDialog(
          title: const Text('API Keys'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Keys stay in MiniAI\'s own credentials file on this computer. They never go into the project, a chat or the log. '
                  'An environment variable wins over a stored key.',
                  style: TextStyle(fontSize: 11, color: muted),
                ),
                const SizedBox(height: 12),
                if (rows.isEmpty) Text('No model providers yet.', style: TextStyle(fontSize: 11, color: muted)),
                for (final (id, name, source) in rows)
                  Padding(
                    key: ValueKey('miniai_key_row_$id'),
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Expanded(child: Text(name, style: const TextStyle(fontSize: 12))),
                        SizedBox(
                          width: 200,
                          child: Text(
                            switch (source) {
                              null => 'No key',
                              'stored' => 'Stored · ${stored[id] ?? ''}',
                              final env => 'Environment ($env)',
                            },
                            key: ValueKey('miniai_key_source_$id'),
                            style: TextStyle(fontSize: 11, color: source == null ? muted : null),
                          ),
                        ),
                        SizedBox(
                          width: 90,
                          child: stored.containsKey(id)
                              ? OutlineButton(
                                  key: ValueKey('miniai_key_remove_$id'),
                                  density: ButtonDensity.compact,
                                  onPressed: () => settings.removeKey(id),
                                  child: const Text('Remove'),
                                )
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          actions: [PrimaryButton(onPressed: close, child: const Text('Close'))],
        );
      },
    );
  }
}
