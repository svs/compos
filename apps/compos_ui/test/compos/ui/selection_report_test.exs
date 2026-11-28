defmodule Compos.Ui.SelectionReportTest do
  use ExUnit.Case, async: true

  test "selection reports require a gesture and cannot outlive a patch or typing" do
    src = File.read!(Path.expand("../../../priv/static/app.js", __DIR__))
    [_, rest] = String.split(src, "this.selChangeH = () => {", parts: 2)
    [body, _] = String.split(rest, "document.addEventListener(\"selectionchange\"", parts: 2)
    script = """
    const assert = require('node:assert/strict');
    let timer;
    globalThis.setTimeout = f => { timer = f; return 1; };
    globalThis.clearTimeout = () => { timer = null; };
    globalThis.performance = {now: () => 200};
    const win = {classList: {contains: () => true}};
    const buf = {isConnected: true, dataset: {pt: '5'},
      closest: () => win, contains: () => true,
      hasAttribute: name => name === 'contenteditable'};
    globalThis.document = {activeElement: {closest: () => buf}};
    globalThis.window = {getSelection: () => ({isCollapsed: true, focusNode: {}, focusOffset: 2})};
    const domByte = () => 2;
    const markCurrentRow = () => {};
    let reports = 0;
    const hook = {_gestureAt: 100, _patchAt: 50, measureSelection: () => null, sendSelection: () => reports++};
    (function () { this.selChangeH = () => {#{body} }).call(hook);
    hook.selChangeH();
    assert.equal(hook._selPending, true);
    hook._patchAt = 150;
    timer();
    assert.equal(reports, 0, 'patch-induced caret must not be sent');
    hook._patchAt = 50;
    hook._gestureAt = 100;
    hook.selChangeH();
    hook._gestureAt = 0;
    timer();
    assert.equal(reports, 0, 'typing invalidates a delayed selection');
    timer = null;
    hook.selChangeH();
    assert.equal(timer, null, 'no selection report without a gesture');
    hook._gestureAt = 100;
    hook.selChangeH();
    timer();
    assert.equal(reports, 1, 'real caret motion still reports');
    """
    path = Path.join(System.tmp_dir!(), "compos-selection-#{System.unique_integer([:positive])}.js")
    File.write!(path, script)
    try do
      {output, status} = System.cmd("node", [path], stderr_to_stdout: true)
      assert status == 0, output
    after
      File.rm(path)
    end
  end
  test "native line motion crosses a slice edge but keeps wrapped rows native" do
    src = File.read!(Path.expand("../../../priv/static/app.js", __DIR__))
    [_, rest] = String.split(src, "this.moveEditable = (buf, alter, dir, granularity, count) => {", parts: 2)
    [body, _] = String.split(rest, "this.handleEvent(\"select\"", parts: 2)
    script = """
    const assert = require('node:assert/strict');
    const first = {}, last = {};
    let row = first, top = 100, byte = 20, next;
    const node = {nodeType: 1, closest: () => row};
    const sel = {focusNode: node, focusOffset: 0,
      modify: () => {row=next.row;top=next.top;byte=next.byte;}};
    globalThis.window = {getSelection: () => sel};
    globalThis.document = {createRange: () => ({setStart(){},collapse(){},getBoundingClientRect:()=>({top})})};
    const buf = {contains: () => true, classList: {contains: () => false},
      dataset: {v:'7'}, querySelectorAll: () => [first,last]};
    const domByte = () => byte;
    const winIdOf = () => 1;
    let events=[], selections=0;
    const hook={pushEvent:(name,p)=>events.push([name,p]),sendSelection:()=>selections++};
    (function(){this.moveEditable = (buf, alter, dir, granularity, count) => {#{body}}).call(hook);
    next={row:first,top:100,byte:0};
    hook.moveEditable(buf,'move','backward','line',1);
    assert.equal(events[0][0],'edge_motion');
    assert.equal(events[0][1].point,20);
    assert.equal(events[0][1].dir,-1);
    assert.equal(selections,0);
    events=[];row=first;top=120;byte=40;next={row:first,top:100,byte:20};
    hook.moveEditable(buf,'move','backward','line',1);
    assert.equal(events.length,0,'wrapped row above remains a native move');
    assert.equal(selections,1);
    row=last;top=200;byte=90;next={row:last,top:200,byte:100};
    hook.moveEditable(buf,'extend','forward','line',1);
    assert.equal(events[0][1].dir,1);
    assert.equal(events[0][1].point,90);
    assert.equal(events[0][1].extend,true);
    """
    path = Path.join(System.tmp_dir!(), "compos-edge-#{System.unique_integer([:positive])}.js")
    File.write!(path, script)
    try do
      {out, status} = System.cmd("node", [path], stderr_to_stdout: true)
      assert status == 0, out
    after
      File.rm(path)
    end
  end

end
