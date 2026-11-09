# rapid_image

Faster PNG encoding for [`package:image`](https://pub.dev/packages/image):
about 6x faster at the default level on a 4-core machine, with the same pixels
and the same metadata.

`image` filters every row and compresses it in Dart (or with the platform's
zlib). rapid_image does both in Rust, splitting the image into bands that are
filtered and compressed on every core at once.

## Use

Swap the import. Everything from `package:image` is re-exported.

```dart
// import 'package:image/image.dart';
import 'package:rapid_image/rapid_image.dart';

final png = encodePng(image); // same arguments as image's, plus `parallel`
```

`encodePngFile`, `encodeNamedImage`, `encodeImageFile` and
`findEncoderForNamedImage` are replaced too, and `RapidPngEncoder` is a
`PngEncoder` you can use directly. `recompressPng(bytes)` recompresses PNG
bytes you already have.

On web, `await ensureRapidArchiveInitialized()` once at startup.

## How it stays compatible

- Single-frame 8 and 16-bit images without a palette (grey, grey+alpha, RGB,
  RGBA) take the native path. The filtered bytes are identical to image's,
  and every chunk other than IDAT (IHDR, iCCP, cICP, tEXt, pHYs, IEND) is
  written by image's own encoder, so it is identical byte for byte. Tests
  check both for every filter, level and format.
- Everything else (palettes, 1 to 4-bit, animated PNGs, HDR, and the web)
  uses image's encoder to filter, then recompresses the data with
  [rapid_archive](https://pub.dev/packages/rapid_archive).

Files are within about 1 to 2% of image's size at the same level.

## Speed

Linux x64, 4 cores, image 4.12.0, default level 6:

| Image | image | rapid_image | Speedup |
| --- | --- | --- | --- |
| 4000x3000 photo mosaic | 955 ms | 144 ms | 6.6x |
| 1282x1110 photo | 170 ms | 29 ms | 6.0x |
| 1440x3120 UI screenshot | 198 ms | 26 ms | 7.7x |

On one core (`parallel: false`) it is 2.3 to 3x faster. Level 9 is 3 to 5x
faster. Run `dart run bench/bench.dart some.png` to measure your own images, or
`dart run tool/make_bench_images.dart` first to build the test images used
above in `bench/images/`.

In Chrome there is no native code, so the recompress path is used
(2000x1500 image, level 6):

| Build | image | rapid_image | Speedup |
| --- | --- | --- | --- |
| JavaScript (dart2js) | 1594 ms | 475 ms | 3.4x |
| WebAssembly (dart2wasm) | 2404 ms | 878 ms | 2.7x |

The WebAssembly number needs rapid_archive 0.2.1 or later. Run
`dart test -p chrome bench/web_bench_test.dart` to measure in a browser.

## Native library

Released versions download a prebuilt, checksum-verified library for
Android, iOS, macOS, Linux and Windows from this repo's GitHub Releases, so
apps don't need Rust. Without one, the build hook builds it with cargo. To
force a source build:

```yaml
hooks:
  user_defines:
    rapid_image:
      from_source: true
```
