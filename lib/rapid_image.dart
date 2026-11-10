/// package:image, faster.
///
/// Import this instead of `package:image/image.dart`. Everything image offers
/// is re-exported, and these are replaced by native (Rust) versions where
/// the native library supports the image, falling back to package:image
/// otherwise:
///
/// * PNG: `encodePng` (same bytes around the image data, same pixels) and
///   `decodePng` (same pixels and metadata).
/// * JPEG: `decodeJpg`, `encodeJpg` (and `decodeImage` for both formats).
/// * `copyResize`, `copyRotate`, `gaussianBlur`, `adjustColor`: the same
///   pixels as package:image, computed in parallel. `copyResize` also takes
///   a high-quality [ResizeFilter].
///
/// [RapidPipeline] chains decode, resize, adjust and encode while keeping the
/// pixels in native memory, which is fastest.
///
/// On web, await [ensureRapidImageInitialized] once at startup.
library;

import 'dart:typed_data';

import 'package:image/image.dart'
    hide decodeJpg, encodeJpg, decodePng, decodeImage;
import 'package:image/image.dart' as image_lib
    show findEncoderForNamedImage, decodeNamedImage;

import 'src/encoder.dart';
import 'src/ops.dart';

export 'package:image/image.dart'
    hide
        encodePng,
        encodePngFile,
        encodeNamedImage,
        encodeImageFile,
        findEncoderForNamedImage,
        decodeJpg,
        decodeJpgFile,
        encodeJpg,
        encodeJpgFile,
        decodePng,
        decodePngFile,
        decodeImage,
        decodeImageFile,
        copyResize,
        copyRotate,
        gaussianBlur,
        adjustColor;
export 'package:rapid_archive/rapid_archive.dart'
    show ensureRapidArchiveInitialized;
export 'src/native_stub.dart'
    if (dart.library.ffi) 'src/native_ffi.dart'
    if (dart.library.js_interop) 'src/native_web.dart'
    show ensureRapidImageInitialized;

export 'src/encoder.dart';
export 'src/ops.dart'
    show
        ResizeFilter,
        RapidJpegEncoder,
        decodeJpg,
        encodeJpg,
        decodePng,
        decodeImage,
        copyResize,
        copyRotate,
        gaussianBlur,
        adjustColor;
export 'src/pipeline.dart';
export 'src/png_recompress.dart';

/// Encodes [image] to PNG, like image's `encodePng`, but faster.
///
/// [parallel] compresses on every core; turn it off for output that is about
/// 1% smaller.
Uint8List encodePng(Image image,
        {bool singleFrame = false,
        int level = 6,
        PngFilter filter = PngFilter.paeth,
        PngCicpData? cicpData,
        bool parallel = true}) =>
    RapidPngEncoder(
            filter: filter,
            level: level,
            cicpData: cicpData,
            parallel: parallel)
        .encode(image, singleFrame: singleFrame);

/// Encodes [image] to a PNG file at [path], like image's `encodePngFile`.
Future<bool> encodePngFile(String path, Image image,
    {bool singleFrame = false,
    int level = 6,
    PngFilter filter = PngFilter.paeth,
    bool parallel = true}) async {
  if (!supportsFileAccess()) {
    return false;
  }
  return writeFile(
      path,
      encodePng(image,
          singleFrame: singleFrame,
          level: level,
          filter: filter,
          parallel: parallel));
}

/// image's `findEncoderForNamedImage`, returning a [RapidPngEncoder] for
/// `.png` names and a [RapidJpegEncoder] for `.jpg` and `.jpeg`.
Encoder? findEncoderForNamedImage(String name) {
  final n = name.toLowerCase();
  if (n.endsWith('.png')) return RapidPngEncoder();
  if (n.endsWith('.jpg') || n.endsWith('.jpeg')) return RapidJpegEncoder();
  return image_lib.findEncoderForNamedImage(name);
}

/// image's `encodeNamedImage`, with fast PNG encoding.
Uint8List? encodeNamedImage(String path, Image image) =>
    findEncoderForNamedImage(path)?.encode(image);

/// image's `encodeImageFile`, with fast PNG encoding.
Future<bool> encodeImageFile(String path, Image image) async {
  if (!supportsFileAccess()) {
    return false;
  }
  final encoder = findEncoderForNamedImage(path);
  if (encoder == null) {
    return false;
  }
  return writeFile(path, encoder.encode(image));
}

/// image's `decodeJpgFile`, with native decoding.
Future<Image?> decodeJpgFile(String path,
    {int? maxPixels, int scale = 1}) async {
  final bytes = await readFile(path);
  return bytes == null
      ? null
      : decodeJpg(bytes, maxPixels: maxPixels, scale: scale);
}

/// image's `encodeJpgFile`, with native encoding.
Future<bool> encodeJpgFile(String path, Image image,
    {int quality = 100, JpegChroma chroma = JpegChroma.yuv444}) async {
  if (!supportsFileAccess()) {
    return false;
  }
  return writeFile(path, encodeJpg(image, quality: quality, chroma: chroma));
}

/// image's `decodePngFile`, with native decoding.
Future<Image?> decodePngFile(String path) async {
  final bytes = await readFile(path);
  return bytes == null ? null : decodePng(bytes);
}

/// image's `decodeImageFile`, with native JPEG and PNG decoding.
Future<Image?> decodeImageFile(String path, {int? frame}) async {
  final bytes = await readFile(path);
  if (bytes == null) return null;
  final n = path.toLowerCase();
  if (n.endsWith('.jpg') || n.endsWith('.jpeg') || n.endsWith('.png')) {
    return decodeImage(bytes, frame: frame);
  }
  return image_lib.decodeNamedImage(path, bytes, frame: frame);
}
