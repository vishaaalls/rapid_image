// Web: no native code; the encoder falls back to recompressing image's output.
import 'dart:typed_data';

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
    throw UnsupportedError('rapid_image: no native encoder on this platform');
