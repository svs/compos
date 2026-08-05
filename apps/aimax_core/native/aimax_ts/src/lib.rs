//! Tree-sitter NIF: the structural sensor (aimax axiom #1).
//! Stateless v1 — parse per call on dirty CPU schedulers. Incremental
//! trees-as-resources come with the display-list work.

use streaming_iterator::StreamingIterator;
use tree_sitter::{Language, Node, Parser, Query, QueryCursor};

fn language(name: &str) -> Option<Language> {
    match name {
        "elixir" => Some(tree_sitter_elixir::LANGUAGE.into()),
        "json" => Some(tree_sitter_json::LANGUAGE.into()),
        "rust" => Some(tree_sitter_rust::LANGUAGE.into()),
        _ => None,
    }
}

fn highlights_query(name: &str) -> Option<&'static str> {
    match name {
        "elixir" => Some(tree_sitter_elixir::HIGHLIGHTS_QUERY),
        "json" => Some(tree_sitter_json::HIGHLIGHTS_QUERY),
        "rust" => Some(tree_sitter_rust::HIGHLIGHTS_QUERY),
        _ => None,
    }
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
    let Ok(query) = Query::new(&lang, hq) else {
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
    vec!["elixir".into(), "json".into(), "rust".into()]
}

rustler::init!("Elixir.Aimax.Core.TS");
