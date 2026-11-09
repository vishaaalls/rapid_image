// FFI binding to the Rust PNG encoder (native/src/lib.rs), bundled by
// hook/build.dart.

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

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
