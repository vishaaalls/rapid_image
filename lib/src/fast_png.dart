import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'native_stub.dart' if (dart.library.ffi) 'native_ffi.dart';

/// Encodes a single-frame, non-palette 8 or 16-bit [image] with the native
/// encoder, or returns null when that path doesn't apply (web, palettes,
/// other formats) so the caller can fall back.
///
/// The chunks around the image data (IHDR, iCCP, cICP, tEXt, pHYs, IEND) are
/// written by image's own PngEncoder for a 1x1 stand-in with the same
/// format and metadata, so they match image's output byte for byte; only the
/// size in IHDR and the IDAT chunks are replaced.
Uint8List? encodePngNative(img.Image image,
    {required img.PngFilter filter,
    required int level,
    required bool parallel,
    img.PngPhysicalPixelDimensions? pixelDimensions,
    img.PngCicpData? cicpData}) {
  if (!nativePngAvailable || image.hasPalette || image.data == null) {
    return null;
  }
  final format = image.format;
  if (format != img.Format.uint8 && format != img.Format.uint16) return null;
  final nc = image.numChannels;
  if (nc < 1 || nc > 4 || image.width < 1 || image.height < 1) return null;

  final bpc = format == img.Format.uint16 ? 2 : 1;
  final stub = img.Image(
      width: 1,
      height: 1,
      format: format,
      numChannels: nc,
      iccp: image.iccProfile,
      textData: image.textData);
  final head = img.PngEncoder(
          filter: filter,
          level: 0,
          pixelDimensions: pixelDimensions,
          cicpData: cicpData)
      .encode(stub, singleFrame: true);

  final idat = encodeIdat(image.data!.toUint8List(),
      height: image.height,
      stride: image.rowStride,
      bpp: nc * bpc,
      bpc: bpc,
      filter: filter.index,
      level: level.clamp(0, 9),
      parallel: parallel);

  final out = BytesBuilder(copy: false)..add(Uint8List.sublistView(head, 0, 8));
  final v = ByteData.sublistView(head);
  var p = 8;
  var wroteIdat = false;
  while (p + 12 <= head.length) {
    final len = v.getUint32(p);
    final type = String.fromCharCodes(head, p + 4, p + 8);
    final end = p + 12 + len;
    if (type == 'IDAT') {
      if (!wroteIdat) out.add(idat);
      wroteIdat = true;
    } else if (type == 'IHDR') {
      final chunk = Uint8List.fromList(head.sublist(p, end));
      final cv = ByteData.sublistView(chunk)
        ..setUint32(8, image.width)
        ..setUint32(12, image.height);
      cv.setUint32(8 + len, crc32(Uint8List.sublistView(chunk, 4, 8 + len)));
      out.add(chunk);
    } else {
      out.add(Uint8List.sublistView(head, p, end));
    }
    p = end;
  }
  return out.takeBytes();
}

final Uint32List _table = () {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
    }
    t[n] = c;
  }
  return t;
}();

/// CRC-32 of a short buffer (IHDR).
int crc32(Uint8List b) {
  var c = 0xffffffff;
  for (final x in b) {
    c = _table[(c ^ x) & 0xff] ^ (c >> 8);
  }
  return c ^ 0xffffffff;
}
