// Reading an abstract's receiver exposes its representation inside its implementation,
// without granting conversions between nominally different values outside it.
abstract Voltage(Float) {
	public function new(value:Float)
		this = value;

	public function raw():Float
		return this;

	public function inferred():Float {
		var value = this;
		return value;
	}

	public function doubled():Float
		return raw() + inferred();

	public function same():Voltage
		return new Voltage(this);

	public function optional():Null<Voltage>
		return new Voltage(this);

	public function captured():Float {
		var read = () -> this;
		return read();
	}
}

abstract Box<T>(Array<T>) {
	public function new(values:Array<T>)
		this = values;

	public function values():Array<T>
		return this;

	public function first():T
		return values()[0];
}

function main():Int {
	var voltage = new Voltage(10.5);
	var floats = new Box<Float>([voltage.doubled()]);
	var strings = new Box<String>(["typed"]);
	var optional = voltage.optional();
	if (optional == null || optional.raw() != 10.5 || voltage.captured() != 10.5)
		return 2;
	if (voltage.same().raw() != 10.5 || floats.first() != 21 || strings.first() != "typed")
		return 1;
	return 42;
}
