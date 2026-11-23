# Cleanup at the end of a block

Use `defer` to run a statement when execution leaves its enclosing block, including on an early return or an
exception. Use `scoped var` to register a call to `dispose()` once the initializer for a `Disposable` succeeds.

Cleanup runs in reverse registration order. Here `finish` runs first, then the session closes, then `leave`
runs. The caller prints the return value after those actions complete.

```haxe
class Session implements Disposable {
	public function new() {
		Sys.println("open");
	}

	public function dispose():Void {
		Sys.println("close");
	}
}

function work():String {
	defer Sys.println("leave");
	scoped var session = new Session();
	defer Sys.println("finish");
	return "done";
}

function main():Void {
	Sys.println(work());
}
```

```text title="Output"
open
finish
close
leave
done
```

[Example project](examples/cleanup/)

[Scoped cleanup](../reference/SCOPED_CLEANUP.md)
