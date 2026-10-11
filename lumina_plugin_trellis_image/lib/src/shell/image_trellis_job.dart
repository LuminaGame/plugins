import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';

/// Long-running Trellis work uses start/events/save, rather than a blocking MCP call.
class ImageTrellisJob {
  ImageTrellisJob(this.image, this.trellis, this.notify);
  final PluginProcessChannel image, trellis;
  final VoidCallback notify;
  bool busy = false, cancelled = false;
  bool _ownsGeneration = false;
  String status = '', error = '';
  Future<void> run(String draftId) async {
    if (busy) return;
    busy = true;
    cancelled = false;
    _ownsGeneration = false;
    error = '';
    status = 'Checking approved image';
    notify();
    var approved = false;
    StreamSubscription<PluginProcessEvent>? events;
    VoidCallback? processState;
    Map<String, Object?>? saved;
    try {
      if (!trellis.state.value.isAvailable) {
        throw StateError(
          'Enable Trellis 3D and restart its plugin process first.',
        );
      }
      final existing = await trellis.call('trellis.state');
      if (existing is Map && existing['generating'] == true) {
        throw StateError('Trellis is already generating another mesh.');
      }
      final reply = await image.call('image.approve3d', {'draftId': draftId});
      if (reply is! Map || reply['approvedImage'] is! String) {
        throw StateError('Image approval failed.');
      }
      approved = true;
      if (cancelled) throw StateError('Cancelled');
      final done = Completer<Map<String, Object?>>();
      done.future.ignore();
      var started = false;
      events = trellis.events('state').listen((event) {
        if (event.data is! Map) return;
        final data = Map<String, Object?>.from(event.data as Map);
        started = started || data['generating'] == true;
        final progress = data['progress'];
        status = progress is Map
            ? 'Trellis: ${progress['stage_name'] ?? progress['stage']} ${progress['step'] ?? ''}'
            : 'Generating Trellis 3D';
        notify();
        if (started && data['generating'] == false && !done.isCompleted) {
          done.complete(data);
        }
      });
      processState = () {
        if (!trellis.state.value.isAvailable && !done.isCompleted) {
          done.completeError(
            StateError('Trellis process stopped. Restart it and retry.'),
          );
        }
      };
      trellis.state.addListener(processState);
      await trellis.call('trellis.generate', {
        'image_path': reply['approvedImage'],
        if (existing is Map && existing['config'] is Map) ...{
          'quality': (existing['config'] as Map)['default_quality'],
          'bg_mode': (existing['config'] as Map)['default_background_mode'],
          'steps': (existing['config'] as Map)['default_steps'],
          'guidance': (existing['config'] as Map)['default_guidance'],
          'texture': (existing['config'] as Map)['default_texture_enabled'],
          'texture_steps': (existing['config'] as Map)['default_texture_steps'],
        },
      });
      _ownsGeneration = true;
      if (cancelled) await trellis.call('trellis.cancel');
      final complete = await done.future.timeout(const Duration(minutes: 30));
      _ownsGeneration = false;
      if (cancelled) throw StateError('Cancelled');
      final mesh = complete['result'];
      if (mesh is! Map ||
          mesh['success'] != true ||
          mesh['glb_path'] is! String) {
        throw StateError(
          mesh is Map
              ? '${mesh['error'] ?? '3D generation failed'}'
              : '3D generation failed',
        );
      }
      status = 'Saving generated mesh';
      notify();
      final response = await trellis.call('trellis.save', {
        'glb_path': mesh['glb_path'],
        'asset_name': 'Qwen_${DateTime.now().millisecondsSinceEpoch}',
      }, const Duration(minutes: 5));
      if (response is! Map || response['asset_path'] is! String) {
        throw StateError('Trellis did not return a saved project asset.');
      }
      saved = {
        'asset_path': response['asset_path'],
        'glb_path': mesh['glb_path'],
      };
    } catch (e) {
      error = '$e';
      if (_ownsGeneration && trellis.state.value.isAvailable) {
        try {
          await trellis.call('trellis.cancel');
        } catch (_) {
          // Preserve the original generation failure.
        }
      }
    } finally {
      _ownsGeneration = false;
      await events?.cancel();
      if (processState != null) trellis.state.removeListener(processState);
      if (approved) {
        try {
          await image.call('image.finish3d', {
            'draftId': draftId,
            'result': saved,
            'error': saved == null ? error : null,
          });
        } catch (e) {
          error = '$e';
        }
      }
      busy = false;
      notify();
    }
  }

  Future<void> cancel() async {
    cancelled = true;
    if (!_ownsGeneration) return;
    try {
      await trellis.call('trellis.cancel');
    } catch (e) {
      error = '$e';
      notify();
    }
  }
}
