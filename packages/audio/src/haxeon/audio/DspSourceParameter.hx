package haxeon.audio;

/** Source controls use native, source-specific validated domains. */
enum abstract DspSourceParameter(Int) from Int to Int {
  var Ratio = 0;
  var Index = 1;
  var Accent = 2;
  var Structure = 3;
  var Brightness = 4;
  var Damping = 5;
  var Nonlinearity = 6;
  var Position = 7;
  var Resolution = 8;
  var Dettack = 9;
  var Tone = 10;
  var Decay = 11;
  var AttackFm = 12;
  var SelfFm = 13;
  var Dirtiness = 14;
  var FmAmount = 15;
  var FmDecay = 16;
  var Snappy = 17;
  var Noisiness = 18;
  var FormantRatio = 19;
  var PhaseShift = 20;
  var SecondFormantRatio = 21;
  var Shape = 22;
  var Mode = 23;
  var PulseWidth = 24;
  var SyncRatio = 25;
  var FirstHarmonic = 26;
  var Bleed = 27;
  var Resonance = 28;
  var RandomRate = 29;
  var Density = 30;
  var Spread = 31;
  var Color = 32;
  var Speed = 33;
  var RootNote = 34;
  var GrainMs = 35;
  var Sustain = 36;
  var SyncEnabled = 37;
}
