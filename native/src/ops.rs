//! Image operations behind rapid_image's drop-in replacements for
//! package:image functions, and the pipeline API.
//!
//! Two kinds of operation live here:
//!
//! * Ports of package:image's own algorithms (copyResize's nearest, linear,
//!   average and cubic paths, copyRotate, gaussianBlur, adjustColor, EXIF
//!   orientation). They do the same floating-point steps in the same order,
//!   so they give the same pixels, but run in parallel over rows.
//! * Codecs and filters from Rust crates: JPEG decoding (zune-jpeg) and
//!   encoding (jpeg-encoder), PNG decoding (png) and high-quality resampling
//!   (fast_image_resize). These are faster than package:image, and close to
//!   it, but not identical.
//!
//! Images are 8-bit, 1 to 4 interleaved channels, rows packed with no padding,
//! the layout package:image uses for `Format.uint8`.

use rayon::prelude::*;

/// An 8-bit image with `nc` interleaved channels.
pub struct Img {
    pub w: usize,
    pub h: usize,
    pub nc: usize,
    pub data: Vec<u8>,
}

impl Img {
    pub fn new(w: usize, h: usize, nc: usize) -> Img {
        Img {
            w,
            h,
            nc,
            data: vec![0; w * h * nc],
        }
    }

    fn stride(&self) -> usize {
        self.w * self.nc
    }
}

// ---------------------------------------------------------------------------
// EXIF orientation
// ---------------------------------------------------------------------------

/// The pixels of an image seen with an EXIF orientation applied: oriented
/// pixel (x, y) starts at byte `base + x * col + y * row`. The same table as
/// package:image's `_OrientedSource`.
struct Oriented<'a> {
    s: &'a [u8],
    k: usize,
    w: usize,
    h: usize,
    base: isize,
    col: isize,
    row: isize,
}

impl<'a> Oriented<'a> {
    fn new(img: &'a Img, orientation: i32) -> Oriented<'a> {
        let k = img.nc as isize;
        let stride = img.stride() as isize;
        let last_col = (img.w as isize - 1) * k;
        let last_row = (img.h as isize - 1) * stride;
        let (base, col, row) = match orientation {
            2 => (last_col, -k, stride),
            3 => (last_row + last_col, -k, -stride),
            4 => (last_row, k, -stride),
            5 => (0, stride, k),
            6 => (last_row, -stride, k),
            7 => (last_row + last_col, -stride, -k),
            8 => (last_col, stride, -k),
            _ => (0, k, stride),
        };
        let swap = (5..=8).contains(&orientation);
        Oriented {
            s: &img.data,
            k: img.nc,
            w: if swap { img.h } else { img.w },
            h: if swap { img.w } else { img.h },
            base,
            col,
            row,
        }
    }

    #[inline]
    fn row_start(&self, y: usize) -> isize {
        self.base + y as isize * self.row
    }
}

/// Applies an EXIF orientation (2 to 8) to `img`, as package:image's
/// bakeOrientation does. Other values return a copy.
pub fn orient(img: &Img, orientation: i32) -> Img {
    if !(2..=8).contains(&orientation) {
        return Img {
            data: img.data.clone(),
            ..*img
        };
    }
    let src = Oriented::new(img, orientation);
    let mut dst = Img::new(src.w, src.h, img.nc);
    let k = img.nc;
    let stride = dst.stride();
    dst.data.par_chunks_mut(stride).enumerate().for_each(|(y, out)| {
        let mut si = src.row_start(y);
        for px in out.chunks_exact_mut(k) {
            let i = si as usize;
            px.copy_from_slice(&src.s[i..i + k]);
            si += src.col;
        }
    });
    dst
}

// ---------------------------------------------------------------------------
// Resize: package:image's copyResize, exactly
// ---------------------------------------------------------------------------

/// package:image's `Interpolation`, plus fast_image_resize filters (10+).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ResizeMode {
    Nearest,
    Linear,
    Cubic,
    Average,
    Box,
    Bilinear,
    CatmullRom,
    Mitchell,
    Lanczos3,
}

impl ResizeMode {
    pub fn from_i32(v: i32) -> Option<ResizeMode> {
        Some(match v {
            0 => ResizeMode::Nearest,
            1 => ResizeMode::Linear,
            2 => ResizeMode::Cubic,
            3 => ResizeMode::Average,
            10 => ResizeMode::Box,
            11 => ResizeMode::Bilinear,
            12 => ResizeMode::CatmullRom,
            13 => ResizeMode::Mitchell,
            14 => ResizeMode::Lanczos3,
            _ => return None,
        })
    }
}

/// Resizes `img`, with EXIF `orientation` applied first, to `w` x `h`. The
/// package:image modes give copyResize's result (without maintainAspect);
/// the others use fast_image_resize.
pub fn resize(img: &Img, orientation: i32, w: usize, h: usize, mode: ResizeMode) -> Img {
    match mode {
        ResizeMode::Nearest | ResizeMode::Linear | ResizeMode::Cubic | ResizeMode::Average => {
            resize_exact(img, orientation, w, h, mode)
        }
        _ => {
            if (2..=8).contains(&orientation) {
                resize_hq(&orient(img, orientation), w, h, mode)
            } else {
                resize_hq(img, w, h, mode)
            }
        }
    }
}

fn resize_exact(img: &Img, orientation: i32, w: usize, h: usize, mode: ResizeMode) -> Img {
    let src = Oriented::new(img, orientation);
    let (sw, sh, k) = (src.w, src.h, src.k);
    let mut dst = Img::new(w, h, k);
    if w == 0 || h == 0 {
        return dst;
    }
    // copyResize: dx = srcWidth / w, as doubles.
    let dx = sw as f64 / w as f64;
    let dy = sh as f64 / h as f64;
    let stride = dst.stride();
    let s = src.s;
    match mode {
        ResizeMode::Nearest => {
            let src_x: Vec<isize> = (0..w).map(|x| ((x * sw) / w) as isize * src.col).collect();
            dst.data.par_chunks_mut(stride).enumerate().for_each(|(y, out)| {
                let row = src.row_start((y * sh) / h);
                for (px, &sx) in out.chunks_exact_mut(k).zip(&src_x) {
                    let i = (row + sx) as usize;
                    px.copy_from_slice(&s[i..i + k]);
                }
            });
        }
        ResizeMode::Linear => {
            let max_x = sw - 1;
            let max_y = sh - 1;
            let cols: Vec<(isize, isize, f64)> = (0..w)
                .map(|x| {
                    let fx = x as f64 * dx;
                    let ix = fx as usize;
                    let kx = fx - ix as f64;
                    let nx = (ix + 1).min(max_x);
                    (ix as isize * src.col, nx as isize * src.col, kx)
                })
                .collect();
            dst.data.par_chunks_mut(stride).enumerate().for_each(|(y, out)| {
                let fy = y as f64 * dy;
                let iy = fy as usize;
                let ky = fy - iy as f64;
                let ny = (iy + 1).min(max_y);
                let (r0, r1) = (src.row_start(iy), src.row_start(ny));
                for (px, &(ix, nx, kx)) in out.chunks_exact_mut(k).zip(&cols) {
                    let (i0, n0, i1, n1) = (
                        (r0 + ix) as usize,
                        (r0 + nx) as usize,
                        (r1 + ix) as usize,
                        (r1 + nx) as usize,
                    );
                    for c in 0..k {
                        let icc = s[i0 + c] as f64;
                        let inc = s[n0 + c] as f64;
                        let icn = s[i1 + c] as f64;
                        let inn = s[n1 + c] as f64;
                        let v = icc + kx * (inc - icc + ky * (icc + inn - icn - inc)) + ky * (icn - icc);
                        px[c] = v as i64 as u8;
                    }
                }
            });
        }
        ResizeMode::Average => {
            let span = |i: usize, d: f64| {
                let a1 = (i as f64 * d) as usize;
                let mut a2 = ((i + 1) as f64 * d) as usize;
                if a2 == a1 {
                    a2 += 1;
                }
                (a1, a2)
            };
            let cols: Vec<(usize, usize)> = (0..w).map(|x| span(x, dx)).collect();
            dst.data.par_chunks_mut(stride).enumerate().for_each(|(y, out)| {
                let (ay1, ay2) = span(y, dy);
                let mut sums = [0i64; 4];
                for (px, &(ax1, ax2)) in out.chunks_exact_mut(k).zip(&cols) {
                    sums[..k].fill(0);
                    for sy in ay1..ay2 {
                        let mut si = src.row_start(sy) + ax1 as isize * src.col;
                        for _ in ax1..ax2 {
                            let i = si as usize;
                            for c in 0..k {
                                sums[c] += s[i + c] as i64;
                            }
                            si += src.col;
                        }
                    }
                    let inv = 1.0 / (((ay2 - ay1) * (ax2 - ax1)) as f64);
                    for c in 0..k {
                        px[c] = (sums[c] as f64 * inv) as i64 as u8;
                    }
                }
            });
        }
        ResizeMode::Cubic => {
            // Per column: the four tap offsets, whether each is inside, and
            // the fraction. A tap outside the image uses the centre pixel.
            let cols: Vec<([isize; 4], [bool; 4], f64)> = (0..w)
                .map(|x| {
                    let fx = x as f64 * dx;
                    let ix = fx as isize;
                    let mut off = [0isize; 4];
                    let mut inside = [false; 4];
                    for t in 0..4 {
                        let cx = ix + t as isize - 1;
                        off[t] = cx * src.col;
                        inside[t] = cx >= 0 && cx < sw as isize;
                    }
                    (off, inside, fx - ix as f64)
                })
                .collect();
            dst.data.par_chunks_mut(stride).enumerate().for_each(|(y, out)| {
                let fy = y as f64 * dy;
                let iy = fy as isize;
                let ky = fy - iy as f64;
                let mut rows = [0isize; 4];
                let mut row_in = [false; 4];
                for t in 0..4 {
                    let cy = iy + t as isize - 1;
                    rows[t] = src.base + cy * src.row;
                    row_in[t] = cy >= 0 && cy < sh as isize;
                }
                let mut taps = [0usize; 16];
                let mut p = [0f64; 4];
                for (px, (off, inside, kx)) in out.chunks_exact_mut(k).zip(&cols) {
                    let center = rows[1] + off[1];
                    for r in 0..4 {
                        for t in 0..4 {
                            taps[r * 4 + t] = if !row_in[r] || !inside[t] {
                                center as usize
                            } else {
                                (rows[r] + off[t]) as usize
                            };
                        }
                    }
                    for c in 0..k {
                        for r in 0..4 {
                            let o = r * 4;
                            p[r] = cubic(
                                *kx,
                                s[taps[o] + c] as f64,
                                s[taps[o + 1] + c] as f64,
                                s[taps[o + 2] + c] as f64,
                                s[taps[o + 3] + c] as f64,
                            );
                        }
                        let v = cubic(ky, p[0], p[1], p[2], p[3]);
                        px[c] = if v < 0.0 {
                            0
                        } else if v > 255.0 {
                            255
                        } else {
                            v as u8
                        };
                    }
                }
            });
        }
        _ => unreachable!(),
    }
    dst
}

/// package:image's `_cubic`, term for term.
#[inline]
fn cubic(dx: f64, ipp: f64, icp: f64, inp: f64, iap: f64) -> f64 {
    icp + 0.5
        * (dx * (-ipp + inp)
            + dx * dx * (2.0 * ipp - 5.0 * icp + 4.0 * inp - iap)
            + dx * dx * dx * (-ipp + 3.0 * icp - 3.0 * inp + iap))
}

/// High-quality resampling with fast_image_resize (SIMD, all cores). Alpha
/// is premultiplied while filtering, so transparent pixels don't bleed.
fn resize_hq(img: &Img, w: usize, h: usize, mode: ResizeMode) -> Img {
    use fast_image_resize::images::{Image, ImageRef};
    use fast_image_resize::{FilterType, PixelType, ResizeAlg, ResizeOptions, Resizer};
    let pt = match img.nc {
        1 => PixelType::U8,
        2 => PixelType::U8x2,
        3 => PixelType::U8x3,
        _ => PixelType::U8x4,
    };
    let mut out = Img::new(w, h, img.nc);
    if w == 0 || h == 0 || img.w == 0 || img.h == 0 {
        return out;
    }
    let alg = ResizeAlg::Convolution(match mode {
        ResizeMode::Box => FilterType::Box,
        ResizeMode::Bilinear => FilterType::Bilinear,
        ResizeMode::CatmullRom => FilterType::CatmullRom,
        ResizeMode::Mitchell => FilterType::Mitchell,
        _ => FilterType::Lanczos3,
    });
    let src = ImageRef::new(img.w as u32, img.h as u32, &img.data, pt).expect("buffer size");
    let mut dst = Image::new(w as u32, h as u32, pt);
    Resizer::new()
        .resize(&src, &mut dst, &ResizeOptions::new().resize_alg(alg))
        .expect("resize");
    out.data = dst.into_vec();
    out
}

// ---------------------------------------------------------------------------
// Crop, flip, rotate
// ---------------------------------------------------------------------------

/// The `w` x `h` region at (`x`, `y`), clipped to the image.
pub fn crop(img: &Img, x: usize, y: usize, w: usize, h: usize) -> Img {
    let x = x.min(img.w);
    let y = y.min(img.h);
    let w = w.min(img.w - x);
    let h = h.min(img.h - y);
    let mut dst = Img::new(w, h, img.nc);
    let (k, ss) = (img.nc, img.stride());
    let ds = dst.stride();
    for r in 0..h {
        let s0 = (y + r) * ss + x * k;
        dst.data[r * ds..(r + 1) * ds].copy_from_slice(&img.data[s0..s0 + ds]);
    }
    dst
}

/// Flips in place: 0 horizontal, 1 vertical, 2 both.
pub fn flip(img: &mut Img, dir: i32) {
    let (k, stride, h) = (img.nc, img.stride(), img.h);
    if dir == 0 || dir == 2 {
        img.data.par_chunks_mut(stride).for_each(|row| {
            let n = row.len() / k;
            for x in 0..n / 2 {
                let (a, b) = (x * k, (n - 1 - x) * k);
                for c in 0..k {
                    row.swap(a + c, b + c);
                }
            }
        });
    }
    if dir == 1 || dir == 2 {
        for y in 0..h / 2 {
            let (top, bottom) = img.data.split_at_mut((h - 1 - y) * stride);
            top[y * stride..(y + 1) * stride].swap_with_slice(&mut bottom[..stride]);
        }
    }
}

/// package:image's copyRotate: `interp` 0 nearest, 1 linear (and average),
/// 2 cubic. Right angles are exact transposes; other angles grow the canvas
/// to fit, leaving the corners zero (transparent, or black without alpha).
pub fn rotate(img: &Img, angle: f64, interp: i32) -> Img {
    let n_angle = angle.rem_euclid(360.0);
    let k = img.nc;
    if n_angle.rem_euclid(90.0) == 0.0 {
        let (w, h) = (img.w, img.h);
        return match (n_angle / 90.0) as i64 {
            1 => orient_like(img, |x, y| (y, h - 1 - x), h, w),
            2 => orient_like(img, |x, y| (w - 1 - x, h - 1 - y), w, h),
            3 => orient_like(img, |x, y| (w - 1 - y, x), h, w),
            _ => Img {
                data: img.data.clone(),
                ..*img
            },
        };
    }
    let rad = n_angle * std::f64::consts::PI / 180.0;
    let ca = rad.cos();
    let sa = rad.sin();
    let (sw, sh) = (img.w as f64, img.h as f64);
    let ux = (sw * ca).abs();
    let uy = (sw * sa).abs();
    let vx = (sh * sa).abs();
    let vy = (sh * ca).abs();
    let w2 = 0.5 * sw;
    let h2 = 0.5 * sh;
    let dw2 = 0.5 * (ux + vx);
    let dh2 = 0.5 * (uy + vy);
    let mut dst = Img::new((ux + vx) as usize, (uy + vy) as usize, k);
    if dst.w == 0 || dst.h == 0 {
        return dst;
    }
    let (iw, ih) = (img.w as i64, img.h as i64);
    let s = &img.data;
    let stride = img.stride();
    let at = |x: i64, y: i64| y as usize * stride + x as usize * k;
    let ds = dst.stride();
    dst.data.par_chunks_mut(ds).enumerate().for_each(|(y, out)| {
        let yf = y as f64;
        for (x, px) in out.chunks_exact_mut(k).enumerate() {
            let xf = x as f64;
            let x2 = w2 + (xf - dw2) * ca + (yf - dh2) * sa;
            let y2 = h2 - (xf - dw2) * sa + (yf - dh2) * ca;
            if !(x2 >= 0.0 && y2 >= 0.0 && x2 < sw && y2 < sh) {
                continue;
            }
            match interp {
                0 => {
                    let i = at(x2 as i64, y2 as i64);
                    px.copy_from_slice(&s[i..i + k]);
                }
                2 => cubic_sample(s, k, at, iw, ih, x2, y2, px),
                _ => linear_sample(s, k, at, iw, ih, x2, y2, px),
            }
        }
    });
    dst
}

/// Builds a `w` x `h` image whose pixel (x, y) is source pixel `map(x, y)`.
fn orient_like(img: &Img, map: impl Fn(usize, usize) -> (usize, usize) + Sync, w: usize, h: usize) -> Img {
    let k = img.nc;
    let ss = img.stride();
    let mut dst = Img::new(w, h, k);
    let ds = dst.stride();
    dst.data.par_chunks_mut(ds).enumerate().for_each(|(y, out)| {
        for (x, px) in out.chunks_exact_mut(k).enumerate() {
            let (sx, sy) = map(x, y);
            let i = sy * ss + sx * k;
            px.copy_from_slice(&img.data[i..i + k]);
        }
    });
    dst
}

/// Image.getPixelLinear for a coordinate inside the image, then getColor's
/// clamp and truncation.
#[inline]
#[allow(clippy::too_many_arguments)]
fn linear_sample(
    s: &[u8],
    k: usize,
    at: impl Fn(i64, i64) -> usize,
    w: i64,
    h: i64,
    fx: f64,
    fy: f64,
    px: &mut [u8],
) {
    let x = fx as i64;
    let y = fy as i64;
    let (nx, ny) = (x + 1, y + 1);
    let dx = fx - x as f64;
    let dy = fy - y as f64;
    let icc = at(x, y);
    let icn = if ny >= h { icc } else { at(x, ny) };
    let inc = if nx >= w { icc } else { at(nx, y) };
    let inn = if nx >= w || ny >= h { icc } else { at(nx, ny) };
    for c in 0..k {
        let (a, b, cc, d) = (
            s[icc + c] as f64,
            s[inc + c] as f64,
            s[icn + c] as f64,
            s[inn + c] as f64,
        );
        let v = a + dx * (b - a + dy * (a + d - cc - b)) + dy * (cc - a);
        px[c] = v.clamp(0.0, 255.0) as u8;
    }
}

/// Image.getPixelCubic for a coordinate inside the image.
#[inline]
#[allow(clippy::too_many_arguments)]
fn cubic_sample(
    s: &[u8],
    k: usize,
    at: impl Fn(i64, i64) -> usize,
    w: i64,
    h: i64,
    fx: f64,
    fy: f64,
    px: &mut [u8],
) {
    let x = fx as i64;
    let y = fy as i64;
    let (px_, nx, ax) = (x - 1, x + 1, x + 2);
    let (py, ny, ay) = (y - 1, y + 1, y + 2);
    let dx = fx - x as f64;
    let dy = fy - y as f64;
    let icc = at(x, y);
    // Each of the 16 taps, or the centre where getPixelCubic uses it.
    let tap = |cx: i64, cy: i64, out: bool| if out { icc } else { at(cx, cy) };
    let rows = [
        [
            tap(px_, py, px_ < 0 || py < 0),
            tap(x, py, py < 0),
            tap(nx, py, py < 0 || nx >= w),
            tap(ax, py, ax >= w || py < 0),
        ],
        [
            tap(px_, y, px_ < 0),
            icc,
            tap(nx, y, nx >= w),
            tap(ax, y, ax >= w),
        ],
        [
            tap(px_, ny, px_ < 0 || ny >= h),
            tap(x, ny, ny >= h),
            tap(nx, ny, nx >= w || ny >= h),
            tap(ax, ny, ax >= w || ny >= h),
        ],
        [
            tap(px_, ay, px_ < 0 || ay >= h),
            tap(x, ay, ay >= h),
            tap(nx, ay, nx >= w || ay >= h),
            tap(ax, ay, ax >= w || ay >= h),
        ],
    ];
    for c in 0..k {
        let v = |i: usize| s[i + c] as f64;
        let r: [f64; 4] = std::array::from_fn(|i| {
            let t = &rows[i];
            cubic(dx, v(t[0]), v(t[1]), v(t[2]), v(t[3]))
        });
        let out = cubic(dy, r[0], r[1], r[2], r[3]);
        px[c] = out.clamp(0.0, 255.0) as u8;
    }
}

// ---------------------------------------------------------------------------
// Gaussian blur: package:image's gaussianBlur, exactly
// ---------------------------------------------------------------------------

/// reflectIndex from package:image.
#[inline]
fn reflect(max: i64, x: i64) -> usize {
    let mut x = x.abs();
    if x >= max {
        x = max - (x - max) - 1;
    }
    x.clamp(0, max - 1) as usize
}

/// The normalised kernel gaussianBlur uses for `radius`.
fn gaussian_kernel(radius: i64) -> Vec<f64> {
    let sigma = radius as f64 * (2.0 / 3.0);
    let s = 2.0 * sigma * sigma;
    let mut k = Vec::with_capacity((2 * radius + 1) as usize);
    let mut sum = 0.0;
    for x in -radius..=radius {
        let c = (-(x * x) as f64 / s).exp();
        sum += c;
        k.push(c);
    }
    let scale = 1.0 / sum;
    k.iter().map(|c| c * scale).collect()
}

/// Blurs in place. Each channel is filtered horizontally and stored as a
/// byte, then vertically, with the taps summed in package:image's order and
/// edges reflected, so the result matches its uint8 fast path.
pub fn gaussian_blur(img: &mut Img, radius: i64) {
    if radius <= 0 || img.w < 2 || img.h < 2 {
        return;
    }
    let k = gaussian_kernel(radius);
    let (w, h, nc) = (img.w as i64, img.h as i64, img.nc);
    let stride = img.stride();
    let size = radius;
    let pad: Vec<usize> = (-size..w + size).map(|x| reflect(w, x) * nc).collect();
    let mut tmp = vec![0u8; img.data.len()];
    let src = &img.data;
    tmp.par_chunks_mut(stride).enumerate().for_each(|(y, out)| {
        let line = &src[y * stride..(y + 1) * stride];
        let mut padded = vec![0u8; pad.len() * nc];
        for (i, &p) in pad.iter().enumerate() {
            padded[i * nc..(i + 1) * nc].copy_from_slice(&line[p..p + nc]);
        }
        let mut acc = vec![0f64; stride];
        for (i, a) in acc.iter_mut().enumerate() {
            *a = k[0] * padded[i] as f64;
        }
        for (j, &c) in k.iter().enumerate().skip(1) {
            let o = j * nc;
            for (i, a) in acc.iter_mut().enumerate() {
                *a += c * padded[o + i] as f64;
            }
        }
        for (o, a) in out.iter_mut().zip(&acc) {
            *o = *a as i64 as u8;
        }
    });
    img.data.par_chunks_mut(stride).enumerate().for_each(|(y, out)| {
        let rows: Vec<usize> = (0..k.len() as i64)
            .map(|j| reflect(h, y as i64 + j - size) * stride)
            .collect();
        let mut acc = vec![0f64; stride];
        let r0 = &tmp[rows[0]..rows[0] + stride];
        for (a, &v) in acc.iter_mut().zip(r0) {
            *a = k[0] * v as f64;
        }
        for (j, &c) in k.iter().enumerate().skip(1) {
            let r = &tmp[rows[j]..rows[j] + stride];
            for (a, &v) in acc.iter_mut().zip(r) {
                *a += c * v as f64;
            }
        }
        for (o, a) in out.iter_mut().zip(&acc) {
            *o = *a as i64 as u8;
        }
    });
}

// ---------------------------------------------------------------------------
// adjustColor: package:image's, exactly (without blacks/whites/mids or mask)
// ---------------------------------------------------------------------------

/// adjustColor's parameters; `None` means the argument wasn't given.
#[derive(Clone, Copy, Debug, Default)]
pub struct Adjust {
    pub contrast: Option<f64>,
    pub saturation: Option<f64>,
    pub brightness: Option<f64>,
    pub gamma: Option<f64>,
    pub exposure: Option<f64>,
    pub hue: Option<f64>,
    pub amount: f64,
}

/// Dart's `min`/`max` for doubles that aren't NaN.
#[inline]
fn dmin(a: f64, b: f64) -> f64 {
    if a > b { b } else { a }
}
#[inline]
fn dmax(a: f64, b: f64) -> f64 {
    if a < b { b } else { a }
}

fn rgb_to_hsv(r: f64, g: f64, b: f64) -> [f64; 3] {
    let min_ch = dmin(r, dmin(g, b));
    let max_ch = dmax(r, dmax(g, b));
    let delta = max_ch - min_ch;
    if max_ch == 0.0 || delta == 0.0 {
        return [0.0, 0.0, max_ch];
    }
    let s = delta / max_ch;
    let mut h = if r == max_ch {
        (g - b) / delta
    } else if g == max_ch {
        2.0 + (b - r) / delta
    } else {
        4.0 + (r - g) / delta
    };
    h *= 60.0;
    if h < 0.0 {
        h += 360.0;
    }
    [h, s, max_ch]
}

fn hsv_to_rgb(mut h: f64, s: f64, v: f64) -> [f64; 3] {
    if s == 0.0 {
        let g = v.clamp(0.0, 1.0);
        return [g, g, g];
    }
    while h < 0.0 {
        h += 360.0;
    }
    while h > 360.0 {
        h -= 360.0;
    }
    h /= 60.0;
    let i = h.floor();
    let f = h - i;
    let p = (v * (1.0 - s)).clamp(0.0, 1.0);
    let q = (v * (1.0 - s * f)).clamp(0.0, 1.0);
    let t = (v * (1.0 - s * (1.0 - f))).clamp(0.0, 1.0);
    match i as i64 {
        0 => [v, t, p],
        1 => [q, v, p],
        2 => [p, v, t],
        3 => [p, q, v],
        4 => [t, p, v],
        _ => [v, p, q],
    }
}

/// Adjusts the RGB channels of a 3 or 4 channel image in place. Alpha is
/// left alone, as in package:image.
pub fn adjust_color(img: &mut Img, a: Adjust) {
    if a.amount == 0.0 || img.nc < 3 {
        return;
    }
    let contrast = a.contrast.map(|c| c.clamp(0.0, 2.0));
    let gamma = a.gamma.map(|g| g.clamp(0.0, 1000.0));
    let exposure = a.exposure.map(|e| 2f64.powf(e.clamp(0.0, 1000.0)));
    let amount = a.amount.clamp(0.0, 1000.0);
    let brightness = a.brightness.filter(|&b| b != 1.0).map(|b| b.clamp(0.0, 1000.0));
    let inv_contrast = contrast.map_or(0.0, |c| 1.0 - c);
    const AVG: f64 = 0.5;

    let tail = |mut c: f64| {
        if let Some(k) = contrast {
            c = AVG * inv_contrast + c * k;
        }
        if let Some(g) = gamma {
            c = c.powf(g);
        }
        if let Some(e) = exposure {
            c *= e;
        }
        c
    };
    let mix = |x: f64, y: f64| x * (1.0 - amount) + y * amount;
    let store = |c: f64| (c.clamp(0.0, 1.0) * 255.0).clamp(0.0, 255.0) as u8;
    let nc = img.nc;

    if a.saturation.is_none() && a.hue.is_none() {
        // Each channel depends only on itself: one lookup table.
        let mut lut = [0u8; 256];
        for (v, out) in lut.iter_mut().enumerate() {
            let o = v as f64 / 255.0;
            let mut c = o;
            if let Some(b) = brightness {
                c *= b;
            }
            *out = store(mix(o, tail(c)));
        }
        img.data.par_chunks_mut(nc * 4096).for_each(|chunk| {
            for p in chunk.chunks_exact_mut(nc) {
                p[0] = lut[p[0] as usize];
                p[1] = lut[p[1] as usize];
                p[2] = lut[p[2] as usize];
            }
        });
        return;
    }

    let hue = a.hue.unwrap_or(0.0);
    let sat = a.saturation.unwrap_or(1.0);
    img.data.par_chunks_mut(nc * 4096).for_each(|chunk| {
        for p in chunk.chunks_exact_mut(nc) {
            let or = p[0] as f64 / 255.0;
            let og = p[1] as f64 / 255.0;
            let ob = p[2] as f64 / 255.0;
            let (mut r, mut g, mut b) = (or, og, ob);
            if let Some(k) = brightness {
                r *= k;
                g *= k;
                b *= k;
            }
            let mut hsv = rgb_to_hsv(r, g, b);
            hsv[0] += hue;
            hsv[1] *= sat;
            let rgb = hsv_to_rgb(hsv[0], hsv[1], hsv[2]);
            p[0] = store(mix(or, tail(rgb[0])));
            p[1] = store(mix(og, tail(rgb[1])));
            p[2] = store(mix(ob, tail(rgb[2])));
        }
    });
}

// ---------------------------------------------------------------------------
// Codecs
// ---------------------------------------------------------------------------

/// Decodes a JPEG to RGB with zune-jpeg, then applies `orientation`.
pub fn decode_jpeg(data: &[u8], orientation: i32) -> Result<Img, String> {
    use zune_jpeg::zune_core::colorspace::ColorSpace;
    use zune_jpeg::zune_core::options::DecoderOptions;
    let opts = DecoderOptions::default()
        .jpeg_set_out_colorspace(ColorSpace::RGB)
        .set_max_width(1 << 16)
        .set_max_height(1 << 16);
    let mut d = zune_jpeg::JpegDecoder::new_with_options(data, opts);
    let px = d.decode().map_err(|e| format!("{e:?}"))?;
    let (w, h) = d.dimensions().ok_or("no dimensions")?;
    if px.len() != w * h * 3 {
        return Err("unexpected output size".into());
    }
    let img = Img {
        w,
        h,
        nc: 3,
        data: px,
    };
    Ok(if (2..=8).contains(&orientation) {
        orient(&img, orientation)
    } else {
        img
    })
}

/// Encodes RGB or RGBA (blended onto `bg`, as package:image does) to JPEG,
/// with optional APP1 (EXIF) and APP2 (ICC) segment bodies.
pub fn encode_jpeg(
    img: &Img,
    quality: u8,
    chroma420: bool,
    bg: [u8; 3],
    app1: Option<&[u8]>,
    app2: Option<&[u8]>,
) -> Result<Vec<u8>, String> {
    use jpeg_encoder::{ColorType, Encoder, SamplingFactor};
    if img.w > 65535 || img.h > 65535 || img.nc < 3 {
        return Err("unsupported image".into());
    }
    let blended;
    let rgb: &[u8] = if img.nc == 4 {
        let mut out = vec![0u8; img.w * img.h * 3];
        out.par_chunks_mut(3 * 4096)
            .zip(img.data.par_chunks(4 * 4096))
            .for_each(|(o, s)| {
                for (d, p) in o.chunks_exact_mut(3).zip(s.chunks_exact(4)) {
                    let a = p[3] as f64 / 255.0;
                    let inv = 1.0 - a;
                    for c in 0..3 {
                        d[c] = (p[c] as f64 * a + bg[c] as f64 * inv).round().clamp(0.0, 255.0) as u8;
                    }
                }
            });
        blended = out;
        &blended
    } else {
        &img.data
    };
    let mut out = Vec::with_capacity(img.w * img.h / 2);
    let mut enc = Encoder::new(&mut out, quality.clamp(1, 100));
    enc.set_sampling_factor(if chroma420 {
        SamplingFactor::F_2_2
    } else {
        SamplingFactor::F_1_1
    });
    if let Some(a) = app1 {
        enc.add_app_segment(1, a).map_err(|e| format!("{e:?}"))?;
    }
    if let Some(a) = app2 {
        enc.add_app_segment(2, a).map_err(|e| format!("{e:?}"))?;
    }
    enc.encode(rgb, img.w as u16, img.h as u16, ColorType::Rgb)
        .map_err(|e| format!("{e:?}"))?;
    Ok(out)
}

/// Decodes an 8-bit grey, grey+alpha, RGB or RGBA PNG (no palette, no tRNS,
/// not animated). Anything else is an error, so the caller falls back.
pub fn decode_png(data: &[u8]) -> Result<Img, String> {
    use png::{BitDepth, ColorType, Decoder, Limits, Transformations};
    let mut dec = Decoder::new_with_limits(data, Limits { bytes: usize::MAX });
    dec.set_transformations(Transformations::IDENTITY);
    let mut r = dec.read_info().map_err(|e| e.to_string())?;
    let info = r.info();
    if info.bit_depth != BitDepth::Eight || info.trns.is_some() || info.animation_control.is_some() {
        return Err("unsupported".into());
    }
    let nc = match info.color_type {
        ColorType::Grayscale => 1,
        ColorType::GrayscaleAlpha => 2,
        ColorType::Rgb => 3,
        ColorType::Rgba => 4,
        _ => return Err("unsupported".into()),
    };
    let (w, h) = (info.width as usize, info.height as usize);
    let mut buf = vec![0; r.output_buffer_size()];
    let fi = r.next_frame(&mut buf).map_err(|e| e.to_string())?;
    if fi.line_size != w * nc {
        return Err("unexpected layout".into());
    }
    buf.truncate(w * h * nc);
    Ok(Img { w, h, nc, data: buf })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn noisy(w: usize, h: usize, nc: usize) -> Img {
        let mut s = 12345u32;
        let mut img = Img::new(w, h, nc);
        for (i, v) in img.data.iter_mut().enumerate() {
            s = s.wrapping_mul(1103515245).wrapping_add(12345);
            *v = ((i / nc % w) as u32 * 3 + (s >> 24)) as u8;
        }
        img
    }

    #[test]
    fn orient_round_trips() {
        let img = noisy(7, 5, 3);
        // 6 (rotate 90) then 8 (rotate 270) is the identity.
        let back = orient(&orient(&img, 6), 8);
        assert_eq!(back.data, img.data);
        assert_eq!((orient(&img, 6).w, orient(&img, 6).h), (5, 7));
        // 2 twice (flip horizontal) is the identity.
        assert_eq!(orient(&orient(&img, 2), 2).data, img.data);
    }

    #[test]
    fn right_angle_rotation_matches_orientation() {
        let img = noisy(9, 4, 4);
        assert_eq!(rotate(&img, 90.0, 0).data, orient(&img, 6).data);
        assert_eq!(rotate(&img, -90.0, 0).data, orient(&img, 8).data);
        assert_eq!(rotate(&img, 180.0, 0).data, orient(&img, 3).data);
        let mut f = Img { data: img.data.clone(), ..img };
        flip(&mut f, 2);
        assert_eq!(f.data, orient(&img, 3).data);
    }

    #[test]
    fn resize_modes_keep_flat_colour() {
        let mut img = Img::new(40, 30, 3);
        for p in img.data.chunks_exact_mut(3) {
            p.copy_from_slice(&[10, 120, 250]);
        }
        for mode in [0, 1, 2, 3, 10, 11, 12, 13, 14] {
            let m = ResizeMode::from_i32(mode).unwrap();
            for (w, h) in [(13, 9), (80, 61)] {
                let r = resize(&img, 1, w, h, m);
                assert_eq!((r.w, r.h), (w, h));
                for p in r.data.chunks_exact(3) {
                    assert!(
                        p.iter().zip([10, 120, 250]).all(|(&a, b)| (a as i32 - b).abs() <= 1),
                        "mode {mode} {w}x{h}: {p:?}"
                    );
                }
            }
        }
    }

    #[test]
    fn blur_keeps_flat_colour_and_smooths_noise() {
        let mut flat = Img::new(20, 20, 3);
        flat.data.fill(77);
        gaussian_blur(&mut flat, 4);
        assert!(flat.data.iter().all(|&v| (76..=77).contains(&v)));
        let mut n = noisy(64, 64, 1);
        let before: u64 = n.data.windows(2).map(|w| (w[0] as i64 - w[1] as i64).unsigned_abs()).sum();
        gaussian_blur(&mut n, 3);
        let after: u64 = n.data.windows(2).map(|w| (w[0] as i64 - w[1] as i64).unsigned_abs()).sum();
        assert!(after * 3 < before);
    }

    #[test]
    fn adjust_identity_and_grey() {
        let img = noisy(16, 16, 3);
        let mut same = Img { data: img.data.clone(), ..img };
        adjust_color(&mut same, Adjust { amount: 1.0, ..Default::default() });
        assert_eq!(same.data, img.data);
        let mut grey = Img { data: img.data.clone(), ..img };
        adjust_color(&mut grey, Adjust { saturation: Some(0.0), amount: 1.0, ..Default::default() });
        for p in grey.data.chunks_exact(3) {
            assert!(p[0] == p[1] && p[1] == p[2]);
        }
    }

    #[test]
    fn jpeg_round_trip() {
        let img = noisy(33, 17, 3);
        let jpg = encode_jpeg(&img, 90, false, [255; 3], Some(b"Exif\0\0test"), None).unwrap();
        assert_eq!(&jpg[..2], &[0xFF, 0xD8]);
        let back = decode_jpeg(&jpg, 1).unwrap();
        assert_eq!((back.w, back.h, back.nc), (33, 17, 3));
        let back6 = decode_jpeg(&jpg, 6).unwrap();
        assert_eq!((back6.w, back6.h), (17, 33));
    }

    #[test]
    fn png_decode_rejects_palette() {
        // A 1x1 palette PNG.
        let mut out = Vec::new();
        {
            let mut e = png::Encoder::new(&mut out, 1, 1);
            e.set_color(png::ColorType::Indexed);
            e.set_palette(vec![1, 2, 3]);
            e.write_header().unwrap().write_image_data(&[0]).unwrap();
        }
        assert!(decode_png(&out).is_err());
    }
}
