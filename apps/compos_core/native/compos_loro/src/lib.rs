//! Loro document behind a NIF. See `docs/PROVENANCE-CRDT.md`.
//!
//! The document holds the buffer's history, its undo stacks, and its cursors.
//! The rope in `compos_rope` stays the working representation and the line
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

struct WeaveState {
    doc: LoroDoc,
    text: LoroText,
    undo: HashMap<String, UndoManager>,
    // an undo group is open: managers registered now must join it
    grouping: bool,
}

struct WeaveRes(Mutex<WeaveState>);

#[rustler::resource_impl]
impl rustler::Resource for WeaveRes {}

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

fn state(res: &ResourceArc<WeaveRes>) -> NifResult<std::sync::MutexGuard<'_, WeaveState>> {
    res.0.lock().map_err(|_| err("document lock poisoned"))
}

fn build(peer: u64) -> WeaveState {
    let doc = LoroDoc::new();
    doc.set_peer_id(peer).expect("set peer id on a fresh doc");
    // Loro merges adjacent changes from one peer within a second, and every
    // local actor shares this replica's peer id. Merging is safe anyway,
    // because Loro keeps changes with different commit messages apart, and two
    // changes with the same message are the same actor doing the same work.
    // Measured both ways: `set_change_merge_interval(0)` changes no behaviour
    // here and only adds change headers, so the default stands.
    let text = doc.get_text("text");
    WeaveState {
        doc,
        text,
        undo: HashMap::new(),
        grouping: false,
    }
}

// ---------------------------------------------------------------- lifecycle

#[rustler::nif]
fn history_new(peer: u64) -> ResourceArc<WeaveRes> {
    ResourceArc::new(WeaveRes(Mutex::new(build(peer))))
}

/// Open a document from exported bytes. The peer id is the local replica's,
/// not the one that wrote the snapshot.
#[rustler::nif(schedule = "DirtyCpu")]
fn history_open(peer: u64, snapshot: Binary) -> NifResult<ResourceArc<WeaveRes>> {
    let st = build(peer);
    st.doc.import(snapshot.as_slice()).map_err(err)?;
    // set_peer_id again: import can carry a peer id from the snapshot.
    st.doc.set_peer_id(peer).map_err(err)?;
    Ok(ResourceArc::new(WeaveRes(Mutex::new(st))))
}

/// Register an actor that can undo. Call this before the actor's first edit;
/// a manager only records what happens after it exists.
///
/// `exclude` lists origin prefixes this actor must not undo. The `undo` origin
/// is always excluded, so one actor's undo never enters another's stack.
#[rustler::nif]
fn history_register_actor(
    res: ResourceArc<WeaveRes>,
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
    // One commit is one undo step, so the buffer's commit boundaries already
    // decide what undoes together. Time must not group anything on top.
    m.set_merge_interval(0);
    m.add_exclude_origin_prefix(UNDO_ORIGIN);
    for prefix in &exclude {
        m.add_exclude_origin_prefix(prefix);
    }
    // an actor is registered lazily, on its first operation — which may be
    // inside an open group; the late manager joins it
    if st.grouping {
        let _ = m.group_start();
    }
    st.undo.insert(actor, m);
    Ok(atoms::ok())
}

/// Take a new peer identity for the operations from here on. The seed a file
/// buffer starts with is written as a peer both replicas agree on, so the two
/// seeds are the same operations rather than rival ones; after that each
/// replica writes as itself.
#[rustler::nif]
fn history_set_peer(res: ResourceArc<WeaveRes>, peer: u64) -> NifResult<Atom> {
    let st = state(&res)?;
    st.doc.commit();
    st.doc.set_peer_id(peer).map_err(err)?;
    Ok(atoms::ok())
}

#[rustler::nif]
fn history_has_actor(res: ResourceArc<WeaveRes>, actor: String) -> NifResult<bool> {
    Ok(state(&res)?.undo.contains_key(&actor))
}

// ----------------------------------------------------------------- mutation

#[rustler::nif]
fn history_insert(res: ResourceArc<WeaveRes>, pos: usize, text: Binary) -> NifResult<usize> {
    let st = state(&res)?;
    st.text.insert_utf8(pos, str_of(&text)?).map_err(err)?;
    Ok(st.text.len_utf8())
}

#[rustler::nif]
fn history_delete(res: ResourceArc<WeaveRes>, pos: usize, len: usize) -> NifResult<usize> {
    let st = state(&res)?;
    st.text.delete_utf8(pos, len).map_err(err)?;
    Ok(st.text.len_utf8())
}

/// Replace the whole text with `text`, emitting the minimal operations. This
/// is the wholesale-swap path: desktop restore, and any other caller that
/// knows the result but not the edit.
#[rustler::nif(schedule = "DirtyCpu")]
fn history_update(res: ResourceArc<WeaveRes>, text: Binary, by_line: bool) -> NifResult<usize> {
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
fn history_commit(
    res: ResourceArc<WeaveRes>,
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
fn history_text(env: Env, res: ResourceArc<WeaveRes>) -> NifResult<Binary> {
    let st = state(&res)?;
    Ok(bin(env, st.text.to_string().as_bytes()))
}

#[rustler::nif]
fn history_len(res: ResourceArc<WeaveRes>) -> NifResult<usize> {
    Ok(state(&res)?.text.len_utf8())
}

// --------------------------------------------------------------------- undo

#[rustler::nif]
fn history_undo(res: ResourceArc<WeaveRes>, actor: String) -> NifResult<bool> {
    let mut st = state(&res)?;
    let m = st
        .undo
        .get_mut(&actor)
        .ok_or_else(|| err(format!("no undo manager for actor {actor}")))?;
    m.undo().map_err(err)
}

#[rustler::nif]
fn history_redo(res: ResourceArc<WeaveRes>, actor: String) -> NifResult<bool> {
    let mut st = state(&res)?;
    let m = st
        .undo
        .get_mut(&actor)
        .ok_or_else(|| err(format!("no undo manager for actor {actor}")))?;
    m.redo().map_err(err)
}

/// Open or close an undo group on every registered manager. While a group is
/// open, each manager merges the changes it records into one undo step. A
/// manager that is not ready, or already grouping, keeps its current state.
#[rustler::nif]
fn history_group(res: ResourceArc<WeaveRes>, on: bool) -> NifResult<Atom> {
    let mut st = state(&res)?;
    st.grouping = on;
    for m in st.undo.values_mut() {
        if on {
            let _ = m.group_start();
        } else {
            m.group_end();
        }
    }
    Ok(atoms::ok())
}

#[rustler::nif]
fn history_undo_count(res: ResourceArc<WeaveRes>, actor: String) -> NifResult<(usize, usize)> {
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
fn history_cursor(env: Env, res: ResourceArc<WeaveRes>, pos: usize) -> NifResult<Option<Binary>> {
    let st = state(&res)?;
    Ok(st
        .text
        .get_cursor(pos, Default::default())
        .map(|c| bin(env, &c.encode())))
}

#[rustler::nif]
fn history_cursor_pos(res: ResourceArc<WeaveRes>, cursor: Binary) -> NifResult<usize> {
    let st = state(&res)?;
    let c = loro::cursor::Cursor::decode(cursor.as_slice()).map_err(err)?;
    Ok(st.doc.get_cursor_pos(&c).map_err(err)?.current.pos)
}

// -------------------------------------------------------- export and import

#[rustler::nif]
fn history_version(env: Env, res: ResourceArc<WeaveRes>) -> NifResult<Binary> {
    let st = state(&res)?;
    Ok(bin(env, &st.doc.oplog_vv().encode()))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn history_export_snapshot(env: Env, res: ResourceArc<WeaveRes>) -> NifResult<Binary> {
    let st = state(&res)?;
    let bytes = st.doc.export(ExportMode::Snapshot).map_err(err)?;
    Ok(bin(env, &bytes))
}

/// Updates since `from`, an encoded version from `history_version`. These bytes go
/// to disk and to a peer without change.
#[rustler::nif(schedule = "DirtyCpu")]
fn history_export_updates<'a>(
    env: Env<'a>,
    res: ResourceArc<WeaveRes>,
    from: Binary,
) -> NifResult<Binary<'a>> {
    let st = state(&res)?;
    let vv = VersionVector::decode(from.as_slice()).map_err(err)?;
    let bytes = st.doc.export(ExportMode::updates(&vv)).map_err(err)?;
    Ok(bin(env, &bytes))
}

/// Everything this history holds, as updates rather than a snapshot. What a
/// log file starts with when nothing has been written for this buffer yet.
#[rustler::nif(schedule = "DirtyCpu")]
fn history_export_all(env: Env, res: ResourceArc<WeaveRes>) -> NifResult<Binary> {
    let st = state(&res)?;
    let bytes = st.doc.export(ExportMode::all_updates()).map_err(err)?;
    Ok(bin(env, &bytes))
}

/// Import bytes another replica wrote. Returns the new byte length, because
/// the caller must rebuild its rope from the result.
#[rustler::nif(schedule = "DirtyCpu")]
fn history_import(res: ResourceArc<WeaveRes>, bytes: Binary) -> NifResult<usize> {
    let st = state(&res)?;
    st.doc.import(bytes.as_slice()).map_err(err)?;
    Ok(st.text.len_utf8())
}

// ------------------------------------------------------------------ history

/// One tuple per change: peer, counter, lamport, unix timestamp, message.
/// The message carries the actor, so this is the attribution record.
#[rustler::nif(schedule = "DirtyCpu")]
fn history_changes(res: ResourceArc<WeaveRes>) -> NifResult<Vec<Change>> {
    let st = state(&res)?;
    let json = st
        .doc
        .export_json_updates_without_peer_compression(&Default::default(), &st.doc.oplog_vv());

    Ok(json
        .changes
        .into_iter()
        .map(|c| Change {
            peer: c.id.peer,
            counter: c.id.counter,
            lamport: c.lamport,
            timestamp: c.timestamp,
            message: c.msg.map(|m| m.to_string()).unwrap_or_default(),
            deps: c.deps.iter().map(|d| (d.peer, d.counter)).collect(),
            ops: c.ops.iter().filter_map(text_op).collect(),
        })
        .collect())
}

/// One change, as the buffer log reads it.
#[derive(rustler::NifStruct)]
#[module = "Compos.Core.BufferHistory.Change"]
struct Change {
    peer: u64,
    counter: i32,
    lamport: u32,
    timestamp: i64,
    message: String,
    deps: Vec<(u64, i32)>,
    ops: Vec<Op>,
}

/// A delete carries a position and a length, never the text it removed. The
/// text is still in the history, but reading it back means checking out the
/// version before the delete, which the log does not do per row.
#[derive(rustler::NifStruct)]
#[module = "Compos.Core.BufferHistory.Op"]
struct Op {
    kind: String,
    pos: i64,
    inserted: String,
    deleted: i64,
}

fn text_op(op: &loro::JsonOp) -> Option<Op> {
    match &op.content {
        loro::JsonOpContent::Text(loro::JsonTextOp::Insert { pos, text }) => Some(Op {
            kind: "insert".into(),
            pos: *pos as i64,
            inserted: text.clone(),
            deleted: 0,
        }),
        loro::JsonOpContent::Text(loro::JsonTextOp::Delete { pos, len, .. }) => Some(Op {
            kind: "delete".into(),
            pos: *pos as i64,
            inserted: String::new(),
            deleted: *len as i64,
        }),
        _ => None,
    }
}

rustler::init!("Elixir.Compos.Core.BufferHistoryNif");
