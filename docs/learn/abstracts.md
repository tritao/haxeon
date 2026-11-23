# Abstracts

Use an abstract to give an underlying value a distinct type and its own operations. `Metres` wraps a
`Float`. Inside the abstract, `this` is the underlying value. Callers construct `Metres` explicitly and
use its method to convert to centimetres.

```haxe
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
```

```text title="Output"
150 cm
```

[Example project](examples/abstracts/)

[Language support](../reference/LANGUAGE_SUPPORT.md)
