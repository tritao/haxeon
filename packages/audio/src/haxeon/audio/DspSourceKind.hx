package haxeon.audio;

/** Specialized DaisySP sources; SF2 is a separate sample-bank backend. */
enum abstract DspSourceKind(Int) from Int to Int {
  var Fm2 = 1;
  var StringVoice = 2;
  var KarplusString = 3;
  var ModalVoice = 4;
  var Resonator = 5;
  var Drip = 6;
  var AnalogBassDrum = 7;
  var SyntheticBassDrum = 8;
  var AnalogSnareDrum = 9;
  var SyntheticSnareDrum = 10;
  var HiHat = 11;
  var Formant = 12;
  var Vosim = 13;
  var Zosc = 14;
  var VariableSaw = 15;
  var VariableShape = 16;
  var OscillatorBank = 17;
  var Harmonic = 18;
  var Grainlet = 19;
  var Particle = 20;
  var Dust = 21;
  var ClockedNoise = 22;
  var FractalNoise = 23;
  var Granular = 24;
}
