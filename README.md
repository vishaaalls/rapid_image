# rapid_image

[`package:image`](https://pub.dev/packages/image), faster. Swap one import
and the slow parts (PNG and JPEG encoding and decoding, resizing, rotating,
blurring, colour adjustment) run in Rust, in parallel on every core, with
the same results.

On an Apple M4 with a 12-megapixel photo, PNG encoding is 12x faster, JPEG
decoding 6.5x, blur 14x, colour adjustment up to 64x, and a typical "shrink
a phone photo for upload" flow goes from 483 ms to 51 ms.

## Use

Swap the import. Everything from `package:image` is re-exported.

```dart
// import 'package:image/image.dart';
import 'package:rapid_image/rapid_image.dart';

final photo = decodeJpg(bytes)!;                  // native
final small = copyResize(photo, width: 1080,      // native, same pixels
    interpolation: Interpolation.cubic);
adjustColor(small, contrast: 1.1, saturation: 1.2); // native, same pixels
final jpg = encodeJpg(small, quality: 85);        // native
final png = encodePng(small);                     // native
```

These functions are replaced by native versions with the same names and
arguments: `encodePng`, `decodePng`, `decodeJpg`, `encodeJpg`,
`decodeImage`, `copyResize`, `copyRotate`, `gaussianBlur` and
`adjustColor`, plus the `...File` and named-image variants. `RapidPngEncoder`
and `RapidJpegEncoder` are drop-in `Encoder`s. `recompressPng(bytes)` shrinks
PNG bytes you already have without touching the pixels.

`copyResize` also takes a `filter`, for resampling that stays smooth when
shrinking: `ResizeFilter.lanczos3` (sharpest, the usual choice for photos),
`mitchell`, `catmullRom`, `bilinear` or `box`.

On web, `await ensureRapidImageInitialized()` once at startup (it compiles
the WebAssembly modules; without it the first call compiles synchronously).

### Pipeline

Each drop-in copies the image into native memory and back, which is cheap
(about 2 ms for 12 megapixels) but adds up. `RapidPipeline` keeps the pixels
in native memory between steps:

```dart
final jpg = RapidPipeline.decode(phoneJpeg)  // EXIF orientation applied
    .resize(width: 1080)                     // Lanczos3 by default
    .adjust(contrast: 1.1, saturation: 1.2)
    .encodeJpg(quality: 85);                 // EXIF and ICC profile kept
```

Steps: `resize`, `crop`, `rotate`, `flip`, `adjust`, `blur`, then
`encodeJpg`, `encodePng` or `toImage`. Call `dispose()` when you're done, or
let the finalizer free the memory. It works the same way on the web.

## How it stays compatible

Every function falls back to package:image for anything the native code
doesn't cover, so results are always available: palette images,
16-bit and float images, animations, masks, `blacks`/`whites`/`mids` in
`adjustColor`, letterboxing in `copyResize`, and JPEGs that aren't 8-bit
Huffman-coded.

Where the native code runs:

| Function | Result compared with package:image |
| --- | --- |
| `copyResize` (nearest, linear, cubic, average) | Identical pixels, EXIF orientation applied the same way |
| `copyRotate`, `gaussianBlur`, `adjustColor` | Identical pixels |
| `decodePng` (8-bit grey, grey+alpha, RGB, RGBA) | Identical pixels, ICC profile and text |
| `encodePng` | Identical pixels; every chunk except IDAT identical byte for byte |
| `decodeJpg` 4:4:4 | Within 4 per channel (mean 0.55): IDCT rounding |
| `decodeJpg` 4:2:0 | Within about 20 at colour edges (mean 1.2): chroma is interpolated, as libjpeg and browsers do, where package:image repeats it |
| `encodeJpg` | Different encoder (jpeg-encoder), same quality scale, sizes within a few percent; EXIF and ICC written as package:image writes them; RGBA blended onto the background colour the same way |

The "identical" functions are ports of package:image's own algorithms that
do the same floating-point steps in the same order; the tests compare them
pixel for pixel across channel counts, sizes, angles, radii and parameters.

## Speed

Apple M4 (10 cores), 4000x3000 RGB photo, image 4.12.0
(`dart run bench/ops_bench.dart bench/images/photo_12mp.png`; raw output in
`bench/RESULTS-macos-m4.txt`):

| Operation | image | rapid_image | Speedup |
| --- | --- | --- | --- |
| `decodeJpg` | 270 ms | 41 ms | 6.5x |
| `decodePng` | 243 ms | 96 ms | 2.5x |
| `encodeJpg` quality 85, 4:4:4 | 336 ms | 92 ms | 3.7x |
| `encodeJpg` quality 85, 4:2:0 | 246 ms | 64 ms | 3.8x |
| `encodePng` level 6 | 786 ms | 64 ms | 12.3x |
| `copyResize` to 1/4, cubic | 50 ms | 5 ms | 9.3x |
| `copyResize` to 1/4, average | 48 ms | 3 ms | 14.4x |
| `copyResize` to 1/4, Lanczos3 (new) | n/a | 6 ms | |
| `copyRotate` 90 degrees | 52 ms | 11 ms | 4.9x |
| `copyRotate` 15 degrees, linear | 1891 ms | 33 ms | 57.8x |
| `gaussianBlur` radius 5 | 622 ms | 46 ms | 13.6x |
| `adjustColor` contrast + saturation | 1767 ms | 28 ms | 63.6x |
| `adjustColor` contrast only | 30 ms | 7 ms | 4.2x |
| Upload flow, drop-ins | 483 ms | 56 ms | 8.6x |
| Upload flow, `RapidPipeline` | 483 ms | 51 ms | 9.4x |

The upload flow decodes a JPEG, resizes it to 1080 wide, adjusts contrast
and saturation and encodes a JPEG at quality 85.

PNG encoding on Linux x64, 4 cores, level 6: 6.6x faster on a 4000x3000
photo, 6.0x on 1282x1110 and 7.7x on a 1440x3120 screenshot. Run
`dart run bench/bench.dart some.png` to measure PNG encoding on your own
images, after `dart run tool/make_bench_images.dart` to build the test
images in `bench/images/`.

### Web

In the browser the image operations run as WebAssembly: the same Rust code,
built for wasm32 with SIMD (350 KB, 142 KB gzipped, embedded in the
package), on one thread. The results are the same as natively: the
comparison tests run in Chrome under dart2js and dart2wasm too. Two
differences: high-quality `ResizeFilter` resampling uses a small built-in
resampler instead of fast_image_resize (close, not identical to native), and
PNG encoding uses rapid_archive's WebAssembly compressor.

Chrome on an Apple M4, 2000x1500 RGB image
(`dart test -p chrome [-c dart2wasm] bench/web_ops_bench_test.dart`):

| Operation | image (dart2js) | rapid_image (dart2js) | image (dart2wasm) | rapid_image (dart2wasm) |
| --- | --- | --- | --- | --- |
| `decodeJpg` | 252 ms | 34 ms (7.4x) | 299 ms | 52 ms (5.7x) |
| `decodePng` | 395 ms | 34 ms (11.7x) | 125 ms | 76 ms (1.7x) |
| `encodeJpg` q85 | 94 ms | 30 ms (3.1x) | 275 ms | 60 ms (4.6x) |
| `copyResize` to 1/4, cubic | 21 ms | 7 ms (3.0x) | 87 ms | 37 ms (2.4x) |
| `copyRotate` 15°, linear | 688 ms | 30 ms (22.8x) | 767 ms | 101 ms (7.6x) |
| `gaussianBlur` radius 5 | 273 ms | 58 ms (4.7x) | 997 ms | 115 ms (8.6x) |
| `adjustColor` contrast + saturation | 592 ms | 51 ms (11.7x) | 988 ms | 104 ms (9.5x) |
| Upload flow, `RapidPipeline` | 568 ms | 105 ms (5.4x) | 1085 ms | 88 ms (12.3x) |

Under dart2wasm, copying pixels between Dart and WebAssembly memory costs
about 3 ms per MB each way (dart2js: almost nothing), so the drop-ins gain
less there than `RapidPipeline`, which copies once in and once out.

PNG encoding (2000x1500, level 6):

| Build | image | rapid_image | Speedup |
| --- | --- | --- | --- |
| JavaScript (dart2js) | 1594 ms | 475 ms | 3.4x |
| WebAssembly (dart2wasm) | 2404 ms | 878 ms | 2.7x |

The PNG WebAssembly number needs rapid_archive 0.2.1 or later. Run
`dart test -p chrome bench/web_bench_test.dart` to measure it.

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

The Rust code uses [zune-jpeg](https://crates.io/crates/zune-jpeg),
[jpeg-encoder](https://crates.io/crates/jpeg-encoder),
[png](https://crates.io/crates/png),
[fast_image_resize](https://crates.io/crates/fast_image_resize),
[libdeflate](https://github.com/ebiggers/libdeflate) and
[rayon](https://crates.io/crates/rayon).
