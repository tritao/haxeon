package haxeon.audio;

/** Prepared source definition shared by procedural and sampled instruments.
 * Implementations allocate resources on the calling preparation thread.
 * The returned instrument participates in the engine's native note/transport API.
 */
interface InstrumentDefinition {
	/** Creates the instrument on `engine`. */
	public function createInstrument(engine:DspEngine):DspInstrument;
}
