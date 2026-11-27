package namedargs;

/** A static extension whose parameters a call may name after the receiver. */
class Padding {
	public static function padded(text:String, left:Int = 0, right:Int = 0, fill:String = "."):String {
		var out = text;
		for (_ in 0...left)
			out = fill + out;
		for (_ in 0...right)
			out = out + fill;
		return out;
	}
}
