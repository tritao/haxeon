package haxeon.audio;

import haxeon.platform.BindingError;

import haxeon.audio.SoundFont.SoundFontPresetInfo;
import sys.FileSystem;
import sys.io.File;
import sys.thread.Condition;

private typedef CachedBank = {
    var path:String;
    var sourceBytes:Int;
    var font:Null<SoundFont>;
    var inventory:Array<SoundFontPresetInfo>;
    var users:Int;
    var loading:Bool;
    var error:Dynamic;
    var stamp:Float;
}

typedef SoundFontCacheStats = {
    var banks:Int;
    var loading:Int;
    var leases:Int;
    var sourceBytes:Int;
    var loads:Int;
    var hits:Int;
    var evictions:Int;
    var failedLoads:Int;
}

/** Scoped immutable SF2 assets, shared by independent instruments. Never use on the audio thread.
 * Bounds resident banks and source bytes, including load reservations; decoded/playback memory
 * is not measured by sourceBytes. Files are immutable within a cache scope. Idle banks are LRU
 * evicted, leased banks stay pinned. Concurrent requests for one canonical path share one load.
 * Close before NativeKit shutdown; outstanding leases remain usable until individually released.
 */
class SoundFontCache {
    final condition = new Condition();
    final entries:Map<String,CachedBank> = new Map();
    final maxBanks:Int;
    final maxSourceBytes:Int;
    var bankCount=0;
    var sourceBytes=0;
    var stamp:Float=0;
    var loads=0;
    var hits=0;
    var evictions=0;
    var failedLoads=0;
    var closed=false;

    public function new(maxBanks:Int=4,maxSourceBytes:Int=8*1024*1024) {
        if (maxBanks<1 || maxBanks>64 || maxSourceBytes<1 || maxSourceBytes>512*1024*1024)
            throw BindingError.invalidArgument("SoundFontCache.new", "Invalid SoundFont cache limits");
        this.maxBanks=maxBanks; this.maxSourceBytes=maxSourceBytes;
    }

    /** Acquire on a preparation thread. A lease owns access to definitions, not playback state. */
    public function acquire(path:String):SoundFontLease {
        if (path==null || path.length==0) throw BindingError.invalidArgument("SoundFontCache.acquire", "SoundFont path must not be empty");
        var key=FileSystem.fullPath(path);
        var metadata=FileSystem.metadata(key);
        if (metadata==null) throw BindingError.invalidArgument("SoundFontCache.acquire", "SoundFont file is unavailable: "+key);
        var bytes=metadata.size;
        if (bytes<=0 || bytes>maxSourceBytes) throw BindingError.invalidArgument("SoundFontCache.acquire", "SoundFont exceeds cache source-byte budget");
        var victims:Array<SoundFont> = [];
        condition.acquire();
        if (closed) { condition.release(); throw BindingError.disposed("SoundFontCache.acquire", "SoundFont cache disposed"); }
        var existing=entries.get(key);
        if (existing!=null) {
            // Pin before waiting: the first caller may release/evict immediately after loading.
            existing.users++;
            while (existing.loading && !closed) condition.wait();
            if (closed || existing.error!=null) {
                existing.users--;
                var close=closed && !existing.loading && existing.error==null && existing.users==0;
                if (close) remove(existing);
                var failure:Dynamic=existing.error==null
                    ? BindingError.disposed("SoundFontCache.acquire", "SoundFont cache disposed") : existing.error;
                condition.release();
                if (close) existing.font.dispose();
                throw failure;
            }
            existing.stamp=++stamp; hits++;
            condition.release(); return new SoundFontLease(this,existing);
        }
        // Choose the full eviction set before mutating, so failed admission retains useful banks.
        var selected:Array<CachedBank> = [];
        var remainingBanks=bankCount; var remainingBytes=sourceBytes;
        while (remainingBanks>=maxBanks || remainingBytes+bytes>maxSourceBytes) {
            var oldest:Null<CachedBank> = null;
            for (entry in entries) if (!entry.loading && entry.users==0 && selected.indexOf(entry)<0
                && (oldest==null || entry.stamp<oldest.stamp)) oldest=entry;
            if (oldest==null) { condition.release(); throw BindingError.invalidState("SoundFontCache.acquire", "SoundFont cache budget is pinned by active leases"); }
            selected.push(oldest); remainingBanks--; remainingBytes-=oldest.sourceBytes;
        }
        for (entry in selected) {
            remove(entry); victims.push(cast entry.font); evictions++;
        }
        var entry:CachedBank={path:key,sourceBytes:bytes,font:null,inventory:[],users:1,
            loading:true,error:null,stamp:++stamp};
        entries.set(key,entry); bankCount++; sourceBytes+=bytes;
        condition.release();

        var font:Null<SoundFont> = null;
        try {
            closeFonts(victims);
            var data=File.getBytes(key);
            if (data.length!=bytes) throw BindingError.invalidData("SoundFontCache.acquire", "SoundFont changed during cache loading");
            font=SoundFont.fromMemory(data);
            var inventory=font.presets();
            var lease=new SoundFontLease(this,entry);
            condition.acquire();
            if (closed) { condition.release(); throw BindingError.disposed("SoundFontCache.acquire", "SoundFont cache disposed during loading"); }
            entry.font=font; entry.inventory=inventory; entry.loading=false;
            loads++; condition.broadcast(); condition.release();
            return lease;
        } catch (failure:Dynamic) {
            condition.acquire();
            entry.error=failure; entry.loading=false; entry.users--; remove(entry); failedLoads++;
            condition.broadcast(); condition.release();
            if (font!=null) font.dispose();
            throw failure;
        }
    }

    // Called with the mutex held. Native destruction always occurs after releasing it.
    function remove(entry:CachedBank):Void {
        entries.remove(entry.path); bankCount--; sourceBytes-=entry.sourceBytes;
    }
    @:allow(haxeon.audio.SoundFontLease)
    private function release(entry:CachedBank):Void {
        condition.acquire();
        entry.users--; entry.stamp=++stamp;
        var close=closed && entry.users==0;
        if (close) remove(entry);
        condition.release();
        if (close) entry.font.dispose();
    }
    public function stats():SoundFontCacheStats {
        condition.acquire();
        var loading=0; var leases=0;
        for (entry in entries) { if (entry.loading) loading++; leases+=entry.users; }
        var result={banks:bankCount,loading:loading,leases:leases,sourceBytes:sourceBytes,
            loads:loads,hits:hits,evictions:evictions,failedLoads:failedLoads};
        condition.release(); return result;
    }
    /** Reject new acquisitions; outstanding leases retain their bank until released. */
    public function dispose():Void {
        var victims:Array<SoundFont> = [];
        condition.acquire();
        if (closed) { condition.release(); return; }
        closed=true;
        var idle=[for (entry in entries) if (!entry.loading && entry.users==0) entry];
        for (entry in idle) { remove(entry); victims.push(cast entry.font); }
        condition.broadcast(); condition.release();
        closeFonts(victims);
    }
    static function closeFonts(fonts:Array<SoundFont>):Void {
        var failure:Dynamic=null;
        for (font in fonts) try font.dispose() catch (error:Dynamic) { if (failure==null) failure=error; }
        if (failure!=null) throw failure;
    }
}

/** Caller-owned pin. Dispose after consumers have finished creating instruments.
 * Native instruments retain samples independently after release. A lease has one owning thread.
 */
class SoundFontLease {
    final cache:SoundFontCache;
    final entry:CachedBank;
    var disposed=false;
    @:allow(haxeon.audio.SoundFontCache)
    private function new(cache:SoundFontCache,entry:CachedBank) { this.cache=cache; this.entry=entry; }
    function ensureLive():Void { if (disposed) throw BindingError.disposed("SoundFontLease.ensureLive", "SoundFont lease disposed"); }
    public function presets():Array<SoundFontPresetInfo> {
        ensureLive();
        return [for (info in entry.inventory) {index:info.index,bank:info.bank,program:info.program,name:info.name}];
    }
    public function preset(index:Int,gain:Float=1):InstrumentDefinition {
        ensureLive();
        if (index<0 || index>=entry.inventory.length || !Math.isFinite(gain) || gain<0 || gain>4)
            throw BindingError.invalidArgument("SoundFontLease.preset", "Invalid cached SoundFont preset");
        return new LeasedPreset(this,index,gain);
    }
    public function createInstrument(engine:DspEngine,index:Int,gain:Float=1):DspInstrument {
        ensureLive();
        var font:SoundFont=cast entry.font;
        return font.preset(index,gain).createInstrument(engine);
    }
    public function dispose():Void {
        if (disposed) return;
        disposed=true; cache.release(entry);
    }
}

private class LeasedPreset implements InstrumentDefinition {
    final lease:SoundFontLease;
    final index:Int;
    final gain:Float;
    public function new(lease:SoundFontLease,index:Int,gain:Float) { this.lease=lease; this.index=index; this.gain=gain; }
    public function createInstrument(engine:DspEngine):DspInstrument return lease.createInstrument(engine,index,gain);
}
