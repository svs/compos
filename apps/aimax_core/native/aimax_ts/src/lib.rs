//! Tree-sitter NIF: the structural sensor (aimax axiom #1).
//! Two layers: stateless per-call parses (nav, arbitrary queries) and a
//! stateful parser resource for fontification — the tree survives across
//! edits, so a keystroke reparses only what changed.

use rustler::ResourceArc;
use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use streaming_iterator::StreamingIterator;
use tree_sitter::{InputEdit, Language, Node, Parser, Point, Query, QueryCursor};

/// Grammars loaded at runtime (ts_load_grammar): name -> (language, query).
/// The dlopen'd libraries are intentionally leaked — the Language fn
/// pointers must outlive every tree ever parsed with them.
fn dynamic() -> &'static Mutex<HashMap<String, (Language, String)>> {
    static DYNAMIC: OnceLock<Mutex<HashMap<String, (Language, String)>>> = OnceLock::new();
    DYNAMIC.get_or_init(|| Mutex::new(HashMap::new()))
}

fn language(name: &str) -> Option<Language> {
    match name {
        "elixir" => Some(tree_sitter_elixir::LANGUAGE.into()),
        "json" => Some(tree_sitter_json::LANGUAGE.into()),
        "rust" => Some(tree_sitter_rust::LANGUAGE.into()),
        _ => dynamic().lock().unwrap().get(name).map(|(l, _)| l.clone()),
    }
}

fn highlights_query(name: &str) -> Option<String> {
    match name {
        "elixir" => Some(tree_sitter_elixir::HIGHLIGHTS_QUERY.to_string()),
        "json" => Some(tree_sitter_json::HIGHLIGHTS_QUERY.to_string()),
        "rust" => Some(tree_sitter_rust::HIGHLIGHTS_QUERY.to_string()),
        _ => dynamic().lock().unwrap().get(name).map(|(_, q)| q.clone()),
    }
}

/// Load a grammar shared library at runtime: dlopen, resolve
/// `tree_sitter_<name>`, sanity-check it against this tree-sitter and the
/// given highlight query, then register it for every other NIF. Returns
/// "ok" or an error message.
#[rustler::nif(schedule = "DirtyCpu")]
fn ts_load_grammar(name: String, lib_path: String, highlights: String) -> String {
    let symbol = format!("tree_sitter_{}", name.replace('-', "_"));

    let lang: Language = unsafe {
        let lib = match libloading::Library::new(&lib_path) {
            Ok(l) => l,
            Err(e) => return format!("error: open {lib_path}: {e}"),
        };
        let func: libloading::Symbol<unsafe extern "C" fn() -> *const ()> =
            match lib.get(symbol.as_bytes()) {
                Ok(f) => f,
                Err(e) => return format!("error: no symbol {symbol}: {e}"),
            };
        let lang_fn = tree_sitter_language::LanguageFn::from_raw(*func);
        // the library must never be unloaded — its code backs the Language
        std::mem::forget(lib);
        Language::new(lang_fn)
    };

    let mut parser = Parser::new();
    if let Err(e) = parser.set_language(&lang) {
        return format!("error: incompatible grammar ABI: {e}");
    }
    if let Err(e) = Query::new(&lang, &highlights) {
        return format!("error: bad highlights query: {e}");
    }

    dynamic().lock().unwrap().insert(name, (lang, highlights));
    "ok".into()
}

fn parse(lang: Language, text: &str) -> Option<tree_sitter::Tree> {
    let mut parser = Parser::new();
    parser.set_language(&lang).ok()?;
    parser.parse(text, None)
}

/// [{start, end, scope_head}] for the grammar's bundled highlight query.
#[rustler::nif(schedule = "DirtyCpu")]
fn ts_highlight(lang_name: String, text: String) -> Vec<(usize, usize, String)> {
    let mut out = Vec::new();
    let (Some(lang), Some(hq)) = (language(&lang_name), highlights_query(&lang_name)) else {
        return out;
    };
    let Some(tree) = parse(lang.clone(), &text) else {
        return out;
    };
    let Ok(query) = Query::new(&lang, &hq) else {
        return out;
    };
    let names = query.capture_names();
    let mut cursor = QueryCursor::new();
    let mut captures = cursor.captures(&query, tree.root_node(), text.as_bytes());
    while let Some((m, ix)) = captures.next() {
        let cap = m.captures[*ix];
        let scope = names[cap.index as usize]
            .split('.')
            .next()
            .unwrap_or("")
            .to_string();
        out.push((cap.node.start_byte(), cap.node.end_byte(), scope));
    }
    out
}

/// Structural navigation: forward/backward (sexp), up (enclosing), down (into).
/// Returns the target byte position, or None.
#[rustler::nif(schedule = "DirtyCpu")]
fn ts_nav(lang_name: String, text: String, pos: usize, op: String) -> Option<usize> {
    let lang = language(&lang_name)?;
    let tree = parse(lang, &text)?;
    let root = tree.root_node();
    let pos = pos.min(text.len());
    let node = root.named_descendant_for_byte_range(pos, pos)?;

    match op.as_str() {
        "forward" => {
            let mut n = node;
            loop {
                if n.start_byte() >= pos {
                    return Some(n.end_byte());
                }
                // between children of n: the next sexp is the first child
                // starting at/after pos
                let mut w = n.walk();
                if let Some(c) = n.named_children(&mut w).find(|c: &Node| c.start_byte() >= pos) {
                    return Some(c.end_byte());
                }
                if let Some(s) = n.next_named_sibling() {
                    return Some(s.end_byte());
                }
                n = n.parent()?;
            }
        }
        "backward" => {
            let mut n = node;
            loop {
                if n.end_byte() <= pos {
                    return Some(n.start_byte());
                }
                let mut w = n.walk();
                if let Some(c) = n
                    .named_children(&mut w)
                    .filter(|c: &Node| c.end_byte() <= pos)
                    .last()
                {
                    return Some(c.start_byte());
                }
                if let Some(s) = n.prev_named_sibling() {
                    return Some(s.start_byte());
                }
                n = n.parent()?;
            }
        }
        "up" => {
            let mut n = node;
            // find the smallest enclosing node that starts strictly before pos
            loop {
                if n.start_byte() < pos {
                    return Some(n.start_byte());
                }
                n = n.parent()?;
            }
        }
        "down" => {
            // first named child at/after pos, searching the covering node
            let mut n = node;
            loop {
                let mut walker = n.walk();
                let child = n.named_children(&mut walker).find(|c: &Node| {
                    c.start_byte() >= pos && c.named_child_count() > 0
                });
                match child {
                    Some(c) => return c.named_child(0).map(|g| g.start_byte()),
                    None => n = n.parent()?,
                }
            }
        }
        _ => None,
    }
}

/// Run an arbitrary query: [{capture_name, start, end}].
#[rustler::nif(schedule = "DirtyCpu")]
fn ts_query_nif(lang_name: String, text: String, query_src: String) -> Vec<(String, usize, usize)> {
    let mut out = Vec::new();
    let Some(lang) = language(&lang_name) else {
        return out;
    };
    let Some(tree) = parse(lang.clone(), &text) else {
        return out;
    };
    let Ok(query) = Query::new(&lang, &query_src) else {
        return out;
    };
    let names = query.capture_names();
    let mut cursor = QueryCursor::new();
    let mut captures = cursor.captures(&query, tree.root_node(), text.as_bytes());
    while let Some((m, ix)) = captures.next() {
        let cap = m.captures[*ix];
        out.push((
            names[cap.index as usize].to_string(),
            cap.node.start_byte(),
            cap.node.end_byte(),
        ));
    }
    out
}

#[rustler::nif]
fn ts_langs() -> Vec<String> {
    let mut langs: Vec<String> = vec!["elixir".into(), "json".into(), "rust".into()];
    langs.extend(dynamic().lock().unwrap().keys().cloned());
    langs.sort();
    langs
}

// --- stateful parsing (incremental fontification) ---------------------------

struct TsState {
    parser: Parser,
    query: Query,
    tree: Option<tree_sitter::Tree>,
}

struct TsRes(Mutex<TsState>);

#[rustler::resource_impl]
impl rustler::Resource for TsRes {}

/// A parser + compiled highlight query + (eventually) a tree, owned by one
/// buffer process. None for unknown languages.
#[rustler::nif]
fn ts_state_new(lang_name: String) -> Option<ResourceArc<TsRes>> {
    let lang = language(&lang_name)?;
    let hq = highlights_query(&lang_name)?;
    let mut parser = Parser::new();
    parser.set_language(&lang).ok()?;
    let query = Query::new(&lang, &hq).ok()?;
    Some(ResourceArc::new(TsRes(Mutex::new(TsState {
        parser,
        query,
        tree: None,
    }))))
}

/// Record an edit against the held tree so the next parse is incremental.
/// Byte offsets plus (row, byte-column) points, per tree-sitter's InputEdit.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn ts_state_edit(
    res: ResourceArc<TsRes>,
    start_byte: usize,
    old_end_byte: usize,
    new_end_byte: usize,
    start_row: usize,
    start_col: usize,
    old_end_row: usize,
    old_end_col: usize,
    new_end_row: usize,
    new_end_col: usize,
) {
    let mut st = res.0.lock().unwrap();
    if let Some(tree) = st.tree.as_mut() {
        tree.edit(&InputEdit {
            start_byte,
            old_end_byte,
            new_end_byte,
            start_position: Point::new(start_row, start_col),
            old_end_position: Point::new(old_end_row, old_end_col),
            new_end_position: Point::new(new_end_row, new_end_col),
        });
    }
}

/// Forget the tree (undo swaps content wholesale): next highlight reparses
/// from scratch.
#[rustler::nif]
fn ts_state_reset(res: ResourceArc<TsRes>) {
    res.0.lock().unwrap().tree = None;
}

/// Parse (incrementally when a tree is held) and return highlight spans —
/// same shape as the stateless ts_highlight.
#[rustler::nif(schedule = "DirtyCpu")]
fn ts_state_highlight(res: ResourceArc<TsRes>, text: String) -> Vec<(usize, usize, String)> {
    let mut guard = res.0.lock().unwrap();
    let st = &mut *guard;
    st.tree = st.parser.parse(&text, st.tree.as_ref());

    let mut out = Vec::new();
    let Some(tree) = st.tree.as_ref() else {
        return out;
    };
    let names = st.query.capture_names();
    let mut cursor = QueryCursor::new();
    let mut captures = cursor.captures(&st.query, tree.root_node(), text.as_bytes());
    while let Some((m, ix)) = captures.next() {
        let cap = m.captures[*ix];
        let scope = names[cap.index as usize]
            .split('.')
            .next()
            .unwrap_or("")
            .to_string();
        out.push((cap.node.start_byte(), cap.node.end_byte(), scope));
    }
    out
}

rustler::init!("Elixir.Aimax.Core.TS");
