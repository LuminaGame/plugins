import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_trellis_image/src/shell/image_trellis_job.dart';

class ImageClient extends ChangeNotifier {
  ImageClient(this.channel, {PluginProcessChannel? trellis}) {
    job = trellis == null
        ? null
        : ImageTrellisJob(channel, trellis, () {
            if (!disposed) notifyListeners();
          });
    _events = channel.events('image.state').listen((event) {
      if (event.data is Map) {
        _apply(Map<String, Object?>.from(event.data as Map));
      }
    });
    channel.state.addListener(_processChanged);
  }
  final PluginProcessChannel channel;
  late final ImageTrellisJob? job;
  late StreamSubscription<PluginProcessEvent> _events;
  Map<String, Object?> state = {};
  bool disposed = false;
  String? callError;
  bool get busy => state['busy'] == true || job?.busy == true;
  bool get canCancel => state['cancellable'] == true || job?.busy == true;
  String? get draft => state['draft'] as String?;
  String? get draftId => state['draftId'] as String?;
  String? get error => job?.error.isNotEmpty == true
      ? job!.error
      : callError ?? state['error'] as String?;
  String get status =>
      job?.busy == true || job?.working == true || job?.preview != null
      ? job!.status
      : state['status'] as String? ?? 'Connecting to image plugin…';
  Future<void> approve3d() async {
    if (busy || draftId == null) return;
    if (job == null) {
      callError = 'Enable Trellis 3D and restart first.';
      notifyListeners();
      return;
    }
    await job!.run(draftId!);
  }

  Future<void> cancel() async {
    if (job?.busy == true) {
      await job!.cancel();
    } else {
      await call('image.cancel');
    }
  }

  void _apply(Map<String, Object?> value) {
    if (disposed) return;
    state = value;
    notifyListeners();
  }

  void _processChanged() {
    if (channel.state.value.isAvailable) unawaited(call('image.state'));
  }

  Future<void> call(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    try {
      callError = null;
      if (job?.busy != true) job?.error = '';
      final response = await channel.call(method, args);
      if (response is Map) _apply(Map<String, Object?>.from(response));
    } catch (e) {
      if (!disposed) {
        callError = '$e';
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    disposed = true;
    unawaited(job?.dispose());
    unawaited(_events.cancel());
    channel.state.removeListener(_processChanged);
    super.dispose();
  }
}
