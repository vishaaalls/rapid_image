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
