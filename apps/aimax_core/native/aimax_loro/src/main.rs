//! Phase 0 measurement gate for `docs/PROVENANCE-CRDT.md`.
//!
//! Two questions. Does a Loro edit fit inside the keystroke budget, which the
//! current buffer meets at 0.007 ms? And does `add_exclude_origin_prefix` give
//! one actor an undo stack that skips another actor's edits?

use loro::{LoroDoc, UndoManager};
use std::time::Instant;

const BUDGET_US: f64 = 7.0;

fn seed(bytes: usize) -> String {
    let line = "fn example(a: usize) -> usize { a + 1 }\n";
    line.repeat(bytes / line.len() + 1)
}

fn doc_with(text: &str) -> (LoroDoc, loro::LoroText) {
    let doc = LoroDoc::new();
    doc.set_peer_id(1).unwrap();
    let t = doc.get_text("text");
    t.insert_utf8(0, text).unwrap();
    doc.commit();
    (doc, t)
}

/// Median of `n` timings, in microseconds. The median matters more than the
/// mean here: one slow allocation must not hide the ordinary keystroke cost.
fn median_us(mut samples: Vec<f64>) -> f64 {
    samples.sort_by(|a, b| a.partial_cmp(b).unwrap());
    samples[samples.len() / 2]
}

fn bench_insert(label: &str, size: usize, at_middle: bool) {
    let text = seed(size);
    let (doc, t) = doc_with(&text);
    let mut samples = Vec::new();

    for i in 0..2000 {
        let len = t.len_utf8();
        let pos = if at_middle { len / 2 } else { len };
        let start = Instant::now();
        t.insert_utf8(pos, "x").unwrap();
        samples.push(start.elapsed().as_nanos() as f64 / 1000.0);
        // Commit every 200 ops, matching @provenance_batch_limit.
        if i % 200 == 199 {
            doc.commit();
        }
    }
    doc.commit();

    let med = median_us(samples);
    let verdict = if med <= BUDGET_US { "ok" } else { "OVER" };
    println!(
        "  {:<28} {:>8.3} us   {:>4}   oplog {} B",
        label,
        med,
        verdict,
        doc.export(loro::ExportMode::all_updates()).unwrap().len()
    );
}

fn bench_rope_insert(label: &str, size: usize) {
    let text = seed(size);
    let mut rope = ropey::Rope::from_str(&text);
    let mut samples = Vec::new();
    for _ in 0..2000 {
        let at = rope.len_chars() / 2;
        let start = Instant::now();
        rope.insert(at, "x");
        samples.push(start.elapsed().as_nanos() as f64 / 1000.0);
    }
    println!("  {:<28} {:>8.3} us", label, median_us(samples));
}

fn bench_roundtrip(size: usize) {
    let text = seed(size);
    let (doc, t) = doc_with(&text);

    let from = doc.oplog_vv();
    for i in 0..200 {
        t.insert_utf8(i, "y").unwrap();
    }
    doc.commit();

    let start = Instant::now();
    let updates = doc.export(loro::ExportMode::updates(&from)).unwrap();
    let export_us = start.elapsed().as_nanos() as f64 / 1000.0;

    let peer = LoroDoc::new();
    peer.set_peer_id(2).unwrap();
    peer.get_text("text").insert_utf8(0, &text).unwrap();
    peer.commit();

    let start = Instant::now();
    peer.import(&updates).unwrap();
    let import_us = start.elapsed().as_nanos() as f64 / 1000.0;

    let start = Instant::now();
    let materialized = t.to_string();
    let to_string_us = start.elapsed().as_nanos() as f64 / 1000.0;

    let start = Instant::now();
    let cursor = t.get_cursor(size / 2, Default::default()).unwrap();
    let pos = doc.get_cursor_pos(&cursor).unwrap().current.pos;
    let cursor_us = start.elapsed().as_nanos() as f64 / 1000.0;

    println!("\n  {} KB document, 200 ops exchanged", size / 1024);
    println!("    export updates       {:>9.1} us   {} B", export_us, updates.len());
    println!("    import updates       {:>9.1} us", import_us);
    println!("    to_string            {:>9.1} us   {} B", to_string_us, materialized.len());
    println!("    cursor resolve       {:>9.3} us   pos {}", cursor_us, pos);
    println!(
        "    snapshot             {:>9} B",
        doc.export(loro::ExportMode::Snapshot).unwrap().len()
    );
}

/// The load-bearing assumption: the human's undo must skip the agent's edits.
fn probe_per_actor_undo() {
    let doc = LoroDoc::new();
    doc.set_peer_id(1).unwrap();
    let t = doc.get_text("text");

    let mut human = UndoManager::new(&doc);
    human.add_exclude_origin_prefix("agent");

    doc.set_next_commit_origin("user");
    t.insert_utf8(0, "HUMAN").unwrap();
    doc.commit();

    doc.set_next_commit_origin("agent:codex");
    t.insert_utf8(5, "AGENT").unwrap();
    doc.commit();

    let before = t.to_string();
    let undone = human.undo().unwrap();
    let after = t.to_string();

    println!("\n  per-actor undo");
    println!("    before undo          {:?}", before);
    println!("    undo returned        {}", undone);
    println!("    after human undo     {:?}", after);
    println!("    human undo_count     {}", human.undo_count());

    if after == "AGENT" {
        println!("    VERDICT              ok: human undo skipped the agent edit");
    } else if after == "HUMAN" {
        println!("    VERDICT              FAIL: human undo reverted the agent edit");
    } else {
        println!("    VERDICT              FAIL: unexpected text");
    }
}

/// A second actor must not be able to undo the first actor's work either.
fn probe_agent_undo_isolation() {
    let doc = LoroDoc::new();
    doc.set_peer_id(1).unwrap();
    let t = doc.get_text("text");

    let mut human = UndoManager::new(&doc);
    human.add_exclude_origin_prefix("agent");
    human.add_exclude_origin_prefix("undo");
    let mut agent = UndoManager::new(&doc);
    agent.add_exclude_origin_prefix("user");
    agent.add_exclude_origin_prefix("undo");

    doc.set_next_commit_origin("user");
    t.insert_utf8(0, "AAA").unwrap();
    doc.commit();

    doc.set_next_commit_origin("agent:codex");
    t.insert_utf8(3, "BBB").unwrap();
    doc.commit();

    doc.set_next_commit_origin("user");
    t.insert_utf8(6, "CCC").unwrap();
    doc.commit();

    println!("\n  two managers over one document");
    println!("    text                 {:?}", t.to_string());
    println!("    human can_undo {} count {}", human.can_undo(), human.undo_count());
    println!("    agent can_undo {} count {}", agent.can_undo(), agent.undo_count());

    agent.undo().unwrap();
    println!(
        "    after agent undo     {:?}   human count {}",
        t.to_string(),
        human.undo_count()
    );
    human.undo().unwrap();
    let after = t.to_string();
    println!("    after human undo     {:?}", after);

    if after == "AAA" {
        println!("    VERDICT              ok: each actor undid only its own work");
    } else {
        println!("    VERDICT              FAIL: expected \"AAA\"");
    }
}

/// Is the actor durable? `origin` is an event-time label. `commit_msg` is a
/// field of `Change`. Only one of them survives a reload.
fn probe_durable_actor() {
    let doc = LoroDoc::new();
    doc.set_peer_id(7).unwrap();
    let t = doc.get_text("text");

    doc.set_next_commit_origin("user");
    doc.set_next_commit_message("user:local|insert");
    t.insert_utf8(0, "AAA").unwrap();
    doc.commit();

    doc.set_next_commit_origin("agent:codex");
    doc.set_next_commit_message("agent:codex|run-42|apply patch");
    t.insert_utf8(3, "BBB").unwrap();
    doc.commit();

    // Round trip through the wire format, as a reload would.
    let bytes = doc.export(loro::ExportMode::Snapshot).unwrap();
    let reloaded = LoroDoc::new();
    reloaded.import(&bytes).unwrap();

    println!("\n  actor durability across a reload");
    println!("    text                 {:?}", reloaded.get_text("text").to_string());
    let json = reloaded.export_json_updates_without_peer_compression(
        &Default::default(),
        &reloaded.oplog_vv(),
    );
    for change in json.changes {
        println!(
            "    peer {} counter {} msg {:?}",
            change.id.peer, change.id.counter, change.msg
        );
    }
}

fn main() {
    println!("Loro Phase 0 gate. Keystroke budget is {} us.\n", BUDGET_US);

    println!("  loro insert_utf8, one character");
    bench_insert("empty document, append", 0, false);
    bench_insert("343 KB, append", 343 * 1024, false);
    bench_insert("343 KB, middle", 343 * 1024, true);
    bench_insert("3 MB, middle", 3 * 1024 * 1024, true);

    println!("\n  ropey insert, for comparison");
    bench_rope_insert("343 KB, middle", 343 * 1024);
    bench_rope_insert("3 MB, middle", 3 * 1024 * 1024);

    bench_roundtrip(343 * 1024);

    probe_per_actor_undo();
    probe_agent_undo_isolation();
    probe_durable_actor();
}
