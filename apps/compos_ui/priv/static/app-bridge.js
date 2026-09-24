(function(){
var t=null;
function el(){return document.scrollingElement||document.documentElement}
addEventListener("message",function(e){
  if(e.data&&e.data.compos==="scroll"){el().scrollTop=e.data.top}
});
addEventListener("scroll",function(){
  clearTimeout(t);
  t=setTimeout(function(){
    parent.postMessage({compos:"scroll",top:Math.round(el().scrollTop)},"*")
  },250)
},true);
addEventListener("keydown",function(e){
  if(e.ctrlKey&&!e.altKey&&!e.metaKey&&e.key.toLowerCase()==="g"){
    e.preventDefault();
    e.stopImmediatePropagation();
    parent.postMessage({compos:"release"},"*")
    return
  }
  // Cmd-arrows move the editor's focus between windows. Keys do not
  // cross the origin boundary, so they travel as a message.
  if(e.metaKey&&!e.ctrlKey&&/^Arrow/.test(e.key)){
    e.preventDefault();
    e.stopImmediatePropagation();
    parent.postMessage({compos:"key",key:e.key,code:e.code,shiftKey:e.shiftKey,altKey:e.altKey,metaKey:true,ctrlKey:false},"*")
  }
},true);
})()
