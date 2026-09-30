//! The browser's rope: ropey behind a C ABI for wasm32-unknown-unknown.
//!
//! The daemon's rope is ropey behind a NIF (compos_rope). This crate puts
//! the same rope in the browser, so the client can hold the buffer text,
//! apply a predicted edit, and map bytes to lines the way the daemon does.
//!
//! Offsets are UTF-8 byte offsets, as in compos_rope. A byte offset inside
//! a multi-byte char floors to the start of that char.
//!
//! A rope is a handle: a pointer to a boxed Rope. JavaScript owns each
//! handle and frees it with `rope_free`. Text crosses the boundary through
//! buffers that JavaScript gets from `buf_alloc` and returns to `buf_free`.

use ropey::Rope;
use std::alloc::{alloc, dealloc, Layout};

fn rope<'a>(h: *mut Rope) -> &'a mut Rope {
    unsafe { &mut *h }
}

fn text<'a>(ptr: *const u8, len: usize) -> &'a str {
    let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
    std::str::from_utf8(bytes).unwrap_or("")
}

fn char_at(r: &Rope, byte: usize) -> usize {
    r.byte_to_char(byte.min(r.len_bytes()))
}

/// A buffer of LEN bytes in wasm memory, for text in either direction.
#[no_mangle]
pub extern "C" fn buf_alloc(len: usize) -> *mut u8 {
    if len == 0 {
        return std::ptr::null_mut();
    }
    unsafe { alloc(Layout::from_size_align_unchecked(len, 1)) }
}

#[no_mangle]
pub extern "C" fn buf_free(ptr: *mut u8, len: usize) {
    if len > 0 && !ptr.is_null() {
        unsafe { dealloc(ptr, Layout::from_size_align_unchecked(len, 1)) }
    }
}

#[no_mangle]
pub extern "C" fn rope_new(ptr: *const u8, len: usize) -> *mut Rope {
    Box::into_raw(Box::new(Rope::from_str(text(ptr, len))))
}

/// A second handle on the same text. O(1): the two ropes share structure.
#[no_mangle]
pub extern "C" fn rope_clone(h: *mut Rope) -> *mut Rope {
    Box::into_raw(Box::new(rope(h).clone()))
}

#[no_mangle]
pub extern "C" fn rope_free(h: *mut Rope) {
    if !h.is_null() {
        drop(unsafe { Box::from_raw(h) });
    }
}

#[no_mangle]
pub extern "C" fn rope_len_bytes(h: *mut Rope) -> usize {
    rope(h).len_bytes()
}

/// The lines, counting the line after a final newline (Emacs semantics).
#[no_mangle]
pub extern "C" fn rope_len_lines(h: *mut Rope) -> usize {
    rope(h).len_lines()
}

#[no_mangle]
pub extern "C" fn rope_insert(h: *mut Rope, byte: usize, ptr: *const u8, len: usize) {
    let r = rope(h);
    let ch = char_at(r, byte);
    r.insert(ch, text(ptr, len));
}

/// Remove the bytes FROM..TO.
#[no_mangle]
pub extern "C" fn rope_remove(h: *mut Rope, from: usize, to: usize) {
    let r = rope(h);
    let (s, e) = (char_at(r, from), char_at(r, to));
    if s < e {
        r.remove(s..e);
    }
}

/// The byte length of the char that ends at BYTE, or 0 at the start.
#[no_mangle]
pub extern "C" fn rope_prev_char_len(h: *mut Rope, byte: usize) -> usize {
    let r = rope(h);
    let ch = char_at(r, byte);
    if ch == 0 {
        0
    } else {
        r.char(ch - 1).len_utf8()
    }
}

/// The 0-based line that holds BYTE.
#[no_mangle]
pub extern "C" fn rope_byte_to_line(h: *mut Rope, byte: usize) -> usize {
    let r = rope(h);
    r.byte_to_line(byte.min(r.len_bytes()))
}

/// The byte where the 0-based LINE starts. LINE = len_lines is the end.
#[no_mangle]
pub extern "C" fn rope_line_to_byte(h: *mut Rope, line: usize) -> usize {
    let r = rope(h);
    r.line_to_byte(line.min(r.len_lines()))
}

/// Copy the bytes FROM..TO into OUT, which holds TO - FROM bytes.
#[no_mangle]
pub extern "C" fn rope_slice_into(h: *mut Rope, from: usize, to: usize, out: *mut u8) -> usize {
    let r = rope(h);
    let (s, e) = (char_at(r, from), char_at(r, to));
    let mut n = 0;
    for chunk in r.slice(s..e).chunks() {
        let b = chunk.as_bytes();
        unsafe { std::ptr::copy_nonoverlapping(b.as_ptr(), out.add(n), b.len()) };
        n += b.len();
    }
    n
}
