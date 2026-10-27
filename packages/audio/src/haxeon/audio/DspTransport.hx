package haxeon.audio;

import haxeon.platform.BindingError;

import haxe.Int64;
import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;

typedef DspTransportEvent = {
    var frame:Float;
    /** 0 = note on, 1 = note off, 2 = tempo. */
    var kind:Int;
    var noteId:Int;
    var instrument:Null<DspInstrument>;
    var note:Int;
    var velocity:Float;
    var bpm:Float;
}
typedef DspTransportSection = {
    var lengthFrames:Float;
    var events:Array<DspTransportEvent>;
    var bars:Array<Float>;
}
typedef DspRuntimeStatus = {
    var playing:Bool;
    var section:Int;
    var frame:Int64;
    var loops:Int64;
    var bpm:Float;
    var stolenVoices:Int64;
    var droppedNotes:Int64;
    var retiredResources:Int64;
    var clockDiscontinuities:Int64;
}

/** Immutable prepared native score. Dispose retires it; collection occurs off callback. */
class DspTransport {
    final engine:DspEngine;
    final id:Int64;
    var disposed:Bool = false;
    @:allow(haxeon.audio.DspEngine)
    private function new(engine:DspEngine, id:Int64) {
        this.engine = engine; this.id = id;
    }
    public function play(section:Int, startFrame:Int64):Void {
        if (disposed) throw BindingError.disposed("DspTransport.play", "DSP transport has been disposed");
        AudioResult.check(NativeKitAudio.nk_audio_dsp_engine_play_transport(engine.nativeHandle(),
            id, section, startFrame), "audio.dsp.transport.play");
    }
    static function groupTracks(programs:Array<DspTransport>):Array<NativeDspTransportTrack> {
        var tracks:Array<NativeDspTransportTrack> = [];
        for (program in programs) {
            if (program.disposed) throw BindingError.disposed("DspTransport.groupTracks", "DSP transport has been disposed");
            var track = new NativeDspTransportTrack();
            track.set_engine(program.engine.nativeHandle()); track.set_program_id(program.id);
            tracks.push(track);
        }
        return tracks;
    }
    /** Publish every track together, using a common native clock origin. */
    public static function playGroup(programs:Array<DspTransport>, section:Int, startFrame:Int64):Void {
        AudioResult.check(NativeKitAudio.nk_audio_dsp_group_play_transport(groupTracks(programs), section, startFrame),
            "audio.dsp.transport.playGroup");
    }
    public static function requestGroup(programs:Array<DspTransport>, section:Int):Void {
        AudioResult.check(NativeKitAudio.nk_audio_dsp_group_request_section(groupTracks(programs), section),
            "audio.dsp.transport.requestGroup");
    }
    /** Atomically relocate all tracks, optionally holding their playhead. */
    public static function seekGroup(programs:Array<DspTransport>, section:Int, frame:Float, paused:Bool):Void {
        AudioResult.check(NativeKitAudio.nk_audio_dsp_group_seek_transport(groupTracks(programs),
            section, frame, paused ? 1 : 0), "audio.dsp.transport.seekGroup");
    }
    public static function setGroupPaused(programs:Array<DspTransport>, paused:Bool):Void {
        AudioResult.check(NativeKitAudio.nk_audio_dsp_group_set_paused(groupTracks(programs),
            paused ? 1 : 0), "audio.dsp.transport.setGroupPaused");
    }
    public function dispose():Void {
        if (disposed) return;
        if (!engine.isDisposed()) AudioResult.check(NativeKitAudio.nk_audio_dsp_engine_retire_transport(
            engine.nativeHandle(), id), "audio.dsp.transport.retire");
        disposed = true;
    }
}
