@TestOn('browser')
library;

import 'package:image/image.dart' as img;
import 'package:rapid_image/rapid_image.dart' as rapid;
import 'package:test/test.dart';

import 'rapid_image_test.dart' show noisy, expectSamePixels;

// Browser specifics. ops_test.dart runs the full comparison suite in the
// browser too; this covers initialization, synchronous loading and the
// pipeline on WebAssembly.
void main() {
  setUpAll(rapid.ensureRapidImageInitialized);

  test('drop-ins give package:image results', () {
    final im = noisy(61, 43, channels: 4);
    expectSamePixels(
        img.copyResize(im, width: 30, interpolation: img.Interpolation.cubic),
        rapid.copyResize(im,
            width: 30, interpolation: img.Interpolation.cubic));
    expectSamePixels(
        img.copyRotate(im, angle: 20), rapid.copyRotate(im, angle: 20));
    expectSamePixels(img.gaussianBlur(im.clone(), radius: 3),
        rapid.gaussianBlur(im.clone(), radius: 3));
    expectSamePixels(img.adjustColor(im.clone(), saturation: 1.3),
        rapid.adjustColor(im.clone(), saturation: 1.3));
    // JPEG is a different codec (see ops_test.dart for the tolerances):
    // check it decodes to the right size and close pixels.
    final jpg = img.encodeJpg(im, quality: 95);
    final a = img.decodeJpg(jpg)!, b = rapid.decodeJpg(jpg)!;
    expect((b.width, b.height, b.numChannels), (a.width, a.height, 3));
    final pa = a.toUint8List(), pb = b.toUint8List();
    var mx = 0;
    for (var i = 0; i < pa.length; i++) {
      final d = (pa[i] - pb[i]).abs();
      if (d > mx) mx = d;
    }
    expect(mx, lessThanOrEqualTo(6));
    expect(img.decodeJpg(rapid.encodeJpg(im))!.width, im.width);
    final png = img.encodePng(im);
    expectSamePixels(img.decodePng(png)!, rapid.decodePng(png)!);
  });

  test('a ResizeFilter resamples on WebAssembly', () {
    final im = noisy(40, 40);
    final r =
        rapid.copyResize(im, width: 10, filter: rapid.ResizeFilter.lanczos3);
    expect((r.width, r.height), (10, 10));
  });

  test('pipeline runs with package:image', () {
    final jpg = img.encodeJpg(noisy(80, 60));
    final out = rapid.RapidPipeline.decode(jpg)
        .resize(width: 40)
        .adjust(contrast: 1.1)
        .blur(1)
        .rotate(90)
        .encodeJpg();
    final back = img.decodeJpg(out)!;
    expect((back.width, back.height), (30, 40));
  });
}
