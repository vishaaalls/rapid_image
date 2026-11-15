// The native image operations, as seen by the Dart code. native_ffi.dart
// implements this with the Rust library; on the web (native_stub.dart)
// there is no implementation and callers use package:image instead.

import 'dart:typed_data';

/// An 8-bit image held by the native library: `width * height * channels`
/// bytes, rows packed. Release it with [dispose] (a finalizer also frees it
/// if it's dropped).
abstract class NativeImage {
  int get width;
  int get height;
  int get channels;

  /// Copies the pixels into [dst], which must hold exactly
  /// `width * height * channels` bytes.
  void readInto(Uint8List dst);

  void dispose();
}

abstract class NativeOps {
  /// Copies packed 8-bit pixels into a native image.
  NativeImage fromPixels(Uint8List pixels, int width, int height, int channels);

  /// Decodes a JPEG to RGB with EXIF [orientation] applied, or returns null
  /// if the native decoder can't read it.
  NativeImage? decodeJpeg(Uint8List bytes, int orientation);

  /// Decodes an 8-bit grey/grey+alpha/RGB/RGBA PNG, or returns null.
  NativeImage? decodePng(Uint8List bytes);

  /// Encodes a 3 or 4 channel image (4: blended onto [background]) to JPEG,
  /// or returns null if it can't.
  Uint8List? encodeJpeg(NativeImage image,
      {required int quality,
      required bool chroma420,
      required List<int> background,
      Uint8List? app1,
      Uint8List? app2});

  /// [mode]: 0 nearest, 1 linear, 2 cubic, 3 average (package:image's
  /// algorithms), 10 box, 11 bilinear, 12 Catmull-Rom, 13 Mitchell,
  /// 14 Lanczos3. [orientation] (EXIF) is applied first.
  NativeImage resize(NativeImage image, int width, int height, int mode,
      {int orientation = 1});

  NativeImage orient(NativeImage image, int orientation);

  /// [interpolation]: 0 nearest, 1 linear, 2 cubic.
  NativeImage rotate(NativeImage image, double angle, int interpolation);

  NativeImage crop(NativeImage image, int x, int y, int width, int height);

  /// 0 horizontal, 1 vertical, 2 both. In place.
  void flip(NativeImage image, int direction);

  /// In place.
  void blur(NativeImage image, int radius);

  /// In place; 3 or 4 channel images only. Returns false if unsupported.
  bool adjust(NativeImage image,
      {double? contrast,
      double? saturation,
      double? brightness,
      double? gamma,
      double? exposure,
      double? hue,
      double amount = 1});
}
