//! C API for ops.rs. Images cross as opaque handles (`*mut Img`) so a
//! pipeline keeps its pixels in Rust between steps. Every handle returned
//! here must be released with `ri_img_free`.
//!
//! Status codes: 0 ok, 1 unsupported input (the caller falls back to
//! package:image), 2 invalid arguments.

use crate::ops::{self, Adjust, Img, ResizeMode};

const OK: i32 = 0;
const UNSUPPORTED: i32 = 1;
const INVALID: i32 = 2;

unsafe fn bytes<'a>(p: *const u8, len: usize) -> &'a [u8] {
    if p.is_null() || len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(p, len) }
    }
}

fn into_handle(img: Img) -> *mut Img {
    Box::into_raw(Box::new(img))
}

unsafe fn put(out: *mut *mut Img, img: Img) -> i32 {
    unsafe { *out = into_handle(img) };
    OK
}

/// Copies `w` x `h` pixels of `nc` channels (rows packed) into a new image.
///
/// # Safety
/// `src` must point to `w * h * nc` readable bytes; `out` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ri_img_new(src: *const u8, w: u32, h: u32, nc: u32, out: *mut *mut Img) -> i32 {
    let (w, h, nc) = (w as usize, h as usize, nc as usize);
    if !(1..=4).contains(&nc) || out.is_null() {
        return INVALID;
    }
    let Some(n) = w.checked_mul(h).and_then(|v| v.checked_mul(nc)) else {
        return INVALID;
    };
    let data = unsafe { bytes(src, n) };
    if data.len() != n {
        return INVALID;
    }
    unsafe { put(out, Img { w, h, nc, data: data.to_vec() }) }
}

/// Releases an image handle.
///
/// # Safety
/// `img` must be a handle from this API, not yet freed (or null).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ri_img_free(img: *mut Img) {
    if !img.is_null() {
        drop(unsafe { Box::from_raw(img) });
    }
}

/// Writes the width, height and channel count of `img`.
///
/// # Safety
/// `img` must be a live handle; the out pointers must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ri_img_info(img: *const Img, w: *mut u32, h: *mut u32, nc: *mut u32) {
    let i = unsafe { &*img };
    unsafe {
        *w = i.w as u32;
        *h = i.h as u32;
        *nc = i.nc as u32;
    }
}

/// The pixels of `img` (`w * h * nc` bytes), valid until it is changed or
/// freed.
///
/// # Safety
/// `img` must be a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ri_img_data(img: *const Img) -> *const u8 {
    unsafe { (*img).data.as_ptr() }
}

/// Decodes a JPEG to RGB and applies EXIF `orientation` (1 to 8).
///
/// # Safety
/// `src` must point to `len` readable bytes; `out` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ri_jpeg_decode(src: *const u8, len: usize, orientation: i32, out: *mut *mut Img) -> i32 {
    match ops::decode_jpeg(unsafe { bytes(src, len) }, orientation) {
        Ok(img) => unsafe { put(out, img) },
        Err(_) => UNSUPPORTED,
    }
}

/// Decodes an 8-bit, non-palette, non-animated PNG without tRNS.
///
/// # Safety
/// `src` must point to `len` readable bytes; `out` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ri_png_decode(src: *const u8, len: usize, out: *mut *mut Img) -> i32 {
    match ops::decode_png(unsafe { bytes(src, len) }) {
        Ok(img) => unsafe { put(out, img) },
        Err(_) => UNSUPPORTED,
    }
}

/// Encodes a 3 or 4 channel image to JPEG. `app1`/`app2` are optional segment
/// bodies (EXIF, ICC). On success writes a buffer to free with `ri_free`.
///
/// # Safety
/// `img` must be a live handle; the segment pointers must point to their
/// lengths of readable bytes; `out` and `out_len` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ri_jpeg_encode(
    img: *const Img,
    quality: i32,
    chroma420: i32,
    bg_r: u32,
    bg_g: u32,
    bg_b: u32,
    app1: *const u8,
    app1_len: usize,
    app2: *const u8,
    app2_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    let i = unsafe { &*img };
    let a1 = unsafe { bytes(app1, app1_len) };
    let a2 = unsafe { bytes(app2, app2_len) };
    let bg = [bg_r.min(255) as u8, bg_g.min(255) as u8, bg_b.min(255) as u8];
    match ops::encode_jpeg(
        i,
        quality.clamp(1, 100) as u8,
        chroma420 != 0,
        bg,
        (!a1.is_empty()).then_some(a1),
        (!a2.is_empty()).then_some(a2),
    ) {
        Ok(v) => {
            let v = v.into_boxed_slice();
            unsafe {
                *out_len = v.len();
                *out = Box::into_raw(v) as *mut u8;
            }
            OK
        }
        Err(_) => UNSUPPORTED,
    }
}

/// Resizes to `w` x `h` (EXIF `orientation` applied first) into a new image.
/// `mode`: 0 nearest, 1 linear, 2 cubic, 3 average (package:image's exact
/// algorithms); 10 box, 11 bilinear, 12 Catmull-Rom, 13 Mitchell,
/// 14 Lanczos3.
///
/// # Safety
/// `img` must be a live handle; `out` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ri_resize(img: *const Img, w: u32, h: u32, mode: i32, orientation: i32, out: *mut *mut Img) -> i32 {
    let Some(m) = ResizeMode::from_i32(mode) else {
        return INVALID;
    };
    let i = unsafe { &*img };
    if i.w == 0 || i.h == 0 || w == 0 || h == 0 {
        return INVALID;
    }
    unsafe { put(out, ops::resize(i, orientation, w as usize, h as usize, m)) }
}

/// Applies EXIF `orientation` into a new image.
///
/// # Safety
/// `img` must be a live handle; `out` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ri_orient(img: *const Img, orientation: i32, out: *mut *mut Img) -> i32 {
    unsafe { put(out, ops::orient(&*img, orientation)) }
}

/// Rotates by `angle` degrees into a new image (`interp`: 0 nearest,
/// 1 linear, 2 cubic).
///
/// # Safety
/// `img` must be a live handle; `out` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ri_rotate(img: *const Img, angle: f64, interp: i32, out: *mut *mut Img) -> i32 {
    if !angle.is_finite() {
        return INVALID;
    }
    unsafe { put(out, ops::rotate(&*img, angle, interp)) }
}

/// Crops into a new image, clipped to the bounds.
///
/// # Safety
/// `img` must be a live handle; `out` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ri_crop(img: *const Img, x: u32, y: u32, w: u32, h: u32, out: *mut *mut Img) -> i32 {
    unsafe { put(out, ops::crop(&*img, x as usize, y as usize, w as usize, h as usize)) }
}

/// Flips in place: 0 horizontal, 1 vertical, 2 both.
///
/// # Safety
/// `img` must be a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ri_flip(img: *mut Img, dir: i32) -> i32 {
    if !(0..=2).contains(&dir) {
        return INVALID;
    }
    ops::flip(unsafe { &mut *img }, dir);
    OK
}

/// Gaussian blur in place, as package:image's gaussianBlur.
///
/// # Safety
/// `img` must be a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ri_blur(img: *mut Img, radius: i32) -> i32 {
    ops::gaussian_blur(unsafe { &mut *img }, radius as i64);
    OK
}

/// adjustColor in place. NaN means "not given".
///
/// # Safety
/// `img` must be a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ri_adjust(
    img: *mut Img,
    contrast: f64,
    saturation: f64,
    brightness: f64,
    gamma: f64,
    exposure: f64,
    hue: f64,
    amount: f64,
) -> i32 {
    let opt = |v: f64| (!v.is_nan()).then_some(v);
    let i = unsafe { &mut *img };
    if i.nc < 3 {
        return UNSUPPORTED;
    }
    ops::adjust_color(
        i,
        Adjust {
            contrast: opt(contrast),
            saturation: opt(saturation),
            brightness: opt(brightness),
            gamma: opt(gamma),
            exposure: opt(exposure),
            hue: opt(hue),
            amount,
        },
    );
    OK
}
