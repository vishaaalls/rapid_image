// Times package:image against rapid_image's drop-ins and pipeline.
//
//   dart run tool/make_bench_images.dart     # once, builds bench/images/
//   dart run bench/ops_bench.dart bench/images/photo_12mp.png

import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:rapid_image/rapid_image.dart' as rapid;

double ms(void Function() f, {int runs = 3}) {
  f();
  final sw = Stopwatch()..start();
  for (var i = 0; i < runs; i++) {
    f();
  }
  return sw.elapsedMicroseconds / 1000 / runs;
}

void row(String name, double a, double b) => print('${name.padRight(34)}'
    '${a.toStringAsFixed(0).padLeft(8)} ms'
    '${b.toStringAsFixed(0).padLeft(8)} ms'
    '${(a / b).toStringAsFixed(1).padLeft(8)}x');

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run bench/ops_bench.dart some.png');
    exit(64);
  }
  final png = File(args.first).readAsBytesSync();
  final im = img.decodePng(png)!;
  final jpg = img.encodeJpg(im, quality: 85);
  print('${args.first}: ${im.width}x${im.height}, ${im.numChannels} channels, '
      '${Platform.numberOfProcessors} cores');
  print('${'operation'.padRight(34)}${'image'.padLeft(11)}'
      '${'rapid'.padLeft(11)}${'speedup'.padLeft(9)}');

  row('decodeJpg', ms(() => img.decodeJpg(jpg)),
      ms(() => rapid.decodeJpg(jpg)));
  row('decodePng', ms(() => img.decodePng(png)),
      ms(() => rapid.decodePng(png)));
  row('encodeJpg q85 (4:4:4)', ms(() => img.encodeJpg(im, quality: 85)),
      ms(() => rapid.encodeJpg(im, quality: 85)));
  row(
      'encodeJpg q85 4:2:0',
      ms(() => img.encodeJpg(im, quality: 85, chroma: img.JpegChroma.yuv420)),
      ms(() =>
          rapid.encodeJpg(im, quality: 85, chroma: img.JpegChroma.yuv420)));
  row('encodePng level 6', ms(() => img.encodePng(im)),
      ms(() => rapid.encodePng(im)));
  for (final i in [
    img.Interpolation.linear,
    img.Interpolation.cubic,
    img.Interpolation.average
  ]) {
    row(
        'copyResize 1/4 ${i.name}',
        ms(() => img.copyResize(im, width: im.width ~/ 4, interpolation: i)),
        ms(() => rapid.copyResize(im, width: im.width ~/ 4, interpolation: i)));
  }
  row(
      'copyResize 1/4 lanczos3 (new)',
      ms(() => img.copyResize(im,
          width: im.width ~/ 4, interpolation: img.Interpolation.cubic)),
      ms(() => rapid.copyResize(im,
          width: im.width ~/ 4, filter: rapid.ResizeFilter.lanczos3)));
  row('copyRotate 90', ms(() => img.copyRotate(im, angle: 90)),
      ms(() => rapid.copyRotate(im, angle: 90)));
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
      'adjustColor contrast+saturation',
      ms(() => img.adjustColor(im.clone(),
          brightness: 1.1, contrast: 1.1, saturation: 1.2)),
      ms(() => rapid.adjustColor(im.clone(),
          brightness: 1.1, contrast: 1.1, saturation: 1.2)));
  row(
      'adjustColor contrast only',
      ms(() => img.adjustColor(im.clone(), contrast: 1.2)),
      ms(() => rapid.adjustColor(im.clone(), contrast: 1.2)));

  // A typical upload: phone JPEG -> 1080 wide -> colour tweak -> JPEG.
  final a = ms(() {
    final d = img.decodeJpg(jpg)!;
    final s =
        img.copyResize(d, width: 1080, interpolation: img.Interpolation.cubic);
    img.adjustColor(s, contrast: 1.1, saturation: 1.2);
    img.encodeJpg(s, quality: 85);
  });
  final b = ms(() {
    final d = rapid.decodeJpg(jpg)!;
    final s = rapid.copyResize(d,
        width: 1080, interpolation: img.Interpolation.cubic);
    rapid.adjustColor(s, contrast: 1.1, saturation: 1.2);
    rapid.encodeJpg(s, quality: 85);
  });
  final c = ms(() => (rapid.RapidPipeline.decode(jpg)
        ..resize(width: 1080)
        ..adjust(contrast: 1.1, saturation: 1.2))
      .encodeJpg(quality: 85));
  row('upload: drop-ins (cubic)', a, b);
  row('upload: RapidPipeline (lanczos3)', a, c);
}
