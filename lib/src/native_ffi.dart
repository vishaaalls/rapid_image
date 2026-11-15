// FFI binding to the Rust library (native/src), bundled by hook/build.dart.

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'native_ops.dart';

@Native<
    Int32 Function(
        Pointer<Uint8>,
        Size,
        Uint32,
        Uint32,
        Uint32,
        Uint32,
        Int32,
        Int32,
        Int32,
        Uint32,
        Pointer<Pointer<Uint8>>,
        Pointer<Size>)>(isLeaf: true)
external int ri_png_encode(
    Pointer<Uint8> src,
    int srcLen,
    int height,
    int stride,
    int bpp,
    int bpc,
    int filter,
    int level,
    int parallel,
    int chunkSize,
    Pointer<Pointer<Uint8>> out,
    Pointer<Size> outLen);

@Native<Void Function(Pointer<Uint8>, Size)>(isLeaf: true)
external void ri_free(Pointer<Uint8> p, int len);

const nativePngAvailable = true;

/// Filters and compresses [src] (height rows of [stride] bytes) into
/// complete IDAT chunks.
Uint8List encodeIdat(Uint8List src,
    {required int height,
    required int stride,
    required int bpp,
    required int bpc,
    required int filter,
    required int level,
    required bool parallel,
    int chunkSize = 1 << 20}) {
  final out = calloc<Pointer<Uint8>>();
  final outLen = calloc<Size>();
  try {
    final rc = ri_png_encode(src.address, src.length, height, stride, bpp, bpc,
        filter, level, parallel ? 1 : 0, chunkSize, out, outLen);
    if (rc != 0) {
      throw ArgumentError('rapid_image: invalid image layout');
    }
    final p = out.value;
    final n = outLen.value;
    final r = Uint8List.fromList(p.asTypedList(n));
    ri_free(p, n);
    return r;
  } finally {
    calloc
      ..free(out)
      ..free(outLen);
  }
}

// ---------------------------------------------------------------------------
// Image operations (native/src/ops_ffi.rs)
// ---------------------------------------------------------------------------

typedef _H = Pointer<Void>;

@Native<Int32 Function(Pointer<Uint8>, Uint32, Uint32, Uint32, Pointer<_H>)>(
    isLeaf: true)
external int ri_img_new(
    Pointer<Uint8> src, int w, int h, int nc, Pointer<_H> out);

@Native<Void Function(_H)>(isLeaf: true)
external void ri_img_free(_H img);

@Native<Void Function(_H, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>)>(
    isLeaf: true)
external void ri_img_info(
    _H img, Pointer<Uint32> w, Pointer<Uint32> h, Pointer<Uint32> nc);

@Native<Pointer<Uint8> Function(_H)>(isLeaf: true)
external Pointer<Uint8> ri_img_data(_H img);

@Native<Int32 Function(Pointer<Uint8>, Size, Int32, Pointer<_H>)>(isLeaf: true)
external int ri_jpeg_decode(
    Pointer<Uint8> src, int len, int orientation, Pointer<_H> out);

@Native<Int32 Function(Pointer<Uint8>, Size, Pointer<_H>)>(isLeaf: true)
external int ri_png_decode(Pointer<Uint8> src, int len, Pointer<_H> out);

@Native<
    Int32 Function(
        _H,
        Int32,
        Int32,
        Uint32,
        Uint32,
        Uint32,
        Pointer<Uint8>,
        Size,
        Pointer<Uint8>,
        Size,
        Pointer<Pointer<Uint8>>,
        Pointer<Size>)>(isLeaf: true)
external int ri_jpeg_encode(
    _H img,
    int quality,
    int chroma420,
    int bgR,
    int bgG,
    int bgB,
    Pointer<Uint8> app1,
    int app1Len,
    Pointer<Uint8> app2,
    int app2Len,
    Pointer<Pointer<Uint8>> out,
    Pointer<Size> outLen);

@Native<Int32 Function(_H, Uint32, Uint32, Int32, Int32, Pointer<_H>)>(
    isLeaf: true)
external int ri_resize(
    _H img, int w, int h, int mode, int orientation, Pointer<_H> out);

@Native<Int32 Function(_H, Int32, Pointer<_H>)>(isLeaf: true)
external int ri_orient(_H img, int orientation, Pointer<_H> out);

@Native<Int32 Function(_H, Double, Int32, Pointer<_H>)>(isLeaf: true)
external int ri_rotate(_H img, double angle, int interp, Pointer<_H> out);

@Native<Int32 Function(_H, Uint32, Uint32, Uint32, Uint32, Pointer<_H>)>(
    isLeaf: true)
external int ri_crop(_H img, int x, int y, int w, int h, Pointer<_H> out);

@Native<Int32 Function(_H, Int32)>(isLeaf: true)
external int ri_flip(_H img, int dir);

@Native<Int32 Function(_H, Int32)>(isLeaf: true)
external int ri_blur(_H img, int radius);

@Native<
    Int32 Function(_H, Double, Double, Double, Double, Double, Double,
        Double)>(isLeaf: true)
external int ri_adjust(
    _H img,
    double contrast,
    double saturation,
    double brightness,
    double gamma,
    double exposure,
    double hue,
    double amount);

/// The native operations on this platform.
final NativeOps? nativeOps = _FfiOps();

final _finalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(_H)>>(ri_img_free).cast());

class _FfiImage implements NativeImage, Finalizable {
  _H _h;
  @override
  final int width, height, channels;

  _FfiImage._(this._h, this.width, this.height, this.channels) {
    _finalizer.attach(this, _h, detach: this);
  }

  factory _FfiImage.adopt(_H h) {
    final p = calloc<Uint32>(3);
    try {
      ri_img_info(h, p, p + 1, p + 2);
      return _FfiImage._(h, p[0], p[1], p[2]);
    } finally {
      calloc.free(p);
    }
  }

  _H get handle {
    if (_h == nullptr) throw StateError('rapid_image: image already disposed');
    return _h;
  }

  @override
  void readInto(Uint8List dst) {
    final n = width * height * channels;
    if (dst.length != n) {
      throw ArgumentError('rapid_image: destination holds ${dst.length} bytes, '
          'expected $n');
    }
    if (n > 0) dst.setAll(0, ri_img_data(handle).asTypedList(n));
  }

  @override
  void dispose() {
    if (_h == nullptr) return;
    _finalizer.detach(this);
    ri_img_free(_h);
    _h = nullptr;
  }
}

/// Runs [f] with an out-pointer for a handle; adopts the result on status 0,
/// returns null on 1 (unsupported) and throws on anything else.
_FfiImage? _call(int Function(Pointer<_H> out) f) {
  final out = calloc<_H>();
  try {
    final rc = f(out);
    if (rc == 0) return _FfiImage.adopt(out.value);
    if (rc == 1) return null;
    throw ArgumentError('rapid_image: invalid arguments (status $rc)');
  } finally {
    calloc.free(out);
  }
}

_H _h(NativeImage i) => (i as _FfiImage).handle;

class _FfiOps implements NativeOps {
  @override
  NativeImage fromPixels(
          Uint8List pixels, int width, int height, int channels) =>
      _call((out) => ri_img_new(pixels.address, width, height, channels, out))!;

  @override
  NativeImage? decodeJpeg(Uint8List bytes, int orientation) => _call(
      (out) => ri_jpeg_decode(bytes.address, bytes.length, orientation, out));

  @override
  NativeImage? decodePng(Uint8List bytes) =>
      _call((out) => ri_png_decode(bytes.address, bytes.length, out));

  @override
  Uint8List? encodeJpeg(NativeImage image,
      {required int quality,
      required bool chroma420,
      required List<int> background,
      Uint8List? app1,
      Uint8List? app2}) {
    final out = calloc<Pointer<Uint8>>();
    final outLen = calloc<Size>();
    final a1 = app1 ?? Uint8List(0);
    final a2 = app2 ?? Uint8List(0);
    try {
      final rc = ri_jpeg_encode(
          _h(image),
          quality,
          chroma420 ? 1 : 0,
          background[0],
          background[1],
          background[2],
          a1.address,
          a1.length,
          a2.address,
          a2.length,
          out,
          outLen);
      if (rc != 0) return null;
      final p = out.value;
      final n = outLen.value;
      final r = Uint8List.fromList(p.asTypedList(n));
      ri_free(p, n);
      return r;
    } finally {
      calloc
        ..free(out)
        ..free(outLen);
    }
  }

  @override
  NativeImage resize(NativeImage image, int width, int height, int mode,
          {int orientation = 1}) =>
      _call((out) =>
          ri_resize(_h(image), width, height, mode, orientation, out))!;

  @override
  NativeImage orient(NativeImage image, int orientation) =>
      _call((out) => ri_orient(_h(image), orientation, out))!;

  @override
  NativeImage rotate(NativeImage image, double angle, int interpolation) =>
      _call((out) => ri_rotate(_h(image), angle, interpolation, out))!;

  @override
  NativeImage crop(NativeImage image, int x, int y, int width, int height) =>
      _call((out) => ri_crop(_h(image), x, y, width, height, out))!;

  @override
  void flip(NativeImage image, int direction) {
    if (ri_flip(_h(image), direction) != 0) {
      throw ArgumentError.value(direction, 'direction');
    }
  }

  @override
  void blur(NativeImage image, int radius) => ri_blur(_h(image), radius);

  @override
  bool adjust(NativeImage image,
          {double? contrast,
          double? saturation,
          double? brightness,
          double? gamma,
          double? exposure,
          double? hue,
          double amount = 1}) =>
      ri_adjust(
          _h(image),
          contrast ?? double.nan,
          saturation ?? double.nan,
          brightness ?? double.nan,
          gamma ?? double.nan,
          exposure ?? double.nan,
          hue ?? double.nan,
          amount) ==
      0;
}

/// Prepares rapid_image. Needed only on the web (it compiles the
/// WebAssembly modules); on native platforms it returns at once.
Future<void> ensureRapidImageInitialized() async {}
