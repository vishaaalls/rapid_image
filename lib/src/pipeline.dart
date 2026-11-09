// RapidPipeline: decode, transform and encode an image with its pixels kept
// in native memory between steps. On the web it runs the same steps with
// package:image.

import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'encoder.dart';
import 'native_ops.dart';
import 'native_stub.dart' if (dart.library.ffi) 'native_ffi.dart';
import 'ops.dart';

/// A chain of image operations that keeps the pixels in native memory, so
/// nothing is copied back to Dart until the end:
///
/// ```dart
/// final jpg = RapidPipeline.decode(photoBytes)
///     .resize(width: 1080)
///     .adjust(contrast: 1.1, saturation: 1.2)
///     .encodeJpg(quality: 85);
/// ```
///
/// Each step changes this pipeline and returns it. The EXIF data (without
/// its orientation, which decoding applies to the pixels), ICC profile and
/// PNG text are carried through to the output. Call [dispose] when done to
/// free the native memory at once; a finalizer frees it otherwise.
///
/// On the web the same steps run with package:image.
class RapidPipeline {
  NativeImage? _native;
  img.Image? _dart;
  img.ExifData _exif;
  img.IccProfile? _icc;
  Map<String, String>? _text;

  RapidPipeline._native(NativeImage n, this._exif, this._icc, this._text)
      : _native = n;

  RapidPipeline._dart(img.Image d)
      : _dart = d,
        _exif = img.ExifData.from(d.exif),
        _icc = d.iccProfile,
        _text = d.textData == null ? null : Map.of(d.textData!);

  /// Decodes JPEG, PNG or any format package:image reads. A JPEG's EXIF
  /// orientation is applied to the pixels. Throws a [FormatException] if
  /// the data isn't an image.
  factory RapidPipeline.decode(Uint8List bytes) {
    final j = decodeJpegNative(bytes);
    if (j != null) return RapidPipeline._native(j.pixels, j.exif, j.icc, null);
    final p = decodePngNative(bytes);
    if (p != null) {
      final (n, meta) = p;
      return RapidPipeline._native(
          n, img.ExifData(), meta.icc, meta.text.isEmpty ? null : meta.text);
    }
    final d = decodeImage(bytes);
    if (d == null)
      throw const FormatException('Not an image rapid_image can read');
    return RapidPipeline.fromImage(d);
  }

  /// Starts from a package:image [image] (its first frame). Images that
  /// aren't 8-bit are converted to 8-bit.
  factory RapidPipeline.fromImage(img.Image image) {
    var src =
        image.numFrames > 1 ? img.Image.from(image, noAnimation: true) : image;
    if (nativeOps == null)
      return RapidPipeline._dart(src.clone(noAnimation: true));
    if (!nativeCompatible(src)) {
      src = src.convert(
          format: img.Format.uint8,
          numChannels: src.hasPalette
              ? src.palette!.numChannels
              : src.numChannels.clamp(1, 4),
          noAnimation: true);
    }
    if (!nativeCompatible(src))
      return RapidPipeline._dart(src.clone(noAnimation: true));
    return RapidPipeline._native(
        toNative(src),
        img.ExifData.from(image.exif),
        image.iccProfile?.clone(),
        image.textData == null ? null : Map.of(image.textData!));
  }

  NativeImage get _n {
    final n = _native;
    if (n == null) throw StateError('rapid_image: pipeline already disposed');
    return n;
  }

  bool get _isNative => _dart == null;

  void _replace(NativeImage n) {
    _native?.dispose();
    _native = n;
  }

  int get width => _isNative ? _n.width : _dart!.width;
  int get height => _isNative ? _n.height : _dart!.height;
  int get numChannels => _isNative ? _n.channels : _dart!.numChannels;

  /// Resizes to [width] x [height]. Give one of them to keep the aspect
  /// ratio. [filter] defaults to Lanczos3, the usual choice for photos.
  RapidPipeline resize(
      {int? width, int? height, ResizeFilter filter = ResizeFilter.lanczos3}) {
    if (width == null && height == null) {
      throw ArgumentError('Give a width, a height or both');
    }
    final w0 = this.width, h0 = this.height;
    final w = width ?? (height! * (w0 / h0)).round();
    final h = height ?? (width! * (h0 / w0)).round();
    if (w < 1 || h < 1) throw ArgumentError('Size must be at least 1x1');
    if (w == w0 && h == h0) return this;
    if (_isNative) {
      _replace(nativeOps!.resize(_n, w, h, filter.code));
    } else {
      _dart = img.copyResize(_dart!,
          width: w, height: h, interpolation: filter.fallback);
    }
    return this;
  }

  /// Keeps the [width] x [height] region at ([x], [y]), clipped to the image.
  RapidPipeline crop(int x, int y, int width, int height) {
    if (_isNative) {
      _replace(nativeOps!.crop(_n, x, y, width, height));
    } else {
      _dart = img.copyCrop(_dart!, x: x, y: y, width: width, height: height);
    }
    return this;
  }

  /// Rotates by [angle] degrees. Right angles are exact; other angles grow
  /// the canvas to fit, with transparent (or black) corners.
  RapidPipeline rotate(num angle,
      {img.Interpolation interpolation = img.Interpolation.linear}) {
    if (_isNative) {
      final code = interpolation == img.Interpolation.cubic
          ? 2
          : interpolation == img.Interpolation.nearest
              ? 0
              : 1;
      _replace(nativeOps!.rotate(_n, angle.toDouble(), code));
    } else {
      _dart =
          img.copyRotate(_dart!, angle: angle, interpolation: interpolation);
    }
    return this;
  }

  /// Flips horizontally, vertically or both.
  RapidPipeline flip(img.FlipDirection direction) {
    if (_isNative) {
      nativeOps!.flip(_n, direction.index);
    } else {
      img.flip(_dart!, direction: direction);
    }
    return this;
  }

  /// adjustColor's colour adjustments; see package:image's `adjustColor`.
  RapidPipeline adjust(
      {num? contrast,
      num? saturation,
      num? brightness,
      num? gamma,
      num? exposure,
      num? hue,
      num amount = 1}) {
    if (_isNative && _n.channels >= 3) {
      nativeOps!.adjust(_n,
          contrast: contrast?.toDouble(),
          saturation: saturation?.toDouble(),
          brightness: brightness?.toDouble(),
          gamma: gamma?.toDouble(),
          exposure: exposure?.toDouble(),
          hue: hue?.toDouble(),
          amount: amount.toDouble());
    } else {
      final d = _isNative ? fromNative(_n) : _dart!;
      img.adjustColor(d,
          contrast: contrast,
          saturation: saturation,
          brightness: brightness,
          gamma: gamma,
          exposure: exposure,
          hue: hue,
          amount: amount);
      if (_isNative) {
        _replace(toNative(d));
      } else {
        _dart = d;
      }
    }
    return this;
  }

  /// Gaussian blur; see package:image's `gaussianBlur`.
  RapidPipeline blur(int radius) {
    if (_isNative) {
      nativeOps!.blur(_n, radius);
    } else {
      img.gaussianBlur(_dart!, radius: radius);
    }
    return this;
  }

  /// Encodes to JPEG at [quality] (1 to 100). [chroma] defaults to 4:4:4,
  /// like package:image; [img.JpegChroma.yuv420] gives smaller files.
  Uint8List encodeJpg(
      {int quality = 90, img.JpegChroma chroma = img.JpegChroma.yuv444}) {
    if (_isNative && _n.channels >= 3) {
      final (app1, app2) = jpegSegments(_exif, _icc);
      final out = nativeOps!.encodeJpeg(_n,
          quality: quality,
          chroma420: chroma == img.JpegChroma.yuv420,
          background: const [255, 255, 255],
          app1: app1,
          app2: app2);
      if (out != null) return out;
    }
    return _encodeJpg(toImage(), quality, chroma);
  }

  /// Encodes to PNG with rapid_image's encoder.
  Uint8List encodePng(
          {int level = 6, img.PngFilter filter = img.PngFilter.paeth}) =>
      RapidPngEncoder(level: level, filter: filter).encode(toImage());

  /// A package:image copy of the current pixels and metadata. The pipeline
  /// stays usable.
  img.Image toImage() {
    final out = _isNative ? fromNative(_n) : _dart!.clone();
    out
      ..exif = img.ExifData.from(_exif)
      ..iccProfile = _icc;
    if (_text != null) out.addTextData(_text!);
    return out;
  }

  /// Frees the native pixels. The pipeline can't be used afterwards.
  void dispose() {
    _native?.dispose();
    _native = null;
  }
}

// Avoids the name clash with RapidPipeline.encodeJpg.
Uint8List _encodeJpg(img.Image i, int quality, img.JpegChroma chroma) =>
    encodeJpg(i, quality: quality, chroma: chroma);
