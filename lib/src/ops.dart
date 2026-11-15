// Drop-in replacements for package:image functions, backed by the native
// library where it applies and by package:image everywhere else (web,
// palettes, 16-bit and float images, animations, masks, unusual JPEGs).

import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'native_ops.dart';
import 'native_stub.dart'
    if (dart.library.ffi) 'native_ffi.dart'
    if (dart.library.js_interop) 'native_web.dart';

/// Resampling filters for [copyResize]'s `filter` argument and
/// `RapidPipeline.resize`. These go beyond package:image's
/// [img.Interpolation]: they filter over the whole area each output pixel
/// covers, so downscaled images stay smooth instead of aliasing.
enum ResizeFilter {
  /// Averages the source pixels each output pixel covers.
  box(10, img.Interpolation.average),

  /// A tent filter: smooth, slightly soft.
  bilinear(11, img.Interpolation.linear),

  /// Catmull-Rom cubic: sharp.
  catmullRom(12, img.Interpolation.cubic),

  /// Mitchell-Netravali cubic: a balance of sharpness and smoothness.
  mitchell(13, img.Interpolation.cubic),

  /// Lanczos with 3 lobes: the sharpest; the usual choice for photos.
  lanczos3(14, img.Interpolation.cubic);

  const ResizeFilter(this.code, this.fallback);

  /// The native mode number.
  final int code;

  /// The closest package:image interpolation, used where there is no native
  /// code (the web).
  final img.Interpolation fallback;
}

/// Whether the native code can work on [image] directly: one frame of
/// unpadded 8-bit pixels with 1 to 4 channels and no palette.
bool nativeCompatible(img.Image image) {
  final d = image.data;
  return nativeOps != null &&
      d != null &&
      image.format == img.Format.uint8 &&
      !image.hasPalette &&
      image.numFrames == 1 &&
      image.numChannels >= 1 &&
      image.numChannels <= 4 &&
      image.width > 0 &&
      image.height > 0 &&
      d.rowStride == image.width * image.numChannels;
}

NativeImage toNative(img.Image image) => nativeOps!.fromPixels(
    image.toUint8List(), image.width, image.height, image.numChannels);

/// A new image holding [n]'s pixels, with [like]'s metadata (EXIF, ICC
/// profile, text) as package:image's copyResize and copyRotate give.
img.Image fromNative(NativeImage n, {img.Image? like}) {
  final out = like != null && like.numChannels == n.channels
      ? img.Image.fromResized(like,
          width: n.width, height: n.height, noAnimation: true)
      : img.Image(width: n.width, height: n.height, numChannels: n.channels);
  if (like != null && like.numChannels != n.channels) {
    out
      ..exif = img.ExifData.from(like.exif)
      ..iccProfile = like.iccProfile?.clone();
    if (like.textData != null) out.addTextData(like.textData!);
  }
  n.readInto(out.toUint8List());
  return out;
}

int _interpCode(img.Interpolation i) => switch (i) {
      img.Interpolation.nearest => 0,
      img.Interpolation.linear => 1,
      img.Interpolation.cubic => 2,
      img.Interpolation.average => 3,
    };

// ---------------------------------------------------------------------------
// JPEG
// ---------------------------------------------------------------------------

class _JpegHeader {
  final int width, height, components;
  _JpegHeader(this.width, this.height, this.components);
}

/// Reads the frame header of a baseline, extended or progressive 8-bit
/// Huffman JPEG. Returns null for anything else (arithmetic coding,
/// lossless, 12-bit), which then goes to package:image.
_JpegHeader? _jpegHeader(Uint8List b) {
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
  var i = 2;
  while (i + 4 <= b.length) {
    if (b[i] != 0xFF) return null;
    final m = b[i + 1];
    if (m == 0xFF) {
      i++;
      continue;
    }
    if (m == 0xD8 || (m >= 0xD0 && m <= 0xD7) || m == 0x01) {
      i += 2;
      continue;
    }
    if (m == 0xD9 || m == 0xDA) return null;
    final len = (b[i + 2] << 8) | b[i + 3];
    if (m == 0xC0 || m == 0xC1 || m == 0xC2) {
      if (i + 10 > b.length || b[i + 4] != 8) return null;
      return _JpegHeader(
          (b[i + 7] << 8) | b[i + 8], (b[i + 5] << 8) | b[i + 6], b[i + 9]);
    }
    if (m >= 0xC3 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC) {
      return null;
    }
    i += 2 + len;
  }
  return null;
}

const _iccSignature = [73, 67, 67, 95, 80, 82, 79, 70, 73, 76, 69, 0];

/// The ICC profile as package:image (4.13 and later) and libjpeg read it:
/// APP2 "ICC_PROFILE" segments, each with a 1-based sequence number and the
/// number of segments, joined in order. A count that differs between
/// segments, a repeated or out-of-range sequence number, or a missing part
/// gives no profile. Segments written by package:image before 4.13 (the
/// profile directly after the signature, with no numbers) are read too.
img.IccProfile? _jpegIcc(Uint8List b) {
  final parts = <int, Uint8List>{};
  var count = 0;
  var valid = true;
  var i = 2;
  while (i + 4 <= b.length && b[i] == 0xFF) {
    final m = b[i + 1];
    if (m == 0xDA || m == 0xD9) break;
    if (m == 0xFF) {
      i++;
      continue;
    }
    final len = (b[i + 2] << 8) | b[i + 3];
    final end = i + 2 + len;
    if (end > b.length) break;
    if (m == 0xE2 && len >= 16) {
      var ok = true;
      for (var k = 0; k < 12; k++) {
        if (b[i + 4 + k] != _iccSignature[k]) {
          ok = false;
          break;
        }
      }
      if (ok) {
        final data = Uint8List.sublistView(b, i + 16, end);
        // Unsplit (pre-4.13 package:image): the profile starts with its own
        // big-endian size, so the would-be sequence number is 0.
        final unsplit = data.length >= 4 &&
            data[0] == 0 &&
            ByteData.sublistView(data).getUint32(0) == data.length;
        final seq = unsplit ? 1 : data[0];
        final n = unsplit ? 1 : (data.length >= 2 ? data[1] : 0);
        final part = unsplit ? data : Uint8List.sublistView(data, 2);
        if (count == 0) count = n;
        if (seq == 0 || seq > n || n != count || parts.containsKey(seq)) {
          valid = false;
        } else {
          parts[seq] = part;
        }
      }
    }
    i = end;
  }
  if (!valid || parts.isEmpty || parts.length != count) return null;
  final out = BytesBuilder(copy: false);
  for (var k = 1; k <= count; k++) {
    out.add(parts[k]!);
  }
  return img.IccProfile(
      'ICC_PROFILE', img.IccProfileCompression.none, out.takeBytes());
}

/// The result of a native JPEG decode: pixels with the EXIF orientation
/// applied, the EXIF data without its orientation, and the ICC profile.
class NativeJpeg {
  final NativeImage pixels;
  final img.ExifData exif;
  final img.IccProfile? icc;
  NativeJpeg(this.pixels, this.exif, this.icc);
}

NativeJpeg? decodeJpegNative(Uint8List bytes, {int? maxPixels}) {
  final ops = nativeOps;
  if (ops == null) return null;
  final h = _jpegHeader(bytes);
  if (h == null || (h.components != 1 && h.components != 3)) return null;
  if (h.width * h.height > (maxPixels ?? img.Decoder.defaultMaxPixels)) {
    return null;
  }
  final exif = img.decodeJpgExif(bytes) ?? img.ExifData();
  final o = exif.imageIfd.hasOrientation ? exif.imageIfd.orientation! : 1;
  final n = ops.decodeJpeg(bytes, o);
  if (n == null) return null;
  final e = img.ExifData.from(exif)..imageIfd.orientation = null;
  return NativeJpeg(n, e, _jpegIcc(bytes));
}

/// Decodes a JPEG, like package:image's `decodeJpg` (the EXIF orientation is
/// applied to the pixels and removed from the EXIF data), but about 8x
/// faster natively.
img.Image? decodeJpg(Uint8List bytes, {int? maxPixels, int scale = 1}) {
  if (scale == 1) {
    final j = decodeJpegNative(bytes, maxPixels: maxPixels);
    if (j != null) {
      final out = fromNative(j.pixels)
        ..exif = j.exif
        ..iccProfile = j.icc;
      j.pixels.dispose();
      return out;
    }
  }
  return img.decodeJpg(bytes, maxPixels: maxPixels, scale: scale);
}

/// The APP1 (EXIF) segment body package:image's JPEG encoder writes.
Uint8List? _exifSegment(img.ExifData exif) {
  if (exif.isEmpty) return null;
  final o = img.OutputBuffer();
  exif.write(o);
  final b = o.getBytes();
  return Uint8List(6 + b.length)
    ..setAll(0, const [0x45, 0x78, 0x69, 0x66, 0, 0])
    ..setAll(6, b);
}

// An APP2 segment holds 65535 bytes, less the length (2), the signature (12),
// the sequence number and the count (2).
const _maxIccPart = 65535 - 16;

/// The APP2 segment bodies for [icc], in the standard (ICC.1, libjpeg)
/// layout package:image 4.13 writes: signature, sequence number, count, part.
List<Uint8List> _iccSegments(img.IccProfile? icc) {
  if (icc == null) return const [];
  final d = icc.decompressed();
  final n = (d.length + _maxIccPart - 1) ~/ _maxIccPart;
  if (n > 255) throw img.ImageException('ICC profile is too large for a JPEG');
  return [
    for (var k = 0; k < n; k++)
      () {
        final start = k * _maxIccPart;
        final end =
            start + _maxIccPart < d.length ? start + _maxIccPart : d.length;
        return Uint8List(14 + end - start)
          ..setAll(0, _iccSignature)
          ..[12] = k + 1
          ..[13] = n
          ..setRange(14, 14 + end - start, d, start);
      }()
  ];
}

/// Inserts APP2 [segments] after the APPn segments at the start of [jpg].
Uint8List _insertApp2(Uint8List jpg, List<Uint8List> segments) {
  var at = 2;
  while (at + 4 <= jpg.length &&
      jpg[at] == 0xFF &&
      jpg[at + 1] >= 0xE0 &&
      jpg[at + 1] <= 0xEF) {
    at += 2 + ((jpg[at + 2] << 8) | jpg[at + 3]);
  }
  final out = BytesBuilder(copy: false)..add(Uint8List.sublistView(jpg, 0, at));
  for (final s in segments) {
    final len = s.length + 2;
    out
      ..add([0xFF, 0xE2, len >> 8, len & 0xFF])
      ..add(s);
  }
  out.add(Uint8List.sublistView(jpg, at));
  return out.takeBytes();
}

/// Encodes [n] to JPEG natively with package:image's EXIF and ICC segments.
/// Returns null if the native encoder can't (the caller falls back).
Uint8List? encodeJpegWithMeta(NativeImage n,
    {required int quality,
    required bool chroma420,
    required List<int> background,
    required img.ExifData exif,
    img.IccProfile? icc}) {
  final icc2 = _iccSegments(icc);
  // A profile that fits in one segment goes through the encoder; a larger
  // one is spliced in after it.
  final out = nativeOps!.encodeJpeg(n,
      quality: quality,
      chroma420: chroma420,
      background: background,
      app1: _exifSegment(exif),
      app2: icc2.length == 1 ? icc2.first : null);
  if (out == null || icc2.length <= 1) return out;
  return _insertApp2(out, icc2);
}

List<int> _background(img.Color? c) => c == null
    ? const [255, 255, 255]
    : [
        c.r.clamp(0, 255).round(),
        c.g.clamp(0, 255).round(),
        c.b.clamp(0, 255).round()
      ];

/// A [img.JpegEncoder] that encodes natively (jpeg-encoder) where it can:
/// 8-bit RGB and RGBA images. RGBA is blended onto the image's background
/// colour (white by default), and the EXIF data and ICC profile are written
/// as package:image writes them.
class RapidJpegEncoder extends img.JpegEncoder {
  final int _quality;

  RapidJpegEncoder({int quality = 100})
      : _quality = quality,
        super(quality: quality);

  @override
  Uint8List encode(img.Image image,
      {img.JpegChroma chroma = img.JpegChroma.yuv444,
      bool singleFrame = false}) {
    final ops = nativeOps;
    if (ops != null &&
        nativeCompatible(image) &&
        image.numChannels >= 3 &&
        image.width <= 65535 &&
        image.height <= 65535) {
      final n = toNative(image);
      try {
        final out = encodeJpegWithMeta(n,
            quality: _quality,
            chroma420: chroma == img.JpegChroma.yuv420,
            background: _background(image.backgroundColor),
            exif: image.exif,
            icc: image.iccProfile);
        if (out != null) return out;
      } finally {
        n.dispose();
      }
    }
    return super.encode(image, chroma: chroma, singleFrame: singleFrame);
  }
}

/// Encodes [image] to JPEG, like package:image's `encodeJpg`, natively for
/// 8-bit RGB(A) images. [chroma] keeps image's default, 4:4:4; pass
/// [img.JpegChroma.yuv420] for smaller files (what cameras and browsers use).
Uint8List encodeJpg(img.Image image,
        {int quality = 100, img.JpegChroma chroma = img.JpegChroma.yuv444}) =>
    RapidJpegEncoder(quality: quality).encode(image, chroma: chroma);

// ---------------------------------------------------------------------------
// PNG decoding
// ---------------------------------------------------------------------------

/// The metadata package:image attaches to a decoded PNG.
class PngMeta {
  final img.IccProfile? icc;
  final Map<String, String> text;
  PngMeta(this.icc, this.text);
}

(NativeImage, PngMeta)? decodePngNative(Uint8List bytes) {
  final ops = nativeOps;
  if (ops == null) return null;
  final info = img.PngDecoder().startDecode(bytes);
  if (info is! img.PngInfo ||
      info.isAnimated ||
      info.bits != 8 ||
      info.transparency != null ||
      !const [0, 2, 4, 6].contains(info.colorType) ||
      info.width * info.height > img.Decoder.defaultMaxPixels) {
    return null;
  }
  final n = ops.decodePng(bytes);
  if (n == null) return null;
  final icc = info.iccpData == null
      ? null
      : img.IccProfile(
          info.iccpName, img.IccProfileCompression.deflate, info.iccpData!);
  return (n, PngMeta(icc, Map.of(info.textData)));
}

/// Decodes a PNG, like package:image's `decodePng`. 8-bit images without a
/// palette or transparency chunk decode natively, giving the same pixels and
/// metadata; others use package:image.
img.Image? decodePng(Uint8List bytes, {int? frame}) {
  if (frame == null || frame == 0) {
    final r = decodePngNative(bytes);
    if (r != null) {
      final (n, meta) = r;
      final out = fromNative(n)..iccProfile = meta.icc;
      if (meta.text.isNotEmpty) out.addTextData(meta.text);
      n.dispose();
      return out;
    }
  }
  return img.decodePng(bytes, frame: frame);
}

bool _isJpeg(Uint8List b) =>
    b.length > 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF;

bool _isPng(Uint8List b) =>
    b.length > 8 &&
    b[0] == 0x89 &&
    b[1] == 0x50 &&
    b[2] == 0x4E &&
    b[3] == 0x47;

/// package:image's `decodeImage`, with native JPEG and PNG decoding.
img.Image? decodeImage(Uint8List data, {int? frame}) {
  if (_isJpeg(data)) {
    final r = decodeJpg(data);
    if (r != null) return r;
  } else if (_isPng(data)) {
    return decodePng(data, frame: frame);
  }
  return img.decodeImage(data, frame: frame);
}

// ---------------------------------------------------------------------------
// Transforms and filters
// ---------------------------------------------------------------------------

/// Returns a resized copy of [src], like package:image's `copyResize` (same
/// sizes, same pixels for each [interpolation], EXIF orientation applied),
/// natively and in parallel.
///
/// [filter] picks a high-quality resampling filter instead of
/// [interpolation]; [ResizeFilter.lanczos3] is the usual choice for photos.
img.Image copyResize(img.Image src,
    {int? width,
    int? height,
    bool? maintainAspect,
    img.Color? backgroundColor,
    img.Interpolation interpolation = img.Interpolation.nearest,
    ResizeFilter? filter}) {
  if (width == null && height == null) {
    throw img.ImageException('Invalid size');
  }
  final ifd = src.exif.imageIfd;
  final o = ifd.hasOrientation ? ifd.orientation! : 1;
  final letterbox = width != null && height != null && maintainAspect == true;
  if (!nativeCompatible(src) || letterbox || o < 1 || o > 8) {
    return img.copyResize(src,
        width: width,
        height: height,
        maintainAspect: maintainAspect,
        backgroundColor: backgroundColor,
        interpolation: filter?.fallback ?? interpolation);
  }
  final swap = o >= 5;
  final srcW = swap ? src.height : src.width;
  final srcH = swap ? src.width : src.height;
  if (height == null || height <= 0) {
    height = (width! * (srcH / srcW)).round();
  }
  if (width == null || width <= 0) {
    width = (height * (srcW / srcH)).round();
  }
  if ((width == srcW && height == srcH) || width <= 0 || height <= 0) {
    return img.copyResize(src,
        width: width, height: height, interpolation: interpolation);
  }
  final n = toNative(src);
  try {
    final r = nativeOps!.resize(
        n, width, height, filter?.code ?? _interpCode(interpolation),
        orientation: o);
    final out = fromNative(r, like: src);
    r.dispose();
    if (o != 1) out.exif.imageIfd.orientation = null;
    return out;
  } finally {
    n.dispose();
  }
}

/// Returns a copy of [src] rotated by [angle] degrees, like package:image's
/// `copyRotate` (same size, same pixels), natively and in parallel.
img.Image copyRotate(img.Image src,
    {required num angle,
    img.Interpolation interpolation = img.Interpolation.nearest}) {
  final a = angle % 360.0;
  final rightAngle = a % 90.0 == 0.0;
  if (!nativeCompatible(src) ||
      a == 0 ||
      (!rightAngle && src.backgroundColor != null)) {
    return img.copyRotate(src, angle: angle, interpolation: interpolation);
  }
  final code = interpolation == img.Interpolation.cubic
      ? 2
      : interpolation == img.Interpolation.nearest
          ? 0
          : 1;
  final n = toNative(src);
  try {
    final r = nativeOps!.rotate(n, angle.toDouble(), code);
    final out = fromNative(r, like: src);
    r.dispose();
    return out;
  } finally {
    n.dispose();
  }
}

/// Blurs [src] in place, like package:image's `gaussianBlur` (same pixels),
/// natively and in parallel.
img.Image gaussianBlur(img.Image src,
    {required int radius,
    img.Image? mask,
    img.Channel maskChannel = img.Channel.luminance}) {
  if (radius <= 0) return src;
  if (mask != null ||
      !nativeCompatible(src) ||
      src.width < 2 ||
      src.height < 2) {
    return img.gaussianBlur(src,
        radius: radius, mask: mask, maskChannel: maskChannel);
  }
  final n = toNative(src);
  try {
    nativeOps!.blur(n, radius);
    n.readInto(src.toUint8List());
  } finally {
    n.dispose();
  }
  return src;
}

/// Adjusts the colours of [src] in place, like package:image's
/// `adjustColor` (same pixels), natively and in parallel. [blacks],
/// [whites], [mids] and [mask] use package:image.
img.Image adjustColor(img.Image src,
    {img.Color? blacks,
    img.Color? whites,
    img.Color? mids,
    num? contrast,
    num? saturation,
    num? brightness,
    num? gamma,
    num? exposure,
    num? hue,
    num amount = 1,
    img.Image? mask,
    img.Channel maskChannel = img.Channel.luminance}) {
  if (amount == 0) return src;
  if (blacks != null ||
      whites != null ||
      mids != null ||
      mask != null ||
      !nativeCompatible(src) ||
      src.numChannels < 3) {
    return img.adjustColor(src,
        blacks: blacks,
        whites: whites,
        mids: mids,
        contrast: contrast,
        saturation: saturation,
        brightness: brightness,
        gamma: gamma,
        exposure: exposure,
        hue: hue,
        amount: amount,
        mask: mask,
        maskChannel: maskChannel);
  }
  final n = toNative(src);
  try {
    nativeOps!.adjust(n,
        contrast: contrast?.toDouble(),
        saturation: saturation?.toDouble(),
        brightness: brightness?.toDouble(),
        gamma: gamma?.toDouble(),
        exposure: exposure?.toDouble(),
        hue: hue?.toDouble(),
        amount: amount.toDouble());
    n.readInto(src.toUint8List());
  } finally {
    n.dispose();
  }
  return src;
}
