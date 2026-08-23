//! Loro document behind a NIF. See `docs/PROVENANCE-CRDT.md`.
//!
//! The document holds the buffer's history, its undo stacks, and its cursors.
//! The rope in `aimax_rope` stays the working representation and the line
//! index, so nothing here is on the read path.
//!
//! Two rules from the Phase 0 gate, both load-bearing:
//!
//! - The actor goes in the commit message, because `Change` carries no origin
//!   field and the origin does not survive an export.
//! - Every undo manager excludes the `undo` origin, because an undo is itself a
//!   change. Without it one actor's undo lands on another actor's stack.

use loro::{ExportMode, LoroDoc, LoroText, UndoManager, VersionVector};
use rustler::{Atom, Binary, Env, Error, NifResult, OwnedBinary, ResourceArc};
use std::collections::HashMap;
use std::sync::Mutex;

mod atoms {
    rustler::atoms! { ok }
}

/// The undo origin Loro stamps on the changes an undo itself produces.
const UNDO_ORIGIN: &str = "undo";

struct DocState {
    doc: LoroDoc,
    text: LoroText,
    undo: HashMap<String, UndoManager>,
}

struct DocRes(Mutex<DocState>);

#[rustler::resource_impl]
impl rustler::Resource for DocRes {}

fn err(msg: impl std::fmt::Display) -> Error {
    Error::Term(Box::new(msg.to_string()))
}

fn bin<'a>(env: Env<'a>, data: &[u8]) -> Binary<'a> {
    let mut out = OwnedBinary::new(data.len()).expect("allocate binary");
    out.as_mut_slice().copy_from_slice(data);
    out.release(env)
}

fn str_of<'a>(b: &'a Binary) -> NifResult<&'a str> {
    std::str::from_utf8(b.as_slice()).map_err(err)
}

fn state(res: &ResourceArc<DocRes>) -> NifResult<std::sync::MutexGuard<'_, DocState>> {
    res.0.lock().map_err(|_| err("document lock poisoned"))
}

fn build(peer: u64) -> DocState {
    let doc = LoroDoc::new();
    doc.set_peer_id(peer).expect("set peer id on a fresh doc");
    let text = doc.get_text("text");
    DocState {
        doc,
        text,
        undo: HashMap::new(),
    }
}

// ---------------------------------------------------------------- lifecycle

#[rustler::nif]
fn doc_new(peer: u64) -> ResourceArc<DocRes> {
    ResourceArc::new(DocRes(Mutex::new(build(peer))))
}

/// Open a document from exported bytes. The peer id is the local replica's,
/// not the one that wrote the snapshot.
#[rustler::nif(schedule = "DirtyCpu")]
fn doc_open(peer: u64, snapshot: Binary) -> NifResult<ResourceArc<DocRes>> {
    let st = build(peer);
    st.doc.import(snapshot.as_slice()).map_err(err)?;
    // set_peer_id again: import can carry a peer id from the snapshot.
    st.doc.set_peer_id(peer).map_err(err)?;
    Ok(ResourceArc::new(DocRes(Mutex::new(st))))
}

/// Register an actor that can undo. Call this before the actor's first edit;
/// a manager only records what happens after it exists.
///
/// `exclude` lists origin prefixes this actor must not undo. The `undo` origin
/// is always excluded, so one actor's undo never enters another's stack.
#[rustler::nif]
fn doc_register_actor(
    res: ResourceArc<DocRes>,
    actor: String,
    exclude: Vec<String>,
    max_steps: usize,
) -> NifResult<Atom> {
    let mut st = state(&res)?;
    if st.undo.contains_key(&actor) {
        return Ok(atoms::ok());
    }
    let mut m = UndoManager::new(&st.doc);
    m.set_max_undo_steps(max_steps);
    m.add_exclude_origin_prefix(UNDO_ORIGIN);
    for prefix in &exclude {
        m.add_exclude_origin_prefix(prefix);
    }
    st.undo.insert(actor, m);
    Ok(atoms::ok())
}

// ----------------------------------------------------------------- mutation

#[rustler::nif]
fn doc_insert(res: ResourceArc<DocRes>, pos: usize, text: Binary) -> NifResult<usize> {
    let st = state(&res)?;
    st.text.insert_utf8(pos, str_of(&text)?).map_err(err)?;
    Ok(st.text.len_utf8())
}

#[rustler::nif]
fn doc_delete(res: ResourceArc<DocRes>, pos: usize, len: usize) -> NifResult<usize> {
    let st = state(&res)?;
    st.text.delete_utf8(pos, len).map_err(err)?;
    Ok(st.text.len_utf8())
}

/// Replace the whole text with `text`, emitting the minimal operations. This
/// is the wholesale-swap path: desktop restore, and any other caller that
/// knows the result but not the edit.
#[rustler::nif(schedule = "DirtyCpu")]
fn doc_update(res: ResourceArc<DocRes>, text: Binary, by_line: bool) -> NifResult<usize> {
    let st = state(&res)?;
    let s = str_of(&text)?;
    let opts = Default::default();
    if by_line {
        st.text.update_by_line(s, opts).map_err(err)?;
    } else {
        st.text.update(s, opts).map_err(err)?;
    }
    Ok(st.text.len_utf8())
}

/// Close the pending change. `msg` is durable and carries the actor; `origin`
/// is the live label the undo managers filter on.
#[rustler::nif]
fn doc_commit(
    res: ResourceArc<DocRes>,
    origin: String,
    msg: String,
    timestamp: i64,
) -> NifResult<Atom> {
    let st = state(&res)?;
    st.doc.set_next_commit_origin(&origin);
    st.doc.set_next_commit_message(&msg);
    st.doc.set_next_commit_timestamp(timestamp);
    st.doc.commit();
    Ok(atoms::ok())
}

// --------------------------------------------------------------------- read

#[rustler::nif(schedule = "DirtyCpu")]
fn doc_text(env: Env, res: ResourceArc<DocRes>) -> NifResult<Binary> {
    let st = state(&res)?;
    Ok(bin(env, st.text.to_string().as_bytes()))
}

#[rustler::nif]
fn doc_len(res: ResourceArc<DocRes>) -> NifResult<usize> {
    Ok(state(&res)?.text.len_utf8())
}

// --------------------------------------------------------------------- undo

#[rustler::nif]
fn doc_undo(res: ResourceArc<DocRes>, actor: String) -> NifResult<bool> {
    let mut st = state(&res)?;
    let m = st
        .undo
        .get_mut(&actor)
        .ok_or_else(|| err(format!("no undo manager for actor {actor}")))?;
    m.undo().map_err(err)
}

#[rustler::nif]
fn doc_redo(res: ResourceArc<DocRes>, actor: String) -> NifResult<bool> {
    let mut st = state(&res)?;
    let m = st
        .undo
        .get_mut(&actor)
        .ok_or_else(|| err(format!("no undo manager for actor {actor}")))?;
    m.redo().map_err(err)
}

#[rustler::nif]
fn doc_undo_count(res: ResourceArc<DocRes>, actor: String) -> NifResult<(usize, usize)> {
    let st = state(&res)?;
    let m = st
        .undo
        .get(&actor)
        .ok_or_else(|| err(format!("no undo manager for actor {actor}")))?;
    Ok((m.undo_count(), m.redo_count()))
}

// ------------------------------------------------------------------ cursors

/// A cursor over `pos` that survives concurrent edits. Encoded opaquely; the
/// caller stores the bytes and hands them back to resolve.
#[rustler::nif]
fn doc_cursor(env: Env, res: ResourceArc<DocRes>, pos: usize) -> NifResult<Option<Binary>> {
    let st = state(&res)?;
    Ok(st
        .text
        .get_cursor(pos, Default::default())
        .map(|c| bin(env, &c.encode())))
}

#[rustler::nif]
fn doc_cursor_pos(res: ResourceArc<DocRes>, cursor: Binary) -> NifResult<usize> {
    let st = state(&res)?;
    let c = loro::cursor::Cursor::decode(cursor.as_slice()).map_err(err)?;
    Ok(st.doc.get_cursor_pos(&c).map_err(err)?.current.pos)
}

// -------------------------------------------------------- export and import

#[rustler::nif]
fn doc_version(env: Env, res: ResourceArc<DocRes>) -> NifResult<Binary> {
    let st = state(&res)?;
    Ok(bin(env, &st.doc.oplog_vv().encode()))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn doc_export_snapshot(env: Env, res: ResourceArc<DocRes>) -> NifResult<Binary> {
    let st = state(&res)?;
    let bytes = st.doc.export(ExportMode::Snapshot).map_err(err)?;
    Ok(bin(env, &bytes))
}

/// Updates since `from`, an encoded version from `doc_version`. These bytes go
/// to disk and to a peer without change.
#[rustler::nif(schedule = "DirtyCpu")]
fn doc_export_updates<'a>(
    env: Env<'a>,
    res: ResourceArc<DocRes>,
    from: Binary,
) -> NifResult<Binary<'a>> {
    let st = state(&res)?;
    let vv = VersionVector::decode(from.as_slice()).map_err(err)?;
    let bytes = st.doc.export(ExportMode::updates(&vv)).map_err(err)?;
    Ok(bin(env, &bytes))
}

/// Import bytes another replica wrote. Returns the new byte length, because
/// the caller must rebuild its rope from the result.
#[rustler::nif(schedule = "DirtyCpu")]
fn doc_import(res: ResourceArc<DocRes>, bytes: Binary) -> NifResult<usize> {
    let st = state(&res)?;
    st.doc.import(bytes.as_slice()).map_err(err)?;
    Ok(st.text.len_utf8())
}

// ------------------------------------------------------------------ history

/// One tuple per change: peer, counter, lamport, unix timestamp, message.
/// The message carries the actor, so this is the attribution record.
#[rustler::nif(schedule = "DirtyCpu")]
fn doc_history(res: ResourceArc<DocRes>) -> NifResult<Vec<(u64, i32, u32, i64, String)>> {
    let st = state(&res)?;
    let json = st
        .doc
        .export_json_updates_without_peer_compression(&Default::default(), &st.doc.oplog_vv());
    Ok(json
        .changes
        .into_iter()
        .map(|c| {
            (
                c.id.peer,
                c.id.counter,
                c.lamport,
                c.timestamp,
                c.msg.map(|m| m.to_string()).unwrap_or_default(),
            )
        })
        .collect())
}

rustler::init!("Elixir.Aimax.Core.DocNif");
