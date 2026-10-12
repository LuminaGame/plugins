import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_trellis_image/src/shell/mesh_preview.dart';

/// Long-running Trellis work uses start/events, rather than a blocking MCP
/// call. A generated mesh stays in the Trellis plugin's temp folder as a
/// [MeshPreview]: it is inspected, simplified and reverted there, and
/// written into the project only by [save].
class ImageTrellisJob {
  ImageTrellisJob(this.image, this.trellis, this.notify);
  final PluginProcessChannel image, trellis;
  final VoidCallback notify;
  bool busy = false, cancelled = false;
  bool _ownsGeneration = false;
  String status = '', error = '';

  /// The mesh under review; null before a generation and after Discard.
  MeshPreview? preview;

  /// A preview call (simplify, save, discard) is running.
  bool working = false;

  /// The approved draft the preview was generated from (for Regenerate).
  String? lastDraftId;

  /// Simplification applied right after generation (triangles; null: none).
  int? generationTargetTriangles;

  Future<void> run(String draftId) async {
    if (busy) return;
    busy = true;
    cancelled = false;
    _ownsGeneration = false;
    error = '';
    // A new generation replaces a preview that was not discarded.
    final old = preview;
    preview = null;
    if (old != null) unawaited(_discardQuietly(old));
    status = 'Checking approved image';
    notify();
    var approved = false;
    StreamSubscription<PluginProcessEvent>? events;
    VoidCallback? processState;
    Map<String, Object?>? generated;
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
      lastDraftId = draftId;
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
      final config = existing is Map && existing['config'] is Map
          ? existing['config'] as Map
          : const {};
      await trellis.call('trellis.generate', {
        'image_path': reply['approvedImage'],
        if (config.isNotEmpty) ...{
          'quality': config['default_quality'],
          'bg_mode': config['default_background_mode'],
          'steps': config['default_steps'],
          'guidance': config['default_guidance'],
          'texture': config['default_texture_enabled'],
          'texture_steps': config['default_texture_steps'],
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
      status = 'Reading the generated mesh';
      notify();
      final glb = mesh['glb_path'] as String;
      preview = MeshPreview(sourcePath: glb, stats: await _inspect(glb));
      generated = {'glb_path': glb};
      final target = generationTargetTriangles;
      if (target != null && target < preview!.stats.triangles) {
        status = 'Simplifying to ${MeshStats.count(target)} triangles';
        notify();
        preview!.simplified = await _simplify(glb, {
          'target_triangles': target,
        });
      }
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
            'result': generated,
            'error': generated == null ? error : null,
          });
        } catch (e) {
          error = '$e';
        }
      }
      busy = false;
      if (preview != null && error.isEmpty) {
        status = 'Review the 3D model, then save it to the project';
      }
      notify();
    }
  }

  /// Reviews an existing Trellis output (a GLB in the Trellis plugin's
  /// temp folder) as if it had just been generated; Regenerate stays off.
  /// Discard deletes its temp folder.
  Future<void> review(String glbPath) async {
    if (busy || working) return;
    final old = preview;
    preview = null;
    lastDraftId = null;
    if (old != null) unawaited(_discardQuietly(old));
    working = true;
    error = '';
    status = 'Reading the mesh';
    notify();
    try {
      // Trellis prepares it for the editor's loaders (a converted copy in
      // its temp folder when the file needs one).
      final opened = await trellis.call('trellis.openGlb', {'path': glbPath});
      final result = opened is Map ? opened['result'] : null;
      final path = result is Map && result['glb_path'] is String
          ? result['glb_path'] as String
          : glbPath;
      preview = MeshPreview(sourcePath: path, stats: await _inspect(path));
      status = 'Review the 3D model, then save it to the project';
    } catch (e) {
      error = '$e';
    } finally {
      working = false;
      notify();
    }
  }

  Future<MeshStats> _inspect(String glb) async {
    final r = await trellis.call('trellis.inspect', {
      'glb_path': glb,
    }, const Duration(minutes: 2));
    return MeshStats.fromJson((r as Map).cast<String, Object?>());
  }

  Future<MeshSimplification> _simplify(
    String glb,
    Map<String, Object?> target,
  ) async {
    final r = await trellis.call('trellis.simplify', {
      'glb_path': glb,
      ...target,
    }, const Duration(minutes: 5));
    return MeshSimplification.fromJson((r as Map).cast<String, Object?>());
  }

  /// Runs [action] as the one preview call at a time, showing its error.
  Future<void> _work(
    String what,
    Future<void> Function(MeshPreview p) action,
  ) async {
    final p = preview;
    if (p == null || working || busy) return;
    working = true;
    error = '';
    status = what;
    notify();
    try {
      await action(p);
    } catch (e) {
      error = '$e';
    } finally {
      working = false;
      notify();
    }
  }

  /// Simplifies the generated mesh (always from the original, so a second
  /// Apply does not compound) to [ratio] of its triangles or [triangles].
  Future<void> simplify({
    double? ratio,
    int? triangles,
  }) => _work('Simplifying', (p) async {
    final s = await _simplify(p.sourcePath, {
      'ratio': ?ratio,
      'target_triangles': ?triangles,
    });
    if (!identical(preview, p)) return;
    p.simplified = s;
    status =
        'Simplified: ${MeshStats.count(s.before.triangles)} → ${MeshStats.count(s.after.triangles)} triangles '
        '(${(s.durationMs / 1000).toStringAsFixed(1)} s)';
  });

  /// Shows the generated mesh again (the simplified copy stays on disk
  /// until Discard).
  void revert() {
    final p = preview;
    if (p == null || working || p.simplified == null) return;
    p.simplified = null;
    status = 'Reverted to the generated mesh';
    notify();
  }

  /// Writes the shown mesh into the project as `<folder>/<name>`
  /// (`.glb`, `.entity.glb`, `.lmas`).
  Future<void> save({required String name, required String folder}) =>
      _work('Saving to the project', (p) async {
        final r = await trellis.call('trellis.save', {
          'glb_path': p.shownPath,
          'asset_name': name,
          'folder': folder,
        }, const Duration(minutes: 5));
        if (r is! Map || r['asset_path'] is! String) {
          throw StateError('Trellis did not return a saved project asset.');
        }
        p.savedAssetPath = r['asset_path'] as String;
        status = 'Saved ${p.savedAssetPath}';
        final draft = lastDraftId;
        if (draft != null) {
          try {
            await image.call('image.saved3d', {
              'draftId': draft,
              'asset_path': p.savedAssetPath,
              'glb_path': p.shownPath,
            });
          } catch (_) {
            // A newer draft replaced it; the asset is saved all the same.
          }
        }
      });

  /// Deletes the preview's temp files; nothing in the project changes.
  Future<void> discard() => _work('Discarding', (p) async {
    await trellis.call('trellis.discard', {'glb_path': p.sourcePath});
    preview = null;
    status = 'Discarded the generated mesh';
  });

  /// Discards the preview and generates again from the same approved image.
  Future<void> regenerate() async {
    final draft = lastDraftId;
    if (draft == null || busy || working) return;
    if (preview != null) await discard();
    if (preview != null) return; // the discard failed; its error shows
    await run(draft);
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

  /// Removes an unsaved preview's temp files (the tab's plugin unloads).
  Future<void> dispose() async {
    final p = preview;
    preview = null;
    if (p != null) await _discardQuietly(p);
  }

  Future<void> _discardQuietly(MeshPreview p) async {
    if (!trellis.state.value.isAvailable) return;
    try {
      await trellis.call('trellis.discard', {'glb_path': p.sourcePath});
    } catch (_) {
      // The Trellis process removes its temp folders when it ends.
    }
  }
}
