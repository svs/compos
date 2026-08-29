//! Rope NIF: ropey (the rope under Helix) behind Compos.Core.Rope.
//!
//! Byte offsets at the boundary — matching Buffer and tree-sitter. Ropey
//! indexes by chars internally, so offsets convert on entry; a byte offset
//! inside a multi-byte char floors to that char's start (the old
//! binary-split rope would happily corrupt UTF-8 there).
//!
//! Ropes are immutable values on the Elixir side: every edit clones the
//! handle (O(1), structure shared) and mutates the clone, so undo history
//! keeps cheap snapshots exactly as before.

use ropey::Rope;
use rustler::ResourceArc;

struct RopeRes(Rope);

#[rustler::resource_impl]
impl rustler::Resource for RopeRes {}

#[rustler::nif(schedule = "DirtyCpu")]
fn rope_new(text: String) -> ResourceArc<RopeRes> {
    ResourceArc::new(RopeRes(Rope::from_str(&text)))
}

#[rustler::nif]
fn rope_len_bytes(r: ResourceArc<RopeRes>) -> usize {
    r.0.len_bytes()
}

/// Flatten to a binary — O(n), callers cache per version.
#[rustler::nif(schedule = "DirtyCpu")]
fn rope_to_binary(r: ResourceArc<RopeRes>) -> String {
    String::from(&r.0)
}

#[rustler::nif]
fn rope_insert(r: ResourceArc<RopeRes>, byte_pos: usize, text: String) -> ResourceArc<RopeRes> {
    let mut rope = r.0.clone();
    let ch = rope.byte_to_char(byte_pos);
    rope.insert(ch, &text);
    ResourceArc::new(RopeRes(rope))
}

#[rustler::nif]
fn rope_delete(r: ResourceArc<RopeRes>, byte_pos: usize, byte_len: usize) -> ResourceArc<RopeRes> {
    let mut rope = r.0.clone();
    let s = rope.byte_to_char(byte_pos);
    let e = rope.byte_to_char(byte_pos + byte_len);
    rope.remove(s..e);
    ResourceArc::new(RopeRes(rope))
}

#[rustler::nif]
fn rope_slice(r: ResourceArc<RopeRes>, byte_pos: usize, byte_len: usize) -> String {
    let s = r.0.byte_to_char(byte_pos);
    let e = r.0.byte_to_char(byte_pos + byte_len);
    r.0.slice(s..e).to_string()
}

/// Total lines, counting the (possibly empty) line after a trailing \n —
/// i.e. newline count + 1, Emacs semantics.
#[rustler::nif]
fn rope_line_count(r: ResourceArc<RopeRes>) -> usize {
    r.0.len_lines()
}

/// 0-based line index containing the byte offset. O(log n).
#[rustler::nif]
fn rope_byte_to_line(r: ResourceArc<RopeRes>, byte_pos: usize) -> usize {
    r.0.byte_to_line(byte_pos)
}

/// Byte offset of the start of a 0-based line. line == line_count is the
/// one-past-the-end offset. O(log n).
#[rustler::nif]
fn rope_line_to_byte(r: ResourceArc<RopeRes>, line: usize) -> usize {
    r.0.line_to_byte(line)
}

rustler::init!("Elixir.Compos.Core.RopeNif");
