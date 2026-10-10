import haxeon.audio.DspSourceKind;
import haxeon.audio.DspSourceParameter;
import haxeon.audio.DspSourceOptions;
import haxeon.audio.DspPatchBuilder;
import haxeon.audio.DspEngine;
import haxeon.audio.DspEngineOptions;
import haxeon.audio.DspRenderTarget;
import haxeon.audio.DspEvent;
class DaisySourceSmoke {
  static function reject(action:Void -> Void):Void {
    var rejected = false;
    try action() catch (_:Dynamic) rejected = true;
    if (!rejected) throw "Invalid DaisySP configuration was accepted";
  }
  public static function run():Void {
    var fm = new DspSourceOptions(DspSourceKind.Fm2).set(DspSourceParameter.Ratio, 3).set(DspSourceParameter.Index, 7);
    if (fm.get(DspSourceParameter.Ratio) != 3
      || fm.get(DspSourceParameter.Index) != 7) throw "DaisySP source controls did not round-trip";
    reject(function() {
      fm.set(DspSourceParameter.Damping, 0.5);
    }
    );
    reject(function() {
      fm.set(DspSourceParameter.Ratio, -1);
    }
    );
    var resonator = new DspSourceOptions(DspSourceKind.Resonator);
    reject(function() {
      resonator.set(DspSourceParameter.Resolution, 5);
    }
    );
    var bank = new DspSourceOptions(DspSourceKind.OscillatorBank);
    reject(function() {
      bank.spectrum([0, 0, 0, 0, 0, 0, 0]);
    }
    );
    bank.spectrum([1, 1, 1, 1, 1, 1, 1]);
    var options = new DspEngineOptions();
    options.channels = 1;
    options.blockSize = 256;
    options.maxVoices = 2;
    var engine = DspEngine.create(options);
    try {
      for (kind in 1...25) {
        var builder = new DspPatchBuilder();
        builder.source = new DspSourceOptions(cast kind);
        builder.gain = 0.2;
        if (kind == 24) builder.source.samples = [for (i in 0...97) 0.5 * Math.sin(i * 0.1)];
        var patch = builder.build();
        var instrument = engine.createInstrument(patch);
        patch.dispose();
        var target = new DspRenderTarget(256, 1);
        engine.render(target, [DspEvent.noteOn(instrument, kind, 60)]);
        for (i in 0...256) if (!Math.isFinite(target.samples.getFloat(i * 4))) throw "Nonfinite DaisySP managed render";
        engine.render(target, [DspEvent.noteOff(kind)]);
        for (i in 0...40) engine.render(target, []);
        instrument.dispose();
      }
    } catch (error:Dynamic) {
      engine.dispose();
      throw error;
    }
    engine.dispose();
  }
}
