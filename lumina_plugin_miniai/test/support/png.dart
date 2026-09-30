import 'dart:typed_data';
import 'dart:ui' as ui;

/// A real PNG of [width]×[height], drawn and encoded by the engine (two
/// coloured halves, so a thumbnail shows something).
Future<Uint8List> renderPng(int width, int height, {ui.Color left = const ui.Color(0xFF2E7DD7), ui.Color right = const ui.Color(0xFFE0A030)}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(ui.Rect.fromLTWH(0, 0, width / 2, height.toDouble()), ui.Paint()..color = left);
  canvas.drawRect(ui.Rect.fromLTWH(width / 2, 0, width / 2, height.toDouble()), ui.Paint()..color = right);
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}
