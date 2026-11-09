import 'dart:typed_data';

import 'package:rapid_archive/rapid_archive.dart' as ra;

/// Rewrites the compressed image data of the PNG (or APNG) [png] with
/// rapid_archive's compressor, leaving every other chunk as it is.
///
/// The IDAT chunks, and the fdAT chunks of each animation frame, are joined,
/// decompressed and compressed again at [level] (0 to 9). Because the number
/// of fdAT chunks can change, the sequence numbers of fcTL and fdAT chunks are
/// renumbered. The pixels are untouched: decoding the result gives the same
/// image as decoding [png].
Uint8List recompressPng(Uint8List png, {int level = 6, bool parallel = true}) {
  if (png.length < 8 || !_hasSignature(png)) {
    throw const FormatException('Not a PNG file');
  }
  final encoder = ra.ZLibEncoder(parallel: parallel);
  const decoder = ra.ZLibDecoder();
  final out = BytesBuilder(copy: false)..add(Uint8List.sublistView(png, 0, 8));
  final view = ByteData.sublistView(png);
  var seq = 0;
  var p = 8;

  // Compressed data of the current IDAT or fdAT run.
  final pending = <Uint8List>[];
  String? pendingType;

  void flush() {
    if (pendingType == null) return;
    final joined = _join(pending);
    final raw = decoder.decodeBytes(joined);
    final packed = encoder.encodeBytes(raw, level: level);
    final isIdat = pendingType == 'IDAT';
    for (var i = 0; i < packed.length || i == 0; i += _maxChunk) {
      final end = i + _maxChunk < packed.length ? i + _maxChunk : packed.length;
      final part = Uint8List.sublistView(packed, i, end);
      if (isIdat) {
        _writeChunk(out, _idat, part);
      } else {
        final body = Uint8List(4 + part.length);
        ByteData.sublistView(body).setUint32(0, seq++);
        body.setRange(4, body.length, part);
        _writeChunk(out, _fdat, body);
      }
      if (packed.isEmpty) break;
    }
    pending.clear();
    pendingType = null;
  }

  while (p + 12 <= png.length) {
    final len = view.getUint32(p);
    final typeBytes = Uint8List.sublistView(png, p + 4, p + 8);
    final type = String.fromCharCodes(typeBytes);
    final dataStart = p + 8;
    final dataEnd = dataStart + len;
    if (dataEnd + 4 > png.length) {
      throw const FormatException('Truncated PNG chunk');
    }
    final data = Uint8List.sublistView(png, dataStart, dataEnd);
    if (type == 'IDAT' || type == 'fdAT') {
      if (pendingType != null && pendingType != type) flush();
      pendingType = type;
      pending.add(type == 'fdAT' ? Uint8List.sublistView(data, 4) : data);
    } else {
      flush();
      if (type == 'fcTL' && len >= 4) {
        final body = Uint8List.fromList(data);
        ByteData.sublistView(body).setUint32(0, seq++);
        _writeChunk(out, typeBytes, body);
      } else {
        // Unchanged chunk, CRC included.
        out.add(Uint8List.sublistView(png, p, dataEnd + 4));
      }
    }
    p = dataEnd + 4;
    if (type == 'IEND') break;
  }
  flush();
  return out.takeBytes();
}

const _maxChunk = 1 << 20;
final _idat = Uint8List.fromList('IDAT'.codeUnits);
final _fdat = Uint8List.fromList('fdAT'.codeUnits);

bool _hasSignature(Uint8List b) =>
    b[0] == 0x89 &&
    b[1] == 0x50 &&
    b[2] == 0x4e &&
    b[3] == 0x47 &&
    b[4] == 0x0d &&
    b[5] == 0x0a &&
    b[6] == 0x1a &&
    b[7] == 0x0a;

Uint8List _join(List<Uint8List> parts) {
  if (parts.length == 1) return parts.first;
  var n = 0;
  for (final x in parts) {
    n += x.length;
  }
  final r = Uint8List(n);
  var o = 0;
  for (final x in parts) {
    r.setRange(o, o + x.length, x);
    o += x.length;
  }
  return r;
}

void _writeChunk(BytesBuilder out, Uint8List type, Uint8List data) {
  final head = Uint8List(8);
  ByteData.sublistView(head).setUint32(0, data.length);
  head.setRange(4, 8, type);
  out
    ..add(head)
    ..add(data);
  var c = _crcUpdate(0xffffffff, type);
  c = _crcUpdate(c, data) ^ 0xffffffff;
  final tail = Uint8List(4);
  ByteData.sublistView(tail).setUint32(0, c);
  out.add(tail);
}

// Slicing-by-8 CRC-32 so the checksum doesn't dominate on large images.
final List<Uint32List> _tables = _makeTables();

List<Uint32List> _makeTables() {
  final t = List.generate(8, (_) => Uint32List(256));
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
    }
    t[0][n] = c;
  }
  for (var n = 0; n < 256; n++) {
    var c = t[0][n];
    for (var k = 1; k < 8; k++) {
      c = t[0][c & 0xff] ^ (c >> 8);
      t[k][n] = c;
    }
  }
  return t;
}

int _crcUpdate(int crc, Uint8List b) {
  final t0 = _tables[0], t1 = _tables[1], t2 = _tables[2], t3 = _tables[3];
  final t4 = _tables[4], t5 = _tables[5], t6 = _tables[6], t7 = _tables[7];
  var c = crc;
  var i = 0;
  final n = b.length;
  final end8 = n - (n & 7);
  while (i < end8) {
    final lo = c ^ (b[i] | b[i + 1] << 8 | b[i + 2] << 16 | b[i + 3] << 24);
    c = t7[lo & 0xff] ^
        t6[(lo >> 8) & 0xff] ^
        t5[(lo >> 16) & 0xff] ^
        t4[(lo >> 24) & 0xff] ^
        t3[b[i + 4]] ^
        t2[b[i + 5]] ^
        t1[b[i + 6]] ^
        t0[b[i + 7]];
    i += 8;
  }
  while (i < n) {
    c = t0[(c ^ b[i++]) & 0xff] ^ (c >> 8);
  }
  return c;
}
