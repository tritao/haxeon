package haxeon.audio;

import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;

/** Three-dimensional audio coordinate in the right-handed OpenGL convention. */
class Vector3 {
	public final x:Float;
	public final y:Float;
	public final z:Float;

	public function new(x:Float, y:Float, z:Float) {
		this.x = x;
		this.y = y;
		this.z = z;
	}

	public static function zero():Vector3
		return new Vector3(0.0, 0.0, 0.0);

	@:allow(haxeon.audio.Mixer)
	@:allow(haxeon.audio.Voice)
	private function nativeValue():AudioVector3Value {
		var result = new AudioVector3Value();
		result.set_x(x);
		result.set_y(y);
		result.set_z(z);
		return result;
	}

	@:allow(haxeon.audio.Mixer)
	@:allow(haxeon.audio.Voice)
	private static function fromNative(value:AudioVector3Value):Vector3
		return new Vector3(value.get_x(), value.get_y(), value.get_z());
}
