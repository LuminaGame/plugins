import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:lumina_plugin_miniai/src/llm/chat_image.dart';

/// The images a tool call returned, as a row of small thumbnails; a click
/// opens one full size.
class ToolImageThumbnails extends StatelessWidget {
  const ToolImageThumbnails({super.key, required this.callId, required this.images, this.height = 72});

  final String callId;
  final List<ChatImage> images;

  /// The thumbnails' height.
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (var n = 0; n < images.length; n++)
          GestureDetector(
            key: ValueKey('miniai_tool_thumb_${callId}_$n'),
            onTap: images[n].kept ? () => showToolImage(context, images[n]) : null,
            child: MouseRegion(
              cursor: images[n].kept ? SystemMouseCursors.zoomIn : MouseCursor.defer,
              child: Container(
                height: height,
                constraints: BoxConstraints(minWidth: height, maxWidth: height * 2.4),
                decoration: BoxDecoration(
                  border: Border.all(color: theme.colorScheme.border),
                  borderRadius: BorderRadius.circular(4),
                ),
                clipBehavior: Clip.antiAlias,
                child: images[n].kept
                    ? Image.memory(images[n].decoded!, height: height, fit: BoxFit.contain, gaplessPlayback: true, filterQuality: FilterQuality.medium)
                    : Padding(
                        padding: const EdgeInsets.all(6),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(LucideIcons.imageOff, size: 14, color: theme.colorScheme.mutedForeground),
                            const SizedBox(height: 4),
                            Text('image no longer kept', style: TextStyle(fontSize: 9, color: theme.colorScheme.mutedForeground)),
                          ],
                        ),
                      ),
              ),
            ),
          ),
      ],
    );
  }
}

/// [image] in a dialog, at most 90 % of the window.
Future<void> showToolImage(BuildContext context, ChatImage image) async {
  final bytes = image.decoded;
  if (bytes == null) return;
  await showOverlay<void>(
    context,
    const DialogConfiguration(),
    builder: (d) {
      final size = MediaQuery.sizeOf(d);
      return AlertDialog(
        key: const ValueKey('miniai_image_dialog'),
        title: Text(image.source ?? 'Tool image', style: const TextStyle(fontSize: 13)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: size.width * 0.9 - 64, maxHeight: size.height * 0.9 - 180),
              child: Image.memory(bytes, fit: BoxFit.contain, filterQuality: FilterQuality.medium),
            ),
            const SizedBox(height: 6),
            Text(image.describe, key: const ValueKey('miniai_image_dialog_size'), style: const TextStyle(fontSize: 10)).muted(),
          ],
        ),
        actions: [
          PrimaryButton(key: const ValueKey('miniai_image_dialog_close'), onPressed: () => closeOverlay(d), child: const Text('Close')),
        ],
      );
    },
  ).future;
}
