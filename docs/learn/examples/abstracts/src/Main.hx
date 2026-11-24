abstract Metres(Float) {
	public function new(value:Float) {
		this = value;
	}

	public function centimetres():Float {
		return this * 100;
	}
}

function main():Void {
	final width = new Metres(1.5);
	Sys.println('${width.centimetres()} cm');
}
