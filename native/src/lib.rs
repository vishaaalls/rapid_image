//! PNG image data encoder: filters the rows of an image and compresses them
//! into the zlib stream that goes in a PNG's IDAT chunks.
//!
//! The parallel path splits the rows into bands of about 1 MiB. PNG filters
//! only look at the current and previous *unfiltered* rows, which are both in
//! the source image, so every band can be filtered and compressed on its own
//! core. Bands are joined pigz-style (sync flush), giving one ordinary zlib
//! stream. The single-core path filters everything and compresses it with
//! libdeflate, which is faster and smaller than zlib.

pub mod ops;
mod ops_ffi;

use std::cell::RefCell;
use std::ptr::NonNull;

use flate2::{Compress, Compression, FlushCompress};
use libdeflate_sys::*;
use rayon::prelude::*;

/// PNG filter types, in image's `PngFilter` order.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Filter {
    None = 0,
    Sub = 1,
    Up = 2,
    Average = 3,
    Paeth = 4,
}

impl Filter {
    fn from_i32(v: i32) -> Option<Filter> {
        Some(match v {
            0 => Filter::None,
            1 => Filter::Sub,
            2 => Filter::Up,
            3 => Filter::Average,
            4 => Filter::Paeth,
            _ => return None,
        })
    }
}

/// How the source rows are laid out.
#[derive(Clone, Copy, Debug)]
pub struct Layout {
    pub height: usize,
    /// Bytes per row in the source (and in the filtered row, minus the type byte).
    pub stride: usize,
    /// Bytes per pixel, the distance the Sub/Average/Paeth filters look back.
    pub bpp: usize,
    /// Bytes per sample. Samples wider than one byte are stored little-endian
    /// and written big-endian, as PNG requires.
    pub bpc: usize,
}

/// Target size of the filtered data in one parallel band.
const BAND: usize = 1 << 20;

/// Filters and compresses the image into a zlib stream at `level` (0..=9).
pub fn encode(src: &[u8], l: Layout, filter: Filter, level: u32, parallel: bool) -> Vec<u8> {
    let level = level.min(9);
    let row_out = l.stride + 1;
    let total = row_out * l.height;
    let rows_per_band = (BAND / row_out).max(1);
    let bands = l.height.div_ceil(rows_per_band);
    if !parallel || bands < 2 || rayon::current_num_threads() < 2 || level == 0 {
        let mut filtered = vec![0u8; total];
        filter_rows(src, l, filter, 0, l.height, &mut filtered);
        return compress_zlib(&filtered, level);
    }
    // zlib-rs level 1 uses a "quick" strategy that is ~35% larger on photos;
    // level 2 is close to libdeflate's level 1 in size.
    let lvl = Compression::new(level.max(2));
    let parts: Vec<(Vec<u8>, u32, usize)> = (0..bands)
        .into_par_iter()
        .map(|b| {
            let y0 = b * rows_per_band;
            let y1 = (y0 + rows_per_band).min(l.height);
            let mut filtered = vec![0u8; (y1 - y0) * row_out];
            filter_rows(src, l, filter, y0, y1, &mut filtered);
            let adler = adler32(1, &filtered);
            (
                deflate_band(&filtered, lvl, b == bands - 1),
                adler,
                filtered.len(),
            )
        })
        .collect();
    let mut out = Vec::with_capacity(parts.iter().map(|p| p.0.len()).sum::<usize>() + 6);
    out.extend_from_slice(&zlib_header(level));
    let mut adler = 1u32;
    for (data, a, len) in &parts {
        out.extend_from_slice(data);
        adler = adler32_combine(adler, *a, *len);
    }
    out.extend_from_slice(&adler.to_be_bytes());
    out
}

/// Filters rows `y0..y1` into `out` (each row: filter type byte + data).
pub fn filter_rows(src: &[u8], l: Layout, filter: Filter, y0: usize, y1: usize, out: &mut [u8]) {
    let n = l.stride;
    let mut cur = vec![0u8; n];
    let mut prev = vec![0u8; n];
    if y0 > 0 {
        load_row(src, l, y0 - 1, &mut prev);
    }
    for (i, y) in (y0..y1).enumerate() {
        load_row(src, l, y, &mut cur);
        let o = &mut out[i * (n + 1)..(i + 1) * (n + 1)];
        o[0] = filter as u8;
        let o = &mut o[1..];
        let bpp = l.bpp.min(n);
        match filter {
            Filter::None => o.copy_from_slice(&cur),
            Filter::Sub => {
                o[..bpp].copy_from_slice(&cur[..bpp]);
                for x in bpp..n {
                    o[x] = cur[x].wrapping_sub(cur[x - bpp]);
                }
            }
            Filter::Up => {
                for x in 0..n {
                    o[x] = cur[x].wrapping_sub(prev[x]);
                }
            }
            Filter::Average => {
                for x in 0..bpp {
                    o[x] = cur[x].wrapping_sub(prev[x] >> 1);
                }
                for x in bpp..n {
                    let avg = ((cur[x - bpp] as u16 + prev[x] as u16) >> 1) as u8;
                    o[x] = cur[x].wrapping_sub(avg);
                }
            }
            Filter::Paeth => {
                for x in 0..bpp {
                    o[x] = cur[x].wrapping_sub(prev[x]);
                }
                for x in bpp..n {
                    let a = cur[x - bpp] as i16;
                    let b = prev[x] as i16;
                    let c = prev[x - bpp] as i16;
                    let pa = (b - c).abs();
                    let pb = (a - c).abs();
                    let pc = (a + b - 2 * c).abs();
                    let p = if pa <= pb && pa <= pc {
                        a
                    } else if pb <= pc {
                        b
                    } else {
                        c
                    };
                    o[x] = cur[x].wrapping_sub(p as u8);
                }
            }
        }
        std::mem::swap(&mut cur, &mut prev);
    }
}

/// Copies row `y` of the source into `row`, swapping wide samples to big-endian.
fn load_row(src: &[u8], l: Layout, y: usize, row: &mut [u8]) {
    let s = &src[y * l.stride..(y + 1) * l.stride];
    if l.bpc <= 1 {
        row.copy_from_slice(s);
    } else {
        for (d, c) in row.chunks_exact_mut(l.bpc).zip(s.chunks_exact(l.bpc)) {
            for (i, v) in c.iter().rev().enumerate() {
                d[i] = *v;
            }
        }
    }
}

/// Raw deflate of one band; non-final bands end with a sync flush so they end
/// byte-aligned and can be concatenated.
fn deflate_band(c: &[u8], lvl: Compression, last: bool) -> Vec<u8> {
    let mut z = Compress::new(lvl, false);
    let mut out = Vec::with_capacity(c.len() / 2 + 1024);
    let flush = if last {
        FlushCompress::Finish
    } else {
        FlushCompress::Sync
    };
    loop {
        let consumed = z.total_in() as usize;
        z.compress_vec(&c[consumed..], &mut out, flush)
            .expect("deflate");
        if z.total_in() as usize == c.len() && out.len() < out.capacity() {
            return out;
        }
        out.reserve(out.capacity().max(1024));
    }
}

fn zlib_header(level: u32) -> [u8; 2] {
    let flevel = match level {
        0 | 1 => 0,
        2..=5 => 1,
        6 => 2,
        _ => 3,
    };
    let cmf = 0x78u16;
    let mut flg = flevel << 6;
    flg += 31 - ((cmf << 8) + flg) % 31;
    [cmf as u8, flg as u8]
}

const MOD: u32 = 65521;

fn adler32(start: u32, data: &[u8]) -> u32 {
    let (mut a, mut b) = (start & 0xffff, start >> 16);
    for c in data.chunks(5552) {
        for &x in c {
            a += x as u32;
            b += a;
        }
        a %= MOD;
        b %= MOD;
    }
    (b << 16) | a
}

/// Adler-32 of A followed by B, from adler(A), adler(B) and B's length
/// (zlib's adler32_combine).
fn adler32_combine(a1: u32, a2: u32, len2: usize) -> u32 {
    let rem = (len2 % MOD as usize) as u64;
    let m = MOD as u64;
    let s1a = (a1 & 0xffff) as u64;
    let s2a = (a1 >> 16) as u64;
    let s1b = (a2 & 0xffff) as u64;
    let s2b = (a2 >> 16) as u64;
    let mut sum1 = s1a + s1b + m - 1;
    let mut sum2 = (rem * s1a) % m + s2a + s2b + m - rem;
    sum1 %= m;
    if sum1 >= m {
        sum1 -= m;
    }
    sum2 %= m;
    ((sum2 as u32) << 16) | sum1 as u32
}

// ---------------------------------------------------------------------------
// libdeflate (single-core path)
// ---------------------------------------------------------------------------

struct Comp {
    level: i32,
    ptr: NonNull<libdeflate_compressor>,
}
impl Drop for Comp {
    fn drop(&mut self) {
        unsafe { libdeflate_free_compressor(self.ptr.as_ptr()) }
    }
}

thread_local! {
    static COMP: RefCell<Option<Comp>> = const { RefCell::new(None) };
}

fn compress_zlib(data: &[u8], level: u32) -> Vec<u8> {
    let level = level as i32;
    COMP.with(|c| {
        let mut c = c.borrow_mut();
        if c.as_ref().map(|c| c.level) != Some(level) {
            let p = unsafe { libdeflate_alloc_compressor(level) };
            *c = Some(Comp {
                level,
                ptr: NonNull::new(p).expect("libdeflate OOM"),
            });
        }
        let comp = c.as_ref().unwrap().ptr.as_ptr();
        unsafe {
            let bound = libdeflate_zlib_compress_bound(comp, data.len());
            let mut out = Vec::<u8>::with_capacity(bound);
            let n = libdeflate_zlib_compress(
                comp,
                data.as_ptr() as *const _,
                data.len(),
                out.as_mut_ptr() as *mut _,
                bound,
            );
            assert!(n > 0, "libdeflate: output bound too small");
            out.set_len(n);
            out
        }
    })
}

// ---------------------------------------------------------------------------
// C API
// ---------------------------------------------------------------------------

/// Encodes the image data of a PNG. `src` holds `height` rows of `stride`
/// bytes. The output is complete IDAT chunks (length, type, data, CRC) of at
/// most `chunk_size` data bytes each, ready to put in the file. On success
/// writes a buffer (free with [`ri_free`]) and returns 0; returns -1 for
/// invalid arguments.
///
/// # Safety
/// `src` must point to `src_len` readable bytes; `out` and `out_len` must be
/// writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ri_png_encode(
    src: *const u8,
    src_len: usize,
    height: u32,
    stride: u32,
    bpp: u32,
    bpc: u32,
    filter: i32,
    level: i32,
    parallel: i32,
    chunk_size: u32,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    let (height, stride, bpp, bpc) = (height as usize, stride as usize, bpp as usize, bpc as usize);
    let Some(filter) = Filter::from_i32(filter) else {
        return -1;
    };
    if src.is_null() && src_len > 0
        || stride == 0
        || chunk_size == 0
        || bpp == 0
        || !(1..=2).contains(&bpc)
        || stride % bpc != 0
        || height.checked_mul(stride).is_none_or(|n| n > src_len)
    {
        return -1;
    }
    let data = if src_len == 0 {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(src, src_len) }
    };
    let l = Layout {
        height,
        stride,
        bpp,
        bpc,
    };
    let level = if level < 0 { 6 } else { level as u32 };
    let z = encode(data, l, filter, level, parallel != 0);
    let v = idat_chunks(&z, chunk_size as usize).into_boxed_slice();
    unsafe {
        *out_len = v.len();
        *out = Box::into_raw(v) as *mut u8;
    }
    0
}

/// Splits a zlib stream into IDAT chunks.
pub fn idat_chunks(z: &[u8], chunk_size: usize) -> Vec<u8> {
    let n = z.len().div_ceil(chunk_size).max(1);
    let mut out = Vec::with_capacity(z.len() + 12 * n);
    let mut parts: Vec<&[u8]> = z.chunks(chunk_size).collect();
    if parts.is_empty() {
        parts.push(&[]);
    }
    for p in parts {
        out.extend_from_slice(&(p.len() as u32).to_be_bytes());
        out.extend_from_slice(b"IDAT");
        out.extend_from_slice(p);
        let mut h = crc32fast::Hasher::new();
        h.update(b"IDAT");
        h.update(p);
        out.extend_from_slice(&h.finalize().to_be_bytes());
    }
    out
}

/// Frees a buffer returned by [`ri_png_encode`].
///
/// # Safety
/// `p` and `len` must come from one successful [`ri_png_encode`] call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ri_free(p: *mut u8, len: usize) {
    if !p.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(p, len)) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;

    fn image(w: usize, h: usize, bpp: usize) -> Vec<u8> {
        let mut s = 12345u32;
        (0..w * h * bpp)
            .map(|i| {
                s = s.wrapping_mul(1103515245).wrapping_add(12345);
                ((i / bpp % w + i / (w * bpp)) as u32 + (s >> 28)) as u8
            })
            .collect()
    }

    fn inflate(z: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        flate2::read::ZlibDecoder::new(z)
            .read_to_end(&mut out)
            .unwrap();
        out
    }

    #[test]
    fn parallel_equals_serial_after_inflate() {
        for &(w, h, bpp, bpc) in &[
            (1000, 900, 3, 1),
            (517, 2003, 4, 1),
            (800, 700, 8, 2),
            (3, 1, 1, 1),
        ] {
            let src = image(w, h, bpp);
            let l = Layout {
                height: h,
                stride: w * bpp,
                bpp,
                bpc,
            };
            for f in [
                Filter::None,
                Filter::Sub,
                Filter::Up,
                Filter::Average,
                Filter::Paeth,
            ] {
                let mut expect = vec![0u8; (w * bpp + 1) * h];
                filter_rows(&src, l, f, 0, h, &mut expect);
                for level in [1, 6, 9] {
                    let a = inflate(&encode(&src, l, f, level, false));
                    let b = inflate(&encode(&src, l, f, level, true));
                    assert_eq!(a, expect);
                    assert_eq!(b, expect, "{w}x{h} {f:?} {level}");
                }
            }
        }
    }

    #[test]
    fn adler_combine_matches() {
        let d = image(300, 300, 3);
        let (x, y) = d.split_at(12345);
        assert_eq!(
            adler32_combine(adler32(1, x), adler32(1, y), y.len()),
            adler32(1, &d)
        );
    }
}
