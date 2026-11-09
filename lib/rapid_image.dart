/// package:image with faster PNG encoding.
///
/// Import this instead of `package:image/image.dart`. Everything image offers
/// is re-exported, and the PNG encoding functions are replaced by versions
/// that compress with rapid_archive (libdeflate, in parallel). The output
/// decodes to exactly the same pixels.
///
/// On web, await [ensureRapidArchiveInitialized] once at startup before
/// encoding.
library;

import 'dart:typed_data';

import 'package:image/image.dart';
import 'package:image/image.dart' as image_lib show findEncoderForNamedImage;

import 'src/encoder.dart';

export 'package:image/image.dart'
    hide
        encodePng,
        encodePngFile,
        encodeNamedImage,
        encodeImageFile,
        findEncoderForNamedImage;
export 'package:rapid_archive/rapid_archive.dart'
    show ensureRapidArchiveInitialized;

export 'src/encoder.dart';
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
/// `.png` names.
Encoder? findEncoderForNamedImage(String name) =>
    name.toLowerCase().endsWith('.png')
        ? RapidPngEncoder()
        : image_lib.findEncoderForNamedImage(name);

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
