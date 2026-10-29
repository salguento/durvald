"use strict";
const params = new URLSearchParams(location.search), provider = params.get("provider"), item = params.get("item");
const started = performance.now(), checks = {ready:false, play:false, progress:false, pause:false, resume:false, seek:false};
let done = false, phase = "loading", player, lastPosition = null, lastAdvance = null, stalls = 0, stallActive = false;
let pausePosition = null, firstPosition = null, resumed = false, seekTarget = null;
function event(name, values={}) {
  const payload = {event:name,time:Math.round(performance.now()-started),phase,...values};
  document.querySelector("#events").textContent = JSON.stringify(payload);
  window.webkit.messageHandlers.probe.postMessage({...payload, checks});
}
function finish(reason) {
  if(done)return;done=true;clearInterval(poll);
  pause();event("complete", {stalls});
  window.webkit.messageHandlers.probe.postMessage({done:true,checks,reason,stalls});
}
function script(url, ready) { const s=document.createElement("script");s.src=url;if(ready)s.onload=ready;s.onerror=()=>finish("sdk_load_failed");document.head.append(s); }
function play() { provider==="youtube" ? player.playVideo() : player.play(); }
function pause() { if(player)provider==="youtube" ? player.pauseVideo() : player.pause(); }
function requestPlay() { event("play_requested");play(); }
function begin() { checks.ready=true;event("ready");requestPlay(); }
function observedPlay() { checks.play=true;event("playing"); }
function position(value, duration) {
  if(done || !Number.isFinite(value))return;
  const now=performance.now();
  if(phase==="loading" && checks.play) {
    if(firstPosition===null)firstPosition=value;
    if(value>firstPosition+0.1) {
      checks.progress=true;phase="playback";event("first_progress",{position:value,duration});
      setTimeout(()=>{if(!done && phase==="playback"){phase="pausing";pause();}},20000);
    }
  }
  if(phase==="playback" || phase==="resuming") {
    if(lastPosition===null || value>lastPosition+0.05) { lastAdvance=now;stallActive=false; }
    else if(lastAdvance!==null && now-lastAdvance>1000 && !stallActive) { stalls++;stallActive=true;event("stall_observed",{position:value}); }
  }
  if(phase==="resuming" && pausePosition!==null && value>pausePosition+0.1 && !resumed) {
    resumed=true;checks.resume=true;event("resumed_progress",{position:value});
    setTimeout(()=>{
      if(done)return;
      phase="seeking";seekTarget=Math.min(60,duration*.4);event("seek_requested",{position:seekTarget});
      provider==="youtube" ? player.seekTo(seekTarget,true) : player.seekTo(seekTarget*1000);
    },2000);
  }
  if(phase==="seeking" && Math.abs(value-seekTarget)<2) { checks.seek=true;event("seek_observed",{position:value});finish("observed_controls"); }
  lastPosition=value;
}
function observedPause() {
  if(done || phase!=="pausing")return;
  checks.pause=true;pausePosition=lastPosition;phase="paused";event("paused");
  setTimeout(()=>{if(!done){phase="resuming";lastAdvance=performance.now();event("resume_requested");play();}},10000);
}
const poll=setInterval(()=>{
  if(done || !player || !checks.ready)return;
  if(provider==="youtube")position(player.getCurrentTime(),player.getDuration());
  else player.getPosition(value=>player.getDuration(duration=>position(value/1000,duration/1000)));
},250);
document.querySelector("#title").textContent=`${provider} · medição externa`;
if(provider==="youtube" && /^[A-Za-z0-9_-]{11}$/.test(item)) {
  window.onYouTubeIframeAPIReady=()=>{
    player=new YT.Player("player",{width:640,height:360,videoId:item,playerVars:{origin:location.origin,playsinline:1},events:{
      onReady:()=>{player.mute();begin();},
      onError:e=>{event("error",{code:e.data});finish("player_error");},
      onAutoplayBlocked:()=>finish("autoplay_blocked"),
      onStateChange:e=>{if(done)return;if(e.data===1)observedPlay();if(e.data===2)observedPause();if(e.data===3)event("buffering");if(e.data===0){event("ended");finish("unexpected_end");}}
    }});
  };
  script("https://www.youtube.com/iframe_api");
} else if(provider==="soundcloud" && /^\d{1,20}$/.test(item)) {
  const frame=document.createElement("iframe");frame.width=640;frame.height=166;frame.allow="autoplay";
  frame.src=`https://w.soundcloud.com/player/?url=${encodeURIComponent("https://api.soundcloud.com/tracks/"+item)}&auto_play=false`;
  document.querySelector("#player").append(frame);
  script("https://w.soundcloud.com/player/api.js",()=>{
    player=SC.Widget(frame);const E=SC.Widget.Events;
    player.bind(E.READY,()=>{player.setVolume(0);begin();});player.bind(E.PLAY,observedPlay);
    player.bind(E.PAUSE,observedPause);player.bind(E.ERROR,()=>{event("error");finish("player_error");});
  });
} else finish("invalid_input");
setTimeout(()=>finish("deadline_exceeded"),75000);
