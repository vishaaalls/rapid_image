// Compares image's encodePng with rapid_image's on real PNG files.
// dart run bench/bench.dart a.png b.png ...
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:rapid_image/rapid_image.dart' as rapid;

(double, int) time(List<int> Function() f, int n) {
  final size = f().length;
  final sw = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    f();
  }
  return (sw.elapsedMicroseconds / n / 1000, size);
}

void main(List<String> files) async {
  await rapid.ensureRapidArchiveInitialized();
  print('cores: ${Platform.numberOfProcessors}');
  for (final f in files) {
    final im = img.decodePng(File(f).readAsBytesSync())!;
    print(
        '\n${f.split('/').last}: ${im.width}x${im.height}, ${im.numChannels} channels');
    print(
        'level  image ms (KB)     rapid 1 core ms (KB)   rapid parallel ms (KB)   speedup');
    for (final level in [1, 3, 6, 9]) {
      final n = im.width * im.height > 4000000 ? 2 : 5;
      final (a, sa) = time(() => img.encodePng(im, level: level), n);
      final (b, sb) =
          time(() => rapid.encodePng(im, level: level, parallel: false), n);
      final (c, sc) = time(() => rapid.encodePng(im, level: level), n);
      String cell(double t, int s) =>
          '${t.toStringAsFixed(0).padLeft(6)} (${(s ~/ 1024).toString().padLeft(6)})';
      print('  $level   ${cell(a, sa)}     ${cell(b, sb)}        ${cell(c, sc)}'
          '          ${(a / b).toStringAsFixed(1)}x / ${(a / c).toStringAsFixed(1)}x');
    }
  }
  exit(0);
}
