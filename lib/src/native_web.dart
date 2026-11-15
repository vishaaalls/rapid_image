// Web: the image operations compiled to WebAssembly (native/src/ops.rs,
// built by tool/build_wasm.sh and embedded in wasm_bytes.g.dart). The PNG
// encoder stays native-only; on the web PNG data is compressed by
// rapid_archive's WebAssembly instead.
//
// Call `ensureRapidImageInitialized()` once at startup to compile the
// modules asynchronously. Without it, the first operation compiles this
// module synchronously, which browsers allow for a module this size.

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:rapid_archive/rapid_archive.dart'
    show ensureRapidArchiveInitialized;

import 'native_ops.dart';
import 'wasm_bytes.g.dart';

const nativePngAvailable = false;

Uint8List encodeIdat(Uint8List src,
        {required int height,
        required int stride,
        required int bpp,
        required int bpc,
        required int filter,
        required int level,
        required bool parallel,
        int chunkSize = 1 << 20}) =>
    throw UnsupportedError('rapid_image: no native PNG encoder on the web');

@JS('WebAssembly.instantiate')
external JSPromise<JSObject> _instantiate(JSUint8Array bytes);

@JS('WebAssembly.Module')
extension type _Module._(JSObject _) implements JSObject {
  external factory _Module(JSUint8Array bytes);
}

@JS('WebAssembly.Instance')
extension type _Instance._(JSObject _) implements JSObject {
  external factory _Instance(_Module module);
  external JSObject get exports;
}

JSObject? _exports;
Future<void>? _loading;

JSUint8Array get _wasmBytes => base64Decode(rapidImageWasmBase64).toJS;

/// Compiles rapid_image's and rapid_archive's WebAssembly modules. Call it
/// once at startup on the web; safe to call more than once, and on other
/// platforms it returns at once.
Future<void> ensureRapidImageInitialized() async {
  await ensureRapidArchiveInitialized();
  if (_exports != null) return;
  await (_loading ??= () async {
    final result = await _instantiate(_wasmBytes).toDart;
    _exports ??= (result['instance'] as _Instance).exports;
  }());
}

JSObject get _x =>
    _exports ??= _Instance(_Module(_wasmBytes)).exports; // sync fallback

int _call(String name, List<JSAny?> args) {
  final f = _x[name] as JSFunction;
  final r = (f as JSObject).callMethodVarArgs('call'.toJS, [null, ...args]);
  // wasm i32 results arrive signed; pointers and sizes are unsigned.
  return r == null ? 0 : (r as JSNumber).toDartInt & 0xFFFFFFFF;
}

/// The current view of wasm memory; re-read after any call, since memory
/// can grow (which replaces the buffer).
JSUint8Array get _mem =>
    JSUint8Array((_x['memory'] as JSObject)['buffer'] as JSArrayBuffer);

int _u32(int ptr) =>
    _DataView((_x['memory'] as JSObject)['buffer'] as JSArrayBuffer)
        .getUint32(ptr, true);

@JS('DataView')
extension type _DataView._(JSObject _) implements JSObject {
  external factory _DataView(JSArrayBuffer buffer);
  external int getUint32(int byteOffset, bool littleEndian);
}

/// Copies [data] into newly allocated wasm memory, in one JS-side copy.
/// Release with `ri_free(p, len)`.
int _put(Uint8List data) {
  final p = _call('ri_alloc', [data.length.toJS]);
  _mem.callMethod<JSAny?>('set'.toJS, data.toJS, p.toJS);
  return p;
}

void _free(int p, int len) => _call('ri_free', [p.toJS, len.toJS]);

/// A copy of [len] bytes at [ptr] in wasm memory, made in JS.
Uint8List _copyOut(int ptr, int len) => _mem
    .callMethod<JSUint8Array>('slice'.toJS, ptr.toJS, (ptr + len).toJS)
    .toDart;

/// Runs [f] with a 4-byte out-slot for a handle; on status 0 returns the
/// adopted image, on 1 (unsupported) null, otherwise throws.
_WebImage? _withOut(int Function(int out) f) {
  final out = _call('ri_alloc', [4.toJS]);
  try {
    final rc = f(out);
    if (rc == 0) return _WebImage.adopt(_u32(out));
    if (rc == 1) return null;
    throw ArgumentError('rapid_image: invalid arguments (status $rc)');
  } finally {
    _free(out, 4);
  }
}

final _finalizer = Finalizer<int>((h) => _call('ri_img_free', [h.toJS]));

class _WebImage implements NativeImage {
  int _h;
  @override
  final int width, height, channels;

  _WebImage._(this._h, this.width, this.height, this.channels) {
    _finalizer.attach(this, _h, detach: this);
  }

  factory _WebImage.adopt(int h) {
    final p = _call('ri_alloc', [12.toJS]);
    try {
      _call('ri_img_info', [h.toJS, p.toJS, (p + 4).toJS, (p + 8).toJS]);
      return _WebImage._(h, _u32(p), _u32(p + 4), _u32(p + 8));
    } finally {
      _free(p, 12);
    }
  }

  int get handle {
    if (_h == 0) throw StateError('rapid_image: image already disposed');
    return _h;
  }

  @override
  void readInto(Uint8List dst) {
    final n = width * height * channels;
    if (dst.length != n) {
      throw ArgumentError('rapid_image: destination holds ${dst.length} bytes, '
          'expected $n');
    }
    if (n == 0) return;
    final p = _call('ri_img_data', [handle.toJS]);
    dst.setAll(0, _copyOut(p, n));
  }

  @override
  void dispose() {
    if (_h == 0) return;
    _finalizer.detach(this);
    _call('ri_img_free', [_h.toJS]);
    _h = 0;
  }
}

int _hd(NativeImage i) => (i as _WebImage).handle;

/// The WebAssembly operations.
final NativeOps? nativeOps = _WebOps();

class _WebOps implements NativeOps {
  @override
  NativeImage fromPixels(
      Uint8List pixels, int width, int height, int channels) {
    final p = _put(pixels);
    try {
      return _withOut((out) => _call('ri_img_new',
          [p.toJS, width.toJS, height.toJS, channels.toJS, out.toJS]))!;
    } finally {
      _free(p, pixels.length);
    }
  }

  NativeImage? _decode(String fn, Uint8List bytes, [int? orientation]) {
    final p = _put(bytes);
    try {
      return _withOut((out) => _call(fn, [
            p.toJS,
            bytes.length.toJS,
            if (orientation != null) orientation.toJS,
            out.toJS
          ]));
    } finally {
      _free(p, bytes.length);
    }
  }

  @override
  NativeImage? decodeJpeg(Uint8List bytes, int orientation) =>
      _decode('ri_jpeg_decode', bytes, orientation);

  @override
  NativeImage? decodePng(Uint8List bytes) => _decode('ri_png_decode', bytes);

  @override
  Uint8List? encodeJpeg(NativeImage image,
      {required int quality,
      required bool chroma420,
      required List<int> background,
      Uint8List? app1,
      Uint8List? app2}) {
    final a1 = app1 == null || app1.isEmpty ? 0 : _put(app1);
    final a2 = app2 == null || app2.isEmpty ? 0 : _put(app2);
    final out = _call('ri_alloc', [8.toJS]);
    try {
      final rc = _call('ri_jpeg_encode', [
        _hd(image).toJS,
        quality.toJS,
        (chroma420 ? 1 : 0).toJS,
        background[0].toJS,
        background[1].toJS,
        background[2].toJS,
        a1.toJS,
        (a1 == 0 ? 0 : app1!.length).toJS,
        a2.toJS,
        (a2 == 0 ? 0 : app2!.length).toJS,
        out.toJS,
        (out + 4).toJS,
      ]);
      if (rc != 0) return null;
      final p = _u32(out), n = _u32(out + 4);
      final r = _copyOut(p, n);
      _free(p, n);
      return r;
    } finally {
      _free(out, 8);
      if (a1 != 0) _free(a1, app1!.length);
      if (a2 != 0) _free(a2, app2!.length);
    }
  }

  @override
  NativeImage resize(NativeImage image, int width, int height, int mode,
          {int orientation = 1}) =>
      _withOut((out) => _call('ri_resize', [
            _hd(image).toJS,
            width.toJS,
            height.toJS,
            mode.toJS,
            orientation.toJS,
            out.toJS
          ]))!;

  @override
  NativeImage orient(NativeImage image, int orientation) => _withOut((out) =>
      _call('ri_orient', [_hd(image).toJS, orientation.toJS, out.toJS]))!;

  @override
  NativeImage rotate(NativeImage image, double angle, int interpolation) =>
      _withOut((out) => _call('ri_rotate',
          [_hd(image).toJS, angle.toJS, interpolation.toJS, out.toJS]))!;

  @override
  NativeImage crop(NativeImage image, int x, int y, int width, int height) =>
      _withOut((out) => _call('ri_crop', [
            _hd(image).toJS,
            x.toJS,
            y.toJS,
            width.toJS,
            height.toJS,
            out.toJS
          ]))!;

  @override
  void flip(NativeImage image, int direction) {
    if (_call('ri_flip', [_hd(image).toJS, direction.toJS]) != 0) {
      throw ArgumentError.value(direction, 'direction');
    }
  }

  @override
  void blur(NativeImage image, int radius) =>
      _call('ri_blur', [_hd(image).toJS, radius.toJS]);

  @override
  bool adjust(NativeImage image,
          {double? contrast,
          double? saturation,
          double? brightness,
          double? gamma,
          double? exposure,
          double? hue,
          double amount = 1}) =>
      _call('ri_adjust', [
        _hd(image).toJS,
        (contrast ?? double.nan).toJS,
        (saturation ?? double.nan).toJS,
        (brightness ?? double.nan).toJS,
        (gamma ?? double.nan).toJS,
        (exposure ?? double.nan).toJS,
        (hue ?? double.nan).toJS,
        amount.toJS,
      ]) ==
      0;
}
