//! Rust core of the rapid_image Dart package.
//!
//! * `png_encode`: PNG row filtering and compression (native only; it uses
//!   libdeflate's C code).
//! * `ops`: JPEG and PNG decoding, JPEG encoding, resizing, rotation, blur
//!   and colour adjustment, with a C API in `ops_ffi`. Built natively and
//!   for WebAssembly (wasm32-unknown-unknown), where the same exports are
//!   called from JavaScript.

pub mod ops;
mod ops_ffi;

#[cfg(not(target_arch = "wasm32"))]
mod png_encode;
#[cfg(not(target_arch = "wasm32"))]
pub use png_encode::*;
