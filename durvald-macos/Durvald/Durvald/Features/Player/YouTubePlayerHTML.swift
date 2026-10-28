import Foundation

extension EmbeddedPlayerController {
    nonisolated static func youtubeHTML(url: String, volume: Double) -> String {
        let encoded = String(data: try! JSONSerialization.data(withJSONObject: [url]), encoding: .utf8)!.replacingOccurrences(of: "<", with: "\\u003c")
        let initialVolume = min(1, max(0, volume.isFinite ? volume : 0.5)) * 100
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>html,body{margin:0;background:transparent;height:100%}#player{width:100%;height:100%;min-height:200px;min-width:200px}</style></head><body><div id="player"></div><script>
        'use strict';const source=\(encoded)[0],video=new URL(source).searchParams.get('v');let player,ready=false,desiredPlay=true,volume=\(initialVolume),seekTarget=null;
        const send=kind=>{let position=0,duration=null;if(ready){position=player.getCurrentTime()||0;const d=player.getDuration();if(Number.isFinite(d)&&d>0)duration=d;}window.webkit.messageHandlers.durvaldPlayback.postMessage({kind,position,duration});};
        window.durvaldCommand=(kind,value)=>{if(kind==='volume'){volume=value*100;if(ready)player.setVolume(volume);}if(kind==='pause'){desiredPlay=false;if(ready)player.pauseVideo();}if(kind==='play'){desiredPlay=true;if(ready)player.playVideo();}if(kind==='seek'&&ready){seekTarget=value;player.seekTo(value,true);}};
        window.onYouTubeIframeAPIReady=()=>{player=new YT.Player('player',{videoId:video,playerVars:{origin:location.origin,playsinline:1,controls:1},events:{onReady:()=>{ready=true;player.setVolume(volume);send('ready');if(desiredPlay)player.playVideo();},onStateChange:e=>{if(e.data===1)send('playing');if(e.data===2)send('paused');if(e.data===0)send('ended');},onError:()=>send('failed'),onAutoplayBlocked:()=>send('failed')}});};
        setInterval(()=>{if(ready&&player.getPlayerState()===1){if(seekTarget!==null&&Math.abs(player.getCurrentTime()-seekTarget)<3){seekTarget=null;send('seeked');}else send('progress');}},500);
        const script=document.createElement('script');script.src='https://www.youtube.com/iframe_api';script.onerror=()=>send('failed');document.head.appendChild(script);
        </script></body></html>
        """
    }
}
