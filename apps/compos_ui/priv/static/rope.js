// The browser's rope: ropey compiled to wasm (native/compos_rope_wasm).
//
// ComposRope.load(src) resolves to a Rope class. SRC is a URL in the
// browser, or the wasm bytes in node. Offsets are UTF-8 byte offsets,
// as in the daemon's rope. Each Rope owns wasm memory: call free().
(function (root) {
  const enc = new TextEncoder();
  const dec = new TextDecoder();

  async function instantiate(src) {
    if (typeof src !== "string") return (await WebAssembly.instantiate(src, {})).instance;
    const res = fetch(src);
    if (WebAssembly.instantiateStreaming) {
      try { return (await WebAssembly.instantiateStreaming(res, {})).instance; }
      catch (_) { /* a server without application/wasm: read the bytes */ }
    }
    const bytes = await (await fetch(src)).arrayBuffer();
    return (await WebAssembly.instantiate(bytes, {})).instance;
  }

  async function load(src) {
    const w = (await instantiate(src)).exports;

    // write S into a fresh wasm buffer; the caller frees it
    const put = (s) => {
      const b = enc.encode(s);
      const p = w.buf_alloc(b.length);
      if (b.length) new Uint8Array(w.memory.buffer, p, b.length).set(b);
      return [p, b.length];
    };

    class Rope {
      constructor(h) { this.h = h; }
      static from(text) {
        const [p, n] = put(text);
        const h = w.rope_new(p, n);
        w.buf_free(p, n);
        return new Rope(h);
      }
      clone() { return new Rope(w.rope_clone(this.h)); }
      free() { if (this.h) { w.rope_free(this.h); this.h = 0; } }
      get length() { return w.rope_len_bytes(this.h); }
      get lines() { return w.rope_len_lines(this.h); }
      insert(byte, text) {
        const [p, n] = put(text);
        w.rope_insert(this.h, byte, p, n);
        w.buf_free(p, n);
      }
      remove(from, to) { w.rope_remove(this.h, from, to); }
      // the byte length of the char that ends at BYTE; 0 at the start
      prevCharLen(byte) { return w.rope_prev_char_len(this.h, byte); }
      byteToLine(byte) { return w.rope_byte_to_line(this.h, byte); }
      lineToByte(line) { return w.rope_line_to_byte(this.h, line); }
      slice(from, to) {
        const n = Math.max(0, to - from);
        if (!n) return "";
        const p = w.buf_alloc(n);
        const got = w.rope_slice_into(this.h, from, to, p);
        const s = dec.decode(new Uint8Array(w.memory.buffer, p, got));
        w.buf_free(p, n);
        return s;
      }
      // the text of the 0-based LINE, without its newline
      line(l) {
        const s = this.lineToByte(l), e = this.lineToByte(l + 1);
        const t = this.slice(s, e);
        return t.endsWith("\n") ? t.slice(0, -1) : t;
      }
      toString() { return this.slice(0, this.length); }
    }
    return Rope;
  }

  const api = { load };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.ComposRope = api;
})(typeof window !== "undefined" ? window : globalThis);
