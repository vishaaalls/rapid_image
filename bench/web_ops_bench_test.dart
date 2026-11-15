// Browser benchmark: package:image against rapid_image's WebAssembly path.
//
//   dart test -p chrome bench/web_ops_bench_test.dart                # dart2js
//   dart test -p chrome -c dart2wasm bench/web_ops_bench_test.dart   # dart2wasm
@TestOn('browser')
library;

import 'dart:math';

import 'package:image/image.dart' as img;
import 'package:rapid_image/rapid_image.dart' as rapid;
import 'package:test/test.dart';

double ms(void Function() f, {int runs = 3}) {
  f();
  final sw = Stopwatch()..start();
  for (var i = 0; i < runs; i++) {
    f();
  }
  return sw.elapsedMicroseconds / 1000 / runs;
}

void main() {
  test('web ops bench', () async {
    await rapid.ensureRapidImageInitialized();
    // A 2000x1500 photo-like image: gradients plus noise.
    final r = Random(1);
    final im = img.Image(width: 2000, height: 1500);
    for (final p in im) {
      final n = r.nextInt(12);
      p
        ..r = (p.x * 255 ~/ 2000 + n) & 255
        ..g = (p.y * 255 ~/ 1500 + n) & 255
        ..b = ((p.x + p.y) * 64 ~/ 2000 + 40 + n) & 255;
    }
    final jpg = img.encodeJpg(im, quality: 85);
    final png = img.encodePng(im, level: 1);
    final rows = <String>[];
    void row(String name, double a, double b) => rows.add(
        'WEB ${name.padRight(30)} ${a.toStringAsFixed(0).padLeft(6)} ms'
        ' ${b.toStringAsFixed(0).padLeft(6)} ms ${(a / b).toStringAsFixed(1).padLeft(5)}x');

    row('decodeJpg', ms(() => img.decodeJpg(jpg)),
        ms(() => rapid.decodeJpg(jpg)));
    row('decodePng', ms(() => img.decodePng(png)),
        ms(() => rapid.decodePng(png)));
    row('encodeJpg q85', ms(() => img.encodeJpg(im, quality: 85)),
        ms(() => rapid.encodeJpg(im, quality: 85)));
    row(
        'copyResize 1/4 cubic',
        ms(() => img.copyResize(im,
            width: 500, interpolation: img.Interpolation.cubic)),
        ms(() => rapid.copyResize(im,
            width: 500, interpolation: img.Interpolation.cubic)));
    row(
        'copyRotate 15 linear',
        ms(() => img.copyRotate(im,
            angle: 15, interpolation: img.Interpolation.linear)),
        ms(() => rapid.copyRotate(im,
            angle: 15, interpolation: img.Interpolation.linear)));
    row(
        'gaussianBlur radius 5',
        ms(() => img.gaussianBlur(im.clone(), radius: 5)),
        ms(() => rapid.gaussianBlur(im.clone(), radius: 5)));
    row(
        'adjustColor contrast+sat',
        ms(() => img.adjustColor(im.clone(), contrast: 1.1, saturation: 1.2)),
        ms(() =>
            rapid.adjustColor(im.clone(), contrast: 1.1, saturation: 1.2)));
    final a = ms(() {
      final d = img.decodeJpg(jpg)!;
      final s = img.copyResize(d,
          width: 1080, interpolation: img.Interpolation.cubic);
      img.adjustColor(s, contrast: 1.1, saturation: 1.2);
      img.encodeJpg(s, quality: 85);
    });
    final b = ms(() => (rapid.RapidPipeline.decode(jpg)
          ..resize(width: 1080)
          ..adjust(contrast: 1.1, saturation: 1.2))
        .encodeJpg(quality: 85));
    row('upload flow (RapidPipeline)', a, b);
    // The cost of crossing into WebAssembly memory and back (9 MB).
    final n = im.toUint8List();
    final copy = ms(() {
      final x = rapid.RapidPipeline.fromImage(im);
      x.toImage();
      x.dispose();
    });
    rows.add(
        'WEB copy in + out, 9 MB: ${copy.toStringAsFixed(1)} ms (${n.length} bytes)');
    print(rows.join('\n'));
  }, timeout: Timeout.none);
}
