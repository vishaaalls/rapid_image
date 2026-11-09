// Builds the benchmark images in bench/images/: a 4000x3000 mosaic of real
// photos from OpenCV's sample set, one 1282x1110 photo, and a 1440x3120
// phone-style UI screenshot.
//
//   dart run tool/make_bench_images.dart
//   dart run bench/bench.dart bench/images/*.png
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

const _base =
    'https://raw.githubusercontent.com/opencv/opencv/4.x/samples/data/';
const _photos = [
  'HappyFish.jpg',
  'aloeL.jpg',
  'aloeR.jpg',
  'apple.jpg',
  'baboon.jpg',
  'building.jpg',
  'fruits.jpg',
  'graf1.png',
  'graf3.png',
  'home.jpg',
  'lena.jpg',
  'messi5.jpg',
  'orange.jpg',
  'pic1.png',
  'pic3.png',
  'starry_night.jpg',
  'sudoku.png',
];

Future<img.Image> _fetch(HttpClient client, String name) async {
  final res = await (await client.getUrl(Uri.parse('$_base$name'))).close();
  if (res.statusCode != 200)
    throw HttpException('HTTP ${res.statusCode}: $name');
  final bytes = BytesBuilder(copy: false);
  await res.forEach(bytes.add);
  return img.decodeImage(bytes.takeBytes())!.convert(numChannels: 3);
}

void main() async {
  final out = Directory('bench/images')..createSync(recursive: true);
  final client = HttpClient()..findProxy = HttpClient.findProxyFromEnvironment;
  final photos = <img.Image>[];
  for (final n in _photos) {
    photos.add(await _fetch(client, n));
  }
  client.close();

  // Photo mosaic, tiles laid out row by row.
  final mosaic = img.Image(width: 4000, height: 3000);
  var x = 0, y = 0, rowH = 0, i = 0;
  while (y < 3000) {
    final p = photos[i++ % photos.length];
    if (x + p.width > 4000) {
      x = 0;
      y += rowH;
      rowH = 0;
    }
    if (y >= 3000) break;
    img.compositeImage(mosaic, p, dstX: x, dstY: y);
    x += p.width;
    if (p.height > rowH) rowH = p.height;
  }
  File('${out.path}/photo_12mp.png')
      .writeAsBytesSync(img.encodePng(mosaic, level: 1));

  File('${out.path}/photo_1.4mp.png')
      .writeAsBytesSync(img.encodePng(photos[1], level: 1));

  // Phone UI: list rows with avatars and text, and a photo near the bottom.
  final ui = img.Image(width: 1440, height: 3120, numChannels: 4);
  img.fill(ui, color: img.ColorRgba8(250, 250, 252, 255));
  for (var k = 0; k < 40; k++) {
    final y0 = 80 + k * 76;
    img.fillRect(ui,
        x1: 40,
        y1: y0,
        x2: 1400,
        y2: y0 + 64,
        radius: 18,
        color: img.ColorRgba8(255, 255, 255, 255));
    img.drawRect(ui,
        x1: 40,
        y1: y0,
        x2: 1400,
        y2: y0 + 64,
        radius: 18,
        color: img.ColorRgba8(225, 225, 230, 255));
    img.fillCircle(ui,
        x: 84,
        y: y0 + 32,
        radius: 24,
        color: img.ColorRgba8((k * 53) % 256, 120, 200, 255));
    img.drawString(ui, 'Message $k  lorem ipsum dolor sit amet consectetur',
        font: img.arial14,
        x: 130,
        y: y0 + 10,
        color: img.ColorRgba8(30, 30, 40, 255));
    img.drawString(
        ui, '12:${k.toString().padLeft(2, '0')}  preview text for the list row',
        font: img.arial14,
        x: 130,
        y: y0 + 36,
        color: img.ColorRgba8(120, 120, 130, 255));
  }
  img.compositeImage(ui, img.copyResize(photos[0], width: 1400, height: 700),
      dstX: 20, dstY: 2380);
  File('${out.path}/ui_screen.png')
      .writeAsBytesSync(img.encodePng(ui, level: 1));
  print('Wrote ${out.listSync().length} images to ${out.path}');
}
