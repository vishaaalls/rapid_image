import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:image/image.dart' as img;
import 'package:rapid_image/rapid_image.dart' as rapid;
import 'package:test/test.dart';

img.Image noisy(int w, int h,
    {img.Format format = img.Format.uint8, int channels = 3, int seed = 1}) {
  final r = Random(seed);
  final im =
      img.Image(width: w, height: h, format: format, numChannels: channels);
  final maxV = im.maxChannelValue.toInt();
  for (final p in im) {
    for (var c = 0; c < channels; c++) {
      p[c] =
          (((p.x + p.y * 3) * maxV ~/ (w + 3 * h)) + r.nextInt(8)) % (maxV + 1);
    }
  }
  return im;
}

void expectSamePixels(img.Image a, img.Image b) {
  expect(b.width, a.width);
  expect(b.height, a.height);
  expect(b.numChannels, a.numChannels);
  expect(b.format, a.format);
  final pa = a.toUint8List(), pb = b.toUint8List();
  expect(pb, orderedEquals(pa));
}

void checkRoundTrip(img.Image im, {bool parallel = true, int level = 6}) {
  final ours = rapid.encodePng(im, parallel: parallel, level: level);
  final theirs = img.encodePng(im, level: level);
  final a = img.decodePng(theirs)!;
  final b = img.decodePng(ours)!;
  expectSamePixels(a, b);
}

void main() {
  setUpAll(rapid.ensureRapidArchiveInitialized);

  test('rgb8, parallel and single', () {
    final im = noisy(613, 401);
    checkRoundTrip(im);
    checkRoundTrip(im, parallel: false);
  });

  test('every level', () {
    final im = noisy(300, 200);
    for (var l = 0; l <= 9; l++) {
      checkRoundTrip(im, level: l);
    }
  });

  test('rgba8, grey, grey+alpha, 16-bit, 1-bit, palette', () {
    checkRoundTrip(noisy(257, 129, channels: 4));
    checkRoundTrip(noisy(257, 129, channels: 1));
    checkRoundTrip(noisy(257, 129, channels: 2));
    checkRoundTrip(noisy(257, 129, format: img.Format.uint16, channels: 4));
    checkRoundTrip(noisy(257, 129, format: img.Format.uint1, channels: 1));
    final q = img.quantize(noisy(200, 100), numberOfColors: 64);
    checkRoundTrip(q);
  });

  test('tiny and large images', () {
    checkRoundTrip(noisy(1, 1));
    checkRoundTrip(noisy(2000, 1500)); // spans many 1 MB IDAT chunks
  });

  test('metadata chunks are kept', () {
    final im = noisy(64, 64)..textData = {'Title': 'rapid', 'Author': 'x'};
    im.iccProfile = img.IccProfile('test', img.IccProfileCompression.none,
        Uint8List.fromList(List.generate(500, (i) => i % 7)));
    final enc = rapid.encodePng(im);
    final dec = img.decodePng(enc)!;
    expect(dec.textData, {'Title': 'rapid', 'Author': 'x'});
    expect(dec.iccProfile?.decompressed(), im.iccProfile!.decompressed());
    expectSamePixels(img.decodePng(img.encodePng(im))!, dec);
  });

  test('APNG frames, durations and sequence numbers', () {
    final anim = noisy(120, 80, channels: 4, seed: 1)..frameDuration = 40;
    for (var i = 2; i <= 4; i++) {
      anim.addFrame(
          noisy(120, 80, channels: 4, seed: i)..frameDuration = 40 * i);
    }
    final enc = rapid.encodePng(anim);
    final ref = img.decodePng(img.encodePng(anim))!;
    final dec = img.decodePng(enc)!;
    expect(dec.numFrames, 4);
    for (var i = 0; i < 4; i++) {
      expectSamePixels(ref.frames[i], dec.frames[i]);
      expect(dec.frames[i].frameDuration, ref.frames[i].frameDuration);
    }
    expect(_sequenceNumbersOk(enc), isTrue);
  });

  test('large APNG frame split over several fdAT chunks', () {
    final anim = noisy(1500, 1200, seed: 1);
    anim.addFrame(noisy(1500, 1200, seed: 2));
    final enc = rapid.encodePng(anim, level: 1);
    expect(_sequenceNumbersOk(enc), isTrue);
    final dec = img.decodePng(enc)!;
    final ref = img.decodePng(img.encodePng(anim, level: 1))!;
    expectSamePixels(ref.frames[1], dec.frames[1]);
  });

  test('every chunk CRC is valid', () {
    final enc = rapid.encodePng(noisy(500, 400));
    expect(_crcsOk(enc), isTrue);
  });

  test('encodeNamedImage uses the rapid encoder for .png', () {
    expect(
        rapid.findEncoderForNamedImage('a.PNG'), isA<rapid.RapidPngEncoder>());
    expect(rapid.findEncoderForNamedImage('a.jpg'), isA<img.JpegEncoder>());
    final im = noisy(50, 40);
    expectSamePixels(im, img.decodePng(rapid.encodeNamedImage('x.png', im)!)!);
  });

  test('streaming start/addFrame/finish API', () {
    final e = rapid.RapidPngEncoder()..start(2);
    final a = noisy(90, 60, seed: 5), b = noisy(90, 60, seed: 6);
    e
      ..addFrame(a)
      ..addFrame(b);
    final dec = img.decodePng(e.finish()!)!;
    expect(dec.numFrames, 2);
    expectSamePixels(a, dec.frames[0]);
    expectSamePixels(b, dec.frames[1]);
  });

  test('rejects non-PNG input', () {
    expect(() => rapid.recompressPng(Uint8List(20)), throwsFormatException);
  });
}

Iterable<(String, Uint8List, int)> _chunks(Uint8List png) sync* {
  final v = ByteData.sublistView(png);
  var p = 8;
  while (p < png.length) {
    final len = v.getUint32(p);
    yield (
      String.fromCharCodes(png.sublist(p + 4, p + 8)),
      Uint8List.sublistView(png, p + 4, p + 8 + len),
      v.getUint32(p + 8 + len)
    );
    p += 12 + len;
  }
}

bool _crcsOk(Uint8List png) =>
    _chunks(png).every((c) => getCrc32(c.$2) == c.$3);

bool _sequenceNumbersOk(Uint8List png) {
  var expected = 0;
  for (final (type, body, _) in _chunks(png)) {
    if (type == 'fcTL' || type == 'fdAT') {
      final seq = ByteData.sublistView(body).getUint32(4);
      if (seq != expected++) return false;
    }
  }
  return _crcsOk(png);
}
