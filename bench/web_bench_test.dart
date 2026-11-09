import 'dart:math';
import 'package:image/image.dart' as img;
import 'package:rapid_image/rapid_image.dart' as rapid;
import 'package:test/test.dart';

void main() {
  test('web bench', () async {
    await rapid.ensureRapidArchiveInitialized();
    final r = Random(1);
    final im = img.Image(width: 2000, height: 1500);
    for (final p in im) {
      final n = r.nextInt(12);
      p
        ..r = (p.x * 255 ~/ 2000 + n) & 255
        ..g = (p.y * 255 ~/ 1500 + n) & 255
        ..b = ((p.x + p.y) * 64 ~/ 2000 + n) & 255;
    }
    for (final level in [6]) {
      double t(List<int> Function() f) {
        f();
        final sw = Stopwatch()..start();
        for (var i = 0; i < 3; i++) f();
        return sw.elapsedMilliseconds / 3;
      }

      final a = t(() => img.encodePng(im, level: level));
      final b = t(() => rapid.encodePng(im, level: level));
      print(
          'WEB level $level: image ${a.toStringAsFixed(0)} ms (${img.encodePng(im, level: level).length ~/ 1024} KB), rapid ${b.toStringAsFixed(0)} ms (${rapid.encodePng(im, level: level).length ~/ 1024} KB), ${(a / b).toStringAsFixed(1)}x');
    }
  }, timeout: Timeout.none);
}
