@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:archive/archive.dart' show ZLibDecoder;
import 'package:image/image.dart' as img;
import 'package:rapid_image/rapid_image.dart' as rapid;
import 'package:test/test.dart';

import 'rapid_image_test.dart' show noisy, expectSamePixels;

List<(String, Uint8List)> chunks(Uint8List png) {
  final v = ByteData.sublistView(png);
  final r = <(String, Uint8List)>[];
  var p = 8;
  while (p < png.length) {
    final len = v.getUint32(p);
    r.add((
      String.fromCharCodes(png, p + 4, p + 8),
      Uint8List.sublistView(png, p, p + 12 + len)
    ));
    p += 12 + len;
  }
  return r;
}

Uint8List idatData(Uint8List png) {
  final b = BytesBuilder();
  for (final (t, c) in chunks(png)) {
    if (t == 'IDAT') b.add(Uint8List.sublistView(c, 8, c.length - 4));
  }
  return b.toBytes();
}

/// The native path writes 1 MiB IDAT chunks; image writes 64 KiB ones.
bool usedNative(Uint8List png) =>
    chunks(png).any((c) => c.$1 == 'IDAT' && c.$2.length > 0x10000 + 12) ||
    chunks(png).where((c) => c.$1 == 'IDAT').length == 1;

void main() {
  setUpAll(rapid.ensureRapidArchiveInitialized);

  final cases = <String, img.Image Function()>{
    'rgb8': () => noisy(700, 500),
    'rgba8': () => noisy(333, 777, channels: 4),
    'grey8': () => noisy(1023, 600, channels: 1),
    'greyalpha8': () => noisy(600, 401, channels: 2),
    'rgb16': () => noisy(400, 300, format: img.Format.uint16),
    'rgba16': () => noisy(401, 299, format: img.Format.uint16, channels: 4),
    'grey16': () => noisy(257, 900, format: img.Format.uint16, channels: 1),
    '1x1': () => noisy(1, 1),
    '1 row': () => noisy(5000, 1, channels: 4),
    '1 column': () => noisy(1, 3000),
    'tall (many bands)': () => noisy(300, 9000),
  };

  for (final MapEntry(key: name, value: make) in cases.entries) {
    test('$name: filtered data and every other chunk match image exactly', () {
      final im = make();
      for (final f in img.PngFilter.values) {
        for (final parallel in [true, false]) {
          for (final level in [1, 6, 9]) {
            final ours = rapid.encodePng(im,
                filter: f, level: level, parallel: parallel);
            final theirs = img.encodePng(im, filter: f, level: level);
            final a = chunks(ours).where((c) => c.$1 != 'IDAT').toList();
            final b = chunks(theirs).where((c) => c.$1 != 'IDAT').toList();
            expect(a.map((c) => c.$2).toList(),
                equals(b.map((c) => c.$2).toList()));
            expect(
                const ZLibDecoder().decodeBytes(idatData(ours), verify: true),
                const ZLibDecoder().decodeBytes(idatData(theirs)),
                reason: '$f level $level parallel $parallel');
          }
        }
      }
      expectSamePixels(im, img.decodePng(rapid.encodePng(im))!);
    });
  }

  test('native path is used for plain images and skipped for palettes', () {
    expect(usedNative(rapid.encodePng(noisy(2000, 1500))), isTrue);
    final q = img.quantize(noisy(2000, 1500), numberOfColors: 200);
    final enc = rapid.encodePng(q);
    expectSamePixels(img.decodePng(img.encodePng(q))!, img.decodePng(enc)!);
  });

  test('metadata: ICC, text, pHYs and cICP are identical to image', () {
    final im = noisy(640, 480, channels: 4)
      ..textData = {'Title': 'rapid', 'Software': 'test'}
      ..iccProfile = img.IccProfile('sRGB', img.IccProfileCompression.none,
          Uint8List.fromList(List.generate(3000, (i) => i * 7 % 251)));
    final phys = img.PngPhysicalPixelDimensions.dpi(144);
    final cicp = img.PngCicpData(
        colorPrimaries: 1,
        transferCharacteristics: 13,
        matrixCoefficients: 0,
        videoFullRangeFlag: 1);
    final ours =
        rapid.RapidPngEncoder(pixelDimensions: phys, cicpData: cicp).encode(im);
    final theirs =
        img.PngEncoder(pixelDimensions: phys, cicpData: cicp).encode(im);
    final a = chunks(ours).where((c) => c.$1 != 'IDAT');
    final b = chunks(theirs).where((c) => c.$1 != 'IDAT');
    expect(a.map((c) => c.$1), containsAll(['iCCP', 'tEXt', 'pHYs', 'cICP']));
    expect(a.map((c) => c.$2).toList(), equals(b.map((c) => c.$2).toList()));
  });

  test('singleFrame on an animation encodes the first frame natively', () {
    final anim = noisy(300, 200, seed: 1)..addFrame(noisy(300, 200, seed: 2));
    final ours = rapid.encodePng(anim, singleFrame: true);
    final theirs = img.encodePng(anim, singleFrame: true);
    expectSamePixels(img.decodePng(theirs)!, img.decodePng(ours)!);
    expect(chunks(ours).map((c) => c.$1), isNot(contains('acTL')));
  });
}
