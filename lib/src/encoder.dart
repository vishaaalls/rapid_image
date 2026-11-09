import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'fast_png.dart';
import 'png_recompress.dart';

/// A [img.PngEncoder] that filters and compresses natively.
///
/// Single-frame 8 and 16-bit images without a palette (the common case) are
/// filtered and compressed in Rust, in parallel on every core, with the
/// surrounding chunks written by image itself. Everything else (palettes,
/// 1 to 4-bit, APNG, HDR, the web) uses image's own encoder to filter, then
/// recompresses its data with rapid_archive.
class RapidPngEncoder extends img.PngEncoder {
  /// Whether to compress on every core, at levels 3 and up. The output is a
  /// little larger (about 1%) than with [parallel] off.
  final bool parallel;

  RapidPngEncoder(
      {super.filter,
      super.level,
      super.pixelDimensions,
      super.cicpData,
      this.parallel = true});

  @override
  Uint8List encode(img.Image image, {bool singleFrame = false}) {
    if (singleFrame || image.numFrames == 1) {
      final fast = encodePngNative(image,
          filter: filter,
          level: level ?? 6,
          parallel: parallel,
          pixelDimensions: pixelDimensions,
          cicpData: cicpData);
      if (fast != null) return fast;
    }
    return super.encode(image, singleFrame: singleFrame);
  }

  @override
  void addFrame(img.Image image) {
    final target = level;
    level = 0;
    try {
      super.addFrame(image);
    } finally {
      level = target;
    }
  }

  @override
  Uint8List? finish() {
    final bytes = super.finish();
    final l = level ?? 6;
    if (bytes == null || l == 0) return bytes;
    // Parallel compression at levels 1 and 2 gives much larger files (about
    // 35% on photos), so those levels always use one core.
    return recompressPng(bytes,
        level: l > 9 ? 9 : l, parallel: parallel && l >= 3);
  }
}
