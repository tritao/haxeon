import haxe.ds.ObjectMap;

typedef Point = {x:Int};
typedef OptionalPoint = {x:Int, ?label:String};
typedef Nested = {point:Point};

class Main {
	static function require(ok:Bool, name:String):Void {
		if (!ok)
			throw name;
	}

	#if haxeon
	static function main():Int {
		checkConversions();
		return 42;
	}
	#else
	static function main():Void
		checkConversions();
	#end

	static function checkConversions():Void {
		var stored = {x: 1};
		var dynamicPoint:Dynamic = stored;
		var castPoint:Point = cast dynamicPoint;
		castPoint.x = 5;
		require(stored.x == 5 && castPoint == stored, "explicit cast");

		var nested:Nested = {point: stored};
		var dynamicNested:Dynamic = nested;
		var nestedView:Nested = dynamicNested;
		nestedView.point.x = 6;
		require(nestedView == nested && nestedView.point == stored && stored.x == 6, "nested record");

		var optional:OptionalPoint = {x: 1};
		var dynamicOptional:Dynamic = optional;
		var optionalView:OptionalPoint = dynamicOptional;
		require(optionalView.label == null, "missing optional field");
		optionalView.label = "set";
		require(optionalView == optional && optional.label == "set", "optional field write");

		var map = new Map<String, Dynamic>();
		map.set("point", stored);
		var mapView:Point = map.get("point");
		mapView.x = 7;
		require(mapView == stored && stored.x == 7, "Map read");

		var key = new Main();
		var objects = new ObjectMap<Main, Point>();
		objects.set(key, stored);
		var objectView:Point = objects.get(key);
		objectView.x = 8;
		require(objectView == stored && stored.x == 8, "ObjectMap read");

		var values:Array<Dynamic> = [stored];
		var arrayView:Point = values[0];
		arrayView.x = 9;
		require(arrayView == stored && stored.x == 9, "Array<Dynamic> read");

		var wider = {x: 10, extra: true};
		var dynamicWider:Dynamic = wider;
		var narrowed:Point = dynamicWider;
		require(narrowed.x == 10, "different layout read");
		narrowed.x = 11;
		#if haxeon
		require(wider.x == 10 && narrowed != dynamicWider, "different layout copy");
		#else
		require(wider.x == 11 && narrowed == dynamicWider, "different layout alias");
		#end
	}

	public function new() {}
}
