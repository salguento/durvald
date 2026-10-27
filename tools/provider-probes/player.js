"use strict";
const params = new URLSearchParams(location.search);
const provider = params.get("provider"), item = params.get("item"), testCase = params.get("case") || "playback";
const checks = testCase === "unavailable" ? {unavailable:false} : {ready:false,play:false,progress:false,pause:false,resume:false,seek:false,ended:false};
const start = performance.now();
let finished = false, phase = "loading", player;
function event(name, values = {}) {
  const value = {event: name, time: Math.round(performance.now()-start), ...values};
  document.querySelector("#events").textContent += JSON.stringify(value) + "\n";
  window.webkit?.messageHandlers?.probe?.postMessage({...value,checks});
}
function finish() {
  if (finished) return; finished = true;
  window.webkit?.messageHandlers?.probe?.postMessage({done:true, checks});
}
function script(url, ready) { const s = document.createElement("script"); s.src=url; if(ready)s.onload=ready; s.onerror=()=>{checks.sdk=false;event("error");finish()};document.head.append(s); }
document.querySelector("#title").textContent = `${provider} · ${testCase}`;
if (provider === "youtube" && /^[A-Za-z0-9_-]{11}$/.test(item)) {
  window.onYouTubeIframeAPIReady = () => {
    player = new YT.Player("player", {width:640,height:360,videoId:item,playerVars:{origin:location.origin,playsinline:1},events:{
      onReady: e => { checks.ready=true;event("ready"); if(testCase!=="unavailable"){e.target.mute();e.target.playVideo();} else e.target.playVideo(); },
      onError: e => { event("error",{code:e.data});checks.unavailable=[100,101,150].includes(e.data);if(testCase!=="unavailable")checks.playback=false;finish(); },
      onAutoplayBlocked: () => {event("error");checks.autoplay=false;finish();},
      onStateChange: e => {
        if(testCase==="unavailable"||finished)return;
        if(e.data===1 && phase==="loading") {
          phase="playing";checks.play=true;const first=player.getCurrentTime();event("playing",{position:first,duration:player.getDuration()});
          setTimeout(()=>{checks.progress=player.getCurrentTime()>first+.3;phase="pause";player.pauseVideo()},2200);
        } else if(e.data===2 && phase==="pause") { checks.pause=true;event("paused");phase="resume";setTimeout(()=>player.playVideo(),400);
        } else if(e.data===1 && phase==="resume") {
          checks.resume=true;event("resumed");phase="seek";
          const target=Math.min(60,player.getDuration()*.4);player.seekTo(target,true);
          setTimeout(()=>{
            checks.seek=Math.abs(player.getCurrentTime()-target)<6;event("seek",{position:player.getCurrentTime()});
            phase="ending";player.seekTo(Math.max(0,player.getDuration()-2),true);player.playVideo();
            setTimeout(()=>{if(!finished){player.pauseVideo();finish()}},10000);
          },2200);
        } else if(e.data===0 && phase==="ending") {checks.ended=true;event("ended");player.pauseVideo();finish();}
      }
    }});
  };
  script("https://www.youtube.com/iframe_api");
} else if(provider === "soundcloud" && /^\d+$/.test(item)) {
  const iframe=document.createElement("iframe");iframe.id="sc-player";iframe.width="640";iframe.height="166";iframe.allow="autoplay";
  iframe.src=`https://w.soundcloud.com/player/?url=${encodeURIComponent("https://api.soundcloud.com/tracks/"+item)}&auto_play=false`;
  document.querySelector("#player").append(iframe);
  script("https://w.soundcloud.com/player/api.js",()=>{
    player=SC.Widget(iframe);const E=SC.Widget.Events;
    player.bind(E.ERROR,()=>{if(testCase==="unavailable")checks.unavailable=true;else checks.playback=false;event("error");finish()});
    player.bind(E.READY,()=>{checks.ready=true;event("ready");player.setVolume(0);player.play()});
    player.bind(E.PLAY_PROGRESS,e=>{if(e.currentPosition>300)checks.progress=true});
    player.bind(E.PLAY,()=>{
      if(phase==="loading"){phase="playing";checks.play=true;event("playing");setTimeout(()=>{phase="pause";player.pause()},2200)}
      else if(phase==="resume") {phase="seek";checks.resume=true;event("resumed");player.getDuration(duration=>{
        const target=Math.min(60000,duration*.4);player.seekTo(target);
        setTimeout(()=>player.getPosition(position=>{checks.seek=Math.abs(position-target)<6000;event("seek",{position:position/1000,duration:duration/1000});phase="ending";player.seekTo(Math.max(0,duration-1500));player.play();setTimeout(()=>{if(!finished){player.pause();finish()}},10000)}),2200);
      })}
    });
    player.bind(E.PAUSE,()=>{if(phase==="pause"){checks.pause=true;event("paused");phase="resume";setTimeout(()=>player.play(),400)}});
    player.bind(E.FINISH,()=>{if(phase==="ending"){checks.ended=true;event("ended");finish()}});
  });
} else { checks.valid_input=false;finish(); }
setTimeout(()=>{if(!finished){checks.completed=false;event("timeout");finish()}},55000);
