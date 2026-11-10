// Web: no native code. The PNG encoder falls back to recompressing image's
// output, and the other operations use package:image.
import 'dart:typed_data';

import 'native_ops.dart';

const nativePngAvailable = false;

/// No native operations on this platform.
const NativeOps? nativeOps = null;

Uint8List encodeIdat(Uint8List src,
        {required int height,
        required int stride,
        required int bpp,
        required int bpc,
        required int filter,
        required int level,
        required bool parallel,
        int chunkSize = 1 << 20}) =>
    throw UnsupportedError('rapid_image: no native encoder on this platform');

/// Prepares rapid_image. Needed only on the web (it compiles the
/// WebAssembly modules); on native platforms it returns at once.
Future<void> ensureRapidImageInitialized() async {}
