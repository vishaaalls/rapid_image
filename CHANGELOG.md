## 0.3.0

* Native (Rust) drop-ins for more of package:image, with the same names and
  arguments, falling back to package:image wherever they don't apply:
  * `decodeJpg` (zune-jpeg, EXIF orientation applied as image does),
    `encodeJpg` and `RapidJpegEncoder` (jpeg-encoder; 4:4:4 by default like
    image, `JpegChroma.yuv420` for smaller files), `decodePng`, `decodeImage`
    and the `...File` variants.
  * `copyResize`, `copyRotate`, `gaussianBlur` and `adjustColor`, ported
    from package:image's algorithms and run in parallel: identical pixels.
  * `copyResize(filter: ResizeFilter.lanczos3)` and other high-quality
    resampling filters (fast_image_resize).
* `RapidPipeline`: decode, resize, crop, rotate, flip, adjust, blur and
  encode with the pixels kept in native memory, carrying EXIF, ICC and PNG
  text through. Works on the web with package:image.
* Apple M4, 12 MP photo: JPEG decode 6.5x faster, blur 14x, adjustColor up
  to 64x, rotate up to 58x; a decode-resize-adjust-encode upload flow 9.4x
  (bench/RESULTS-macos-m4.txt).

## 0.2.0

* PNG rows are now filtered and compressed in Rust, in parallel bands, for
  single-frame 8 and 16-bit images without a palette: about 6x faster than
  image at level 6 on 4 cores. Filtered data and metadata chunks are
  identical to image's.
* Other images keep the 0.1.0 path.
* Requires the native library (prebuilt from GitHub Releases, or built with
  cargo).

## 0.1.0

* First version: `encodePng`, `encodePngFile`, `encodeNamedImage`,
  `encodeImageFile` and `RapidPngEncoder`, which compress PNG data with
  rapid_archive (libdeflate, in parallel), plus `recompressPng` for existing
  PNG bytes. Output decodes to exactly the same pixels as image's.
