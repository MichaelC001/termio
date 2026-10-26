//! The PNG decoder for Kitty graphics (`f=100`).
//!
//! libghostty-vt decodes no PNG itself; it calls a process-wide hook. The
//! decoded size decides how many cells the image covers and so where the
//! cursor lands after it, so a `vt_stream` client must accept the same PNGs
//! with the same sizes, or its screen drifts from this one. The Mac client's
//! decoder (`TermiodStreamTerminal.decodePNG`) keeps the same two rules: the
//! size comes from the image header, and an image larger than
//! [`DECODED_LIMIT`] is refused before it is decoded.
//!
//! The hook is installed through the raw `ghostty_sys_set`, not
//! `kitty::graphics::set_png_decoder`. That wrapper dispatches through a
//! thread-local, so a terminal written on any thread but the installing one
//! would see no decoder and refuse every PNG.

use std::io::Cursor;
use std::sync::Once;

use libghostty_vt::ffi;
use png::{ColorType, Decoder, Limits, Transformations};

/// The largest decoded image accepted, in RGBA bytes: the engine's default
/// Kitty storage limit, so no image this refuses would have fitted anyway.
pub const DECODED_LIMIT: usize = 10_000_000;

static INSTALL: Once = Once::new();

pub(crate) fn install() {
    INSTALL.call_once(|| {
        let hook: ffi::SysDecodePngFn = Some(decode);
        let pointer = hook.map_or(std::ptr::null(), |function| function as *const std::ffi::c_void);
        // SAFETY: the option takes a function pointer with this signature.
        let result = unsafe { ffi::ghostty_sys_set(ffi::SysOption::GHOSTTY_SYS_OPT_DECODE_PNG, pointer) };
        if result != ffi::Result::SUCCESS {
            eprintln!("termiod-vt: PNG decoder not installed ({result})");
        }
    });
}

/// RGBA pixels and the size from the image header.
pub(crate) fn rgba(data: &[u8]) -> Option<(u32, u32, Vec<u8>)> {
    let mut decoder = Decoder::new_with_limits(Cursor::new(data), Limits { bytes: DECODED_LIMIT * 2 });
    decoder.set_transformations(Transformations::normalize_to_color8());
    let mut reader = decoder.read_info().ok()?;
    let (width, height) = (reader.info().width, reader.info().height);
    let pixels = (width as usize).checked_mul(height as usize)?;
    if pixels.checked_mul(4)? > DECODED_LIMIT {
        return None;
    }
    let mut buffer = vec![0; reader.output_buffer_size()?];
    let frame = reader.next_frame(&mut buffer).ok()?;
    if (frame.width, frame.height) != (width, height) {
        return None;
    }
    let channels = match frame.color_type {
        ColorType::Grayscale => 1,
        ColorType::GrayscaleAlpha => 2,
        ColorType::Rgb => 3,
        ColorType::Rgba => 4,
        ColorType::Indexed => return None,
    };
    let mut rgba = Vec::with_capacity(pixels * 4);
    for pixel in buffer[..frame.buffer_size()].chunks_exact(channels) {
        match *pixel {
            [gray] => rgba.extend_from_slice(&[gray, gray, gray, 255]),
            [gray, alpha] => rgba.extend_from_slice(&[gray, gray, gray, alpha]),
            [red, green, blue] => rgba.extend_from_slice(&[red, green, blue, 255]),
            [red, green, blue, alpha] => rgba.extend_from_slice(&[red, green, blue, alpha]),
            _ => return None,
        }
    }
    // Up to IEND: a PNG cut short after its pixels is refused, as the Mac's
    // decoder refuses it.
    reader.finish().ok()?;
    (rgba.len() == pixels * 4).then_some((width, height, rgba))
}

unsafe extern "C" fn decode(
    _userdata: *mut std::ffi::c_void,
    allocator: *const ffi::Allocator,
    data: *const u8,
    data_len: usize,
    out: *mut ffi::SysImage,
) -> bool {
    if data.is_null() || out.is_null() {
        return false;
    }
    // SAFETY: the engine passes `data_len` readable bytes at `data`.
    let data = unsafe { std::slice::from_raw_parts(data, data_len) };
    let Some((width, height, rgba)) = rgba(data) else {
        return false;
    };
    // SAFETY: the engine owns this buffer once we return true, and frees it
    // with the same allocator.
    let buffer = unsafe { ffi::ghostty_alloc(allocator, rgba.len()) };
    if buffer.is_null() {
        return false;
    }
    // SAFETY: `buffer` holds `rgba.len()` bytes and `out` is the engine's.
    unsafe {
        std::ptr::copy_nonoverlapping(rgba.as_ptr(), buffer, rgba.len());
        *out = ffi::SysImage {
            width,
            height,
            data: buffer,
            data_len: rgba.len(),
        };
    }
    true
}
