// A raw-value enum's cases carry an Int or String code: omitted Int codes count up from the previous one and omitted
// String codes are the case name. rawValue() gives the code, fromRaw() the case or null, and `this` in a method is the
// enum value. A switch covers every case, as over any enum.
enum PixelFormat:Int {
	Rgba8 = 1;
	Bgra8 = 2;
	R8;

	public function bytesPerPixel():Int
		return this == R8 ? 1 : 4;

	public function next():PixelFormat
		return switch this {
			case Rgba8: Bgra8;
			case Bgra8: R8;
			case R8: Rgba8;
		};

	public function doubled():Int
		return this.rawValue() * 2;

	public static final all:Array<PixelFormat> = [Rgba8, Bgra8, R8];
}

enum Side:String {
	Left;
	Right = "R";
}

// A struct's final field of a raw-value enum is a value: reading its code does not write the struct, so the method runs
// on a temporary copy.
struct Tagged {
	public final format:PixelFormat;

	public function new(format:PixelFormat)
		this.format = format;

	public function code():Int
		return format.rawValue();
}

function name(format:PixelFormat):String
	return switch format {
		case Rgba8: "rgba";
		case Bgra8, R8: "other";
	};

function main():Int {
	if (PixelFormat.R8.rawValue() != 3 || PixelFormat.Rgba8.next() != Bgra8 || PixelFormat.R8.bytesPerPixel() != 1)
		return 1;
	if (PixelFormat.fromRaw(2) != Bgra8 || PixelFormat.fromRaw(9) != null || PixelFormat.all.length != 3)
		return 2;
	if (Side.Left.rawValue() != "Left" || Side.Right.rawValue() != "R" || Side.fromRaw("R") != Right)
		return 3;
	if (Side.fromRaw("Right") != null || name(Rgba8) != "rgba" || name(R8) != "other")
		return 4;
	if (Bgra8.doubled() != 4 || Std.string(Side.Left) != "Left" || new Tagged(R8).code() != 3)
		return 5;
	var maybe:Null<PixelFormat> = PixelFormat.fromRaw(1);
	return maybe == Rgba8 ? 42 : 6;
}
