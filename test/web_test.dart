@TestOn('browser')
library;

import 'package:image/image.dart' as img;
import 'package:rapid_image/rapid_image.dart' as rapid;
import 'package:test/test.dart';

import 'rapid_image_test.dart' show noisy, expectSamePixels;

// In the browser there is no native code: every drop-in must give exactly
// package:image's result, and the pipeline must still work.
void main() {
  setUpAll(rapid.ensureRapidArchiveInitialized);

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
    final jpg = img.encodeJpg(im);
    expect(rapid.encodeJpg(im), jpg);
    expectSamePixels(img.decodeJpg(jpg)!, rapid.decodeJpg(jpg)!);
    final png = img.encodePng(im);
    expectSamePixels(img.decodePng(png)!, rapid.decodePng(png)!);
  });

  test('a ResizeFilter maps to the nearest package:image interpolation', () {
    final im = noisy(40, 40);
    expectSamePixels(
        img.copyResize(im, width: 10, interpolation: img.Interpolation.cubic),
        rapid.copyResize(im, width: 10, filter: rapid.ResizeFilter.lanczos3));
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
