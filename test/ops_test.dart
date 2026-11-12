// Runs natively and in browsers (WebAssembly), checking the same results.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:rapid_image/rapid_image.dart' as rapid;
import 'package:test/test.dart';

import 'rapid_image_test.dart' show noisy, expectSamePixels;

/// A photo-like test image: smooth gradients, a hard edge and mild noise.
img.Image photo(int w, int h, {int channels = 3, int seed = 7}) {
  final r = Random(seed);
  final im = img.Image(width: w, height: h, numChannels: channels);
  for (final p in im) {
    final x = p.x / w, y = p.y / h;
    final edge = (p.x - w ~/ 3).abs() < w ~/ 20 ? 90 : 0;
    final v = [
      (40 + 180 * x + edge + r.nextInt(9)).clamp(0, 255),
      (60 + 150 * y + 30 * sin(x * 9) + r.nextInt(9)).clamp(0, 255),
      (200 - 120 * x * y + r.nextInt(9) - edge).clamp(0, 255),
      (255 - 200 * y).clamp(0, 255),
    ];
    for (var c = 0; c < channels; c++) {
      p[c] = channels <= 2 && c == 0
          ? (v[0] + v[1]) ~/ 2
          : v[channels == 2 && c == 1 ? 3 : c];
    }
  }
  return im;
}

/// Largest and mean absolute difference between two same-sized images.
(int, double) diff(img.Image a, img.Image b) {
  expect(b.width, a.width);
  expect(b.height, a.height);
  expect(b.numChannels, a.numChannels);
  final pa = a.toUint8List(), pb = b.toUint8List();
  var mx = 0, sum = 0;
  for (var i = 0; i < pa.length; i++) {
    final d = (pa[i] - pb[i]).abs();
    sum += d;
    if (d > mx) mx = d;
  }
  return (mx, sum / pa.length);
}

img.ExifData exifWith({int? orientation, String? make}) {
  final e = img.ExifData();
  if (orientation != null) e.imageIfd.orientation = orientation;
  if (make != null) e.imageIfd['Make'] = img.IfdValueAscii(make);
  return e;
}

void main() {
  setUpAll(rapid.ensureRapidImageInitialized);

  group('decodePng', () {
    for (final nc in [1, 2, 3, 4]) {
      test('$nc channels: same pixels and metadata as image', () {
        final im = noisy(301, 187, channels: nc)
          ..addTextData({'Title': 'rapid', 'Note': 'ü'})
          ..iccProfile = img.IccProfile('icc', img.IccProfileCompression.none,
              Uint8List.fromList(List.generate(200, (i) => i)));
        final png = img.encodePng(im);
        final a = img.decodePng(png)!;
        final b = rapid.decodePng(png)!;
        expectSamePixels(a, b);
        expect(b.textData, a.textData);
        expect(b.iccProfile!.decompressed(), a.iccProfile!.decompressed());
        expect(b.iccProfile!.name, a.iccProfile!.name);
      });
    }

    test('palette, 16-bit and 1-bit PNGs fall back to image', () {
      for (final im in [
        img.Image(width: 20, height: 9, numChannels: 3, withPalette: true),
        noisy(31, 17, format: img.Format.uint16),
        img.Image(
            width: 33, height: 5, format: img.Format.uint1, numChannels: 1),
      ]) {
        final png = img.encodePng(im);
        final a = img.decodePng(png)!;
        final b = rapid.decodePng(png)!;
        expectSamePixels(a, b);
        expect(b.hasPalette, a.hasPalette);
      }
    });

    test('decodeImage routes PNG and JPEG, and other formats to image', () {
      final im = photo(64, 40);
      expectSamePixels(rapid.decodeImage(img.encodePng(im))!, im);
      expect(rapid.decodeImage(img.encodeJpg(im))!.width, 64);
      final bmp = img.encodeBmp(im);
      expectSamePixels(rapid.decodeImage(bmp)!, img.decodeImage(bmp)!);
      expect(rapid.decodeImage(Uint8List.fromList([1, 2, 3, 4])), isNull);
    });
  });

  group('decodeJpg', () {
    // zune-jpeg's IDCT rounding differs slightly from package:image's
    // (4:4:4: within 4, mean about 0.4 on photos). For 4:2:0 it also
    // interpolates the half-resolution chroma, as libjpeg-turbo and browsers
    // do, where package:image repeats it. On real photos that gives mean
    // 0.9 to 1.0 and 99th percentile 6 to 8, but sharp saturated colour edges
    // differ by up to about 75 (this synthetic image stays under 32). The
    // libjpeg-turbo comparison is in native_test.dart.
    for (final chroma in img.JpegChroma.values) {
      test('${chroma.name}: close to image', () {
        final jpg = img.encodeJpg(photo(517, 333), quality: 90, chroma: chroma);
        final a = img.decodeJpg(jpg)!;
        final b = rapid.decodeJpg(jpg)!;
        final (mx, mean) = diff(a, b);
        expect(b.numChannels, 3);
        expect(b.format, img.Format.uint8);
        expect(mean, lessThan(chroma == img.JpegChroma.yuv444 ? 0.8 : 1.6),
            reason: 'max $mx mean $mean');
        expect(mx, lessThanOrEqualTo(chroma == img.JpegChroma.yuv444 ? 6 : 32),
            reason: 'max $mx mean $mean');
      });
    }

    for (var o = 1; o <= 8; o++) {
      test('EXIF orientation $o is applied, as image does', () {
        final base = img.encodeJpg(photo(120, 70), quality: 95);
        final jpg =
            img.injectJpgExif(base, exifWith(orientation: o, make: 'Test'))!;
        final a = img.decodeJpg(jpg)!;
        final b = rapid.decodeJpg(jpg)!;
        final (mx, mean) = diff(a, b);
        expect(mean, lessThan(0.6), reason: 'max $mx');
        expect(b.exif.imageIfd.hasOrientation, isFalse);
        expect(b.exif.imageIfd['Make']?.toString(), 'Test');
      });
    }

    test('ICC profile is read as image reads it', () {
      final im = photo(50, 30)
        ..iccProfile = img.IccProfile(
            'ICC_PROFILE',
            img.IccProfileCompression.none,
            Uint8List.fromList(List.generate(300, (i) => i * 7)));
      final jpg = img.encodeJpg(im);
      expect(rapid.decodeJpg(jpg)!.iccProfile!.data,
          img.decodeJpg(jpg)!.iccProfile!.data);
    });

    test('scale and garbage fall back to image', () {
      final jpg = img.encodeJpg(photo(80, 64));
      expect(rapid.decodeJpg(jpg, scale: 2)!.width,
          img.decodeJpg(jpg, scale: 2)!.width);
      // Bytes image can't read: the same outcome as image (here, an error).
      final bad = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0, 1]);
      expect(() => img.decodeJpg(bad), throwsA(isA<img.ImageException>()));
      expect(() => rapid.decodeJpg(bad), throwsA(isA<img.ImageException>()));
    });
  });

  group('encodeJpg', () {
    test('decodes close to the source and to image\'s output', () {
      final im = photo(640, 480);
      final ours = rapid.encodeJpg(im, quality: 90);
      final theirs = img.encodeJpg(im, quality: 90);
      final a = img.decodeJpg(theirs)!;
      final b = img.decodeJpg(ours)!;
      final (_, meanSrc) = diff(im, b);
      final (_, meanImg) = diff(a, b);
      expect(meanSrc, lessThan(2.5));
      expect(meanImg, lessThan(1.5));
      // 4:4:4 like image, and within a few percent of its size.
      expect(ours.length / theirs.length, inInclusiveRange(0.8, 1.2));
    });

    test('4:2:0 is smaller', () {
      final im = photo(640, 480);
      expect(
          rapid
              .encodeJpg(im, quality: 85, chroma: img.JpegChroma.yuv420)
              .length,
          lessThan(rapid.encodeJpg(im, quality: 85).length));
    });

    test('EXIF and ICC are written as image writes them', () {
      final im = photo(64, 48)
        ..exif = exifWith(orientation: 6, make: 'Rapid')
        ..iccProfile = img.IccProfile(
            'ICC_PROFILE',
            img.IccProfileCompression.none,
            Uint8List.fromList(List.generate(500, (i) => i % 251)));
      final ours = rapid.encodeJpg(im);
      final e = img.decodeJpgExif(ours)!;
      expect(e.imageIfd.orientation, 6);
      expect(e.imageIfd['Make'].toString(), 'Rapid');
      final theirs = img.encodeJpg(im);
      expect(img.decodeJpg(ours)!.iccProfile!.data,
          img.decodeJpg(theirs)!.iccProfile!.data);
    });

    test('RGBA is blended onto the background, as image does', () {
      final im = photo(96, 64, channels: 4);
      final a = img.decodeJpg(img.encodeJpg(im, quality: 95))!;
      final b = img.decodeJpg(rapid.encodeJpg(im, quality: 95))!;
      expect(diff(a, b).$2, lessThan(1.5));
      im.backgroundColor = img.ColorRgb8(0, 0, 0);
      final c = img.decodeJpg(img.encodeJpg(im, quality: 95))!;
      final d = img.decodeJpg(rapid.encodeJpg(im, quality: 95))!;
      expect(diff(c, d).$2, lessThan(1.5));
    });

    test('grey and 16-bit images fall back to image', () {
      for (final im in [
        noisy(40, 30, channels: 1),
        noisy(40, 30, format: img.Format.uint16)
      ]) {
        expect(rapid.encodeJpg(im), img.encodeJpg(im));
      }
    });

    test('encodeNamedImage picks the native JPEG encoder', () {
      expect(rapid.findEncoderForNamedImage('a.JPG'),
          isA<rapid.RapidJpegEncoder>());
      expect(rapid.findEncoderForNamedImage('a.jpeg'),
          isA<rapid.RapidJpegEncoder>());
    });
  });

  group('copyResize matches image exactly', () {
    for (final interp in img.Interpolation.values) {
      for (final nc in [1, 2, 3, 4]) {
        test('${interp.name}, $nc channels', () {
          final im = photo(203, 131, channels: nc);
          for (final (w, h) in [
            (64, null),
            (null, 50),
            (90, 200),
            (407, 263),
            (1, 1),
            (203, 77)
          ]) {
            final a =
                img.copyResize(im, width: w, height: h, interpolation: interp);
            final b = rapid.copyResize(im,
                width: w, height: h, interpolation: interp);
            expectSamePixels(a, b);
          }
        });
      }
      test('${interp.name}, every EXIF orientation', () {
        for (var o = 1; o <= 8; o++) {
          final im = photo(97, 61)..exif = exifWith(orientation: o, make: 'X');
          final a = img.copyResize(im, width: 40, interpolation: interp);
          final b = rapid.copyResize(im, width: 40, interpolation: interp);
          expectSamePixels(a, b);
          expect(
              b.exif.imageIfd.hasOrientation, a.exif.imageIfd.hasOrientation);
          expect(b.exif.imageIfd['Make'].toString(), 'X');
        }
      });
    }

    test('metadata is kept', () {
      final im = photo(50, 50)
        ..addTextData({'k': 'v'})
        ..iccProfile =
            img.IccProfile('p', img.IccProfileCompression.none, Uint8List(10));
      final b = rapid.copyResize(im, width: 20);
      expect(b.textData, {'k': 'v'});
      expect(b.iccProfile!.name, 'p');
    });

    test('letterboxing, 16-bit and palette images fall back to image', () {
      final im = photo(60, 40);
      expectSamePixels(
          img.copyResize(im,
              width: 50,
              height: 50,
              maintainAspect: true,
              backgroundColor: img.ColorRgb8(9, 9, 9)),
          rapid.copyResize(im,
              width: 50,
              height: 50,
              maintainAspect: true,
              backgroundColor: img.ColorRgb8(9, 9, 9)));
      final deep = noisy(60, 40, format: img.Format.uint16);
      expectSamePixels(
          img.copyResize(deep, width: 30), rapid.copyResize(deep, width: 30));
    });
  });

  group('copyResize with a ResizeFilter', () {
    for (final f in rapid.ResizeFilter.values) {
      test('${f.name}: right size, close to a smooth source', () {
        final im = photo(400, 300);
        final b = rapid.copyResize(im, width: 100, filter: f);
        expect((b.width, b.height), (100, 75));
        // Compare with an area average of the source, which is what a good
        // downscale approximates.
        final ref = img.copyResize(im,
            width: 100, interpolation: img.Interpolation.average);
        expect(diff(ref, b).$2, lessThan(4));
      });
    }
  });

  group('copyRotate matches image exactly', () {
    for (final interp in img.Interpolation.values) {
      for (final nc in [1, 2, 3, 4]) {
        test('${interp.name}, $nc channels', () {
          final im = photo(91, 57, channels: nc);
          for (final angle in [90, 180, 270, -90, 450, 15, 33.3, 200, -47.5]) {
            final a = img.copyRotate(im, angle: angle, interpolation: interp);
            final b = rapid.copyRotate(im, angle: angle, interpolation: interp);
            expectSamePixels(a, b);
          }
        });
      }
    }

    test('a background colour falls back to image', () {
      final im = photo(40, 30)..backgroundColor = img.ColorRgb8(200, 0, 0);
      expectSamePixels(
          img.copyRotate(im, angle: 30), rapid.copyRotate(im, angle: 30));
    });
  });

  group('gaussianBlur matches image exactly', () {
    for (final nc in [1, 2, 3, 4]) {
      test('$nc channels', () {
        for (final radius in [1, 2, 5, 12, 40]) {
          final a =
              img.gaussianBlur(photo(83, 61, channels: nc), radius: radius);
          final b =
              rapid.gaussianBlur(photo(83, 61, channels: nc), radius: radius);
          expectSamePixels(a, b);
        }
      });
    }

    test('blurs in place and returns its argument', () {
      final im = photo(30, 30);
      expect(identical(rapid.gaussianBlur(im, radius: 2), im), isTrue);
    });

    test('a mask falls back to image', () {
      final mask = noisy(40, 40, channels: 1);
      final a = img.gaussianBlur(photo(40, 40), radius: 3, mask: mask);
      final b = rapid.gaussianBlur(photo(40, 40), radius: 3, mask: mask);
      expectSamePixels(a, b);
    });
  });

  group('adjustColor matches image exactly', () {
    final params = <Map<Symbol, num>>[
      {#brightness: 1.1, #contrast: 1.1, #saturation: 1.2},
      {#saturation: 0},
      {#hue: 45},
      {#hue: -120, #saturation: 1.5, #amount: 0.5},
      {#contrast: 0.6},
      {#contrast: 1.8, #gamma: 0.7},
      {#exposure: 0.5},
      {#brightness: 0.8, #amount: 0.3},
      {#gamma: 2.2, #saturation: 0.8, #exposure: 0.2},
    ];
    for (final nc in [3, 4]) {
      for (final p in params) {
        test(
            '$nc channels, ${p.map((k, v) => MapEntry(k.toString().split('"')[1], v))}',
            () {
          img.Image run(Function f) =>
              Function.apply(f, [photo(97, 63, channels: nc)], p) as img.Image;
          expectSamePixels(run(img.adjustColor), run(rapid.adjustColor));
        });
      }
    }

    test('grey images and blacks/whites fall back to image', () {
      final g = noisy(30, 20, channels: 1);
      expectSamePixels(img.adjustColor(g.clone(), contrast: 1.4),
          rapid.adjustColor(g.clone(), contrast: 1.4));
      final c = photo(30, 20);
      expectSamePixels(
          img.adjustColor(c.clone(), blacks: img.ColorRgb8(20, 20, 20)),
          rapid.adjustColor(c.clone(), blacks: img.ColorRgb8(20, 20, 20)));
    });
  });

  group('RapidPipeline', () {
    test('JPEG in, steps, JPEG out', () {
      final src = photo(800, 600)..exif = exifWith(make: 'Cam');
      final jpg = img.encodeJpg(src, quality: 92);
      final out = rapid.RapidPipeline.decode(jpg)
          .resize(width: 400)
          .adjust(contrast: 1.1, saturation: 1.2)
          .blur(1)
          .encodeJpg(quality: 85);
      final back = img.decodeJpg(out)!;
      expect((back.width, back.height), (400, 300));
      expect(back.exif.imageIfd['Make'].toString(), 'Cam');
    });

    test('steps give the same pixels as the drop-ins', () {
      final im = photo(300, 200, channels: 4);
      final p = rapid.RapidPipeline.fromImage(im)
        ..adjust(brightness: 1.2, hue: 20)
        ..blur(3)
        ..rotate(90, interpolation: img.Interpolation.nearest)
        ..flip(img.FlipDirection.horizontal)
        ..crop(10, 20, 150, 250);
      var expected = rapid.adjustColor(im.clone(), brightness: 1.2, hue: 20);
      expected = rapid.gaussianBlur(expected, radius: 3);
      expected = img.copyRotate(expected, angle: 90);
      expected = img.flipHorizontal(expected);
      expected = img.copyCrop(expected, x: 10, y: 20, width: 150, height: 250);
      expectSamePixels(expected, p.toImage());
      p.dispose();
    });

    test('a JPEG\'s orientation is applied on decode', () {
      final jpg = img.injectJpgExif(
          img.encodeJpg(photo(90, 40)), exifWith(orientation: 6))!;
      final p = rapid.RapidPipeline.decode(jpg);
      expect((p.width, p.height), (40, 90));
      expect(p.toImage().exif.imageIfd.hasOrientation, isFalse);
    });

    test('PNG in, PNG out keeps text and ICC', () {
      final im = photo(120, 80)
        ..addTextData({'a': 'b'})
        ..iccProfile = img.IccProfile('n', img.IccProfileCompression.none,
            Uint8List.fromList(List.filled(64, 3)));
      final out = rapid.RapidPipeline.decode(img.encodePng(im))
          .resize(width: 60)
          .encodePng();
      final back = img.decodePng(out)!;
      expect(back.width, 60);
      expect(back.textData, {'a': 'b'});
      expect(back.iccProfile!.decompressed(), List.filled(64, 3));
    });

    test('16-bit, palette and grey images work', () {
      final deep = noisy(50, 40, format: img.Format.uint16);
      expect(
          rapid.RapidPipeline.fromImage(deep)
              .resize(width: 25)
              .toImage()
              .format,
          img.Format.uint8);
      final pal =
          img.Image(width: 20, height: 10, numChannels: 3, withPalette: true);
      expect(rapid.RapidPipeline.fromImage(pal).numChannels, 3);
      final grey = noisy(50, 40, channels: 1);
      final jpg =
          rapid.RapidPipeline.fromImage(grey).adjust(contrast: 1.2).encodeJpg();
      expect(img.decodeJpg(jpg)!.width, 50);
    });

    test('errors', () {
      expect(() => rapid.RapidPipeline.decode(Uint8List.fromList([1, 2, 3])),
          throwsFormatException);
      final p = rapid.RapidPipeline.fromImage(photo(10, 10))..dispose();
      expect(() => p.resize(width: 5), throwsStateError);
      expect(() => rapid.RapidPipeline.fromImage(photo(10, 10)).resize(),
          throwsArgumentError);
    });
  });
}
