package project;

import build.Target;

/** Resolution-time compatibility requirements carried by a package manifest. */
class PackageCompatibility {
	public static inline final CURRENT_HAXEON = "0.3.0";
	public static inline final CURRENT_RUNTIME_ABI = "2";

	public final haxeon:Null<String>;
	public final targets:Array<String>;
	public final runtimeAbi:Null<String>;
	public final nativeRequirements:Array<String>;
	public final features:Array<String>;

	public function new(?haxeon:String, ?targets:Array<String>, ?runtimeAbi:String, ?nativeRequirements:Array<String>, ?features:Array<String>) {
		this.haxeon = haxeon;
		this.targets = targets == null ? [] : targets.copy();
		this.runtimeAbi = runtimeAbi;
		this.nativeRequirements = nativeRequirements == null ? [] : nativeRequirements.copy();
		this.features = features == null ? [] : features.copy();
	}

	public function validate(packageName:String, target:Target):Void {
		if (haxeon != null && !satisfiesVersionRange(haxeon, CURRENT_HAXEON))
			throw 'Package $packageName requires Haxeon "$haxeon" (current ${CURRENT_HAXEON})';
		if (targets.length > 0) {
			var matches = false;
			for (declared in targets)
				try {
					if (Target.parse(declared).equals(target))
						matches = true;
				} catch (_:Dynamic) {}
			if (!matches)
				throw 'Package $packageName does not support target ${target.toString()} (supported: ${targets.join(", ")})';
		}
		if (runtimeAbi != null && runtimeAbi != CURRENT_RUNTIME_ABI)
			throw 'Package $packageName requires runtime ABI $runtimeAbi (current ${CURRENT_RUNTIME_ABI})';
	}

	public static function parse(raw:Dynamic, path:String):PackageCompatibility {
		if (raw == null)
			return new PackageCompatibility();
		if (!Reflect.isObject(raw) || Std.isOfType(raw, Array))
			throw '$path "compatibility" must be an object';
		var haxeon = optionalString(raw, "haxeon", path),
			targets = stringArray(raw, "targets", path),
			runtimeAbi = optionalString(raw, "runtimeAbi", path),
			nativeRequirements = stringArray(raw, "nativeRequirements", path),
			features = stringArray(raw, "features", path);
		for (target in targets)
			try {
				Target.parse(target);
			} catch (error:Dynamic) {
				throw '$path "compatibility.targets" contains an invalid target "$target": ${Std.string(error)}';
			}
		return new PackageCompatibility(haxeon, targets, runtimeAbi, nativeRequirements, features);
	}

	public static function satisfiesVersionRange(range:String, actual:String):Bool {
		if (StringTools.trim(range) == "*" || StringTools.trim(range) == "")
			return true;
		var constraints:Array<String> = [];
		for (piece in range.split(","))
			for (term in StringTools.trim(piece).split(" "))
				if (term.length > 0)
					constraints.push(term);
		if (constraints.length == 0)
			return false;
		for (constraint in constraints) {
			var comparator = "=";
			for (candidate in [">=", "<=", ">", "<", "="]) {
				if (StringTools.startsWith(constraint, candidate)) {
					comparator = candidate;
					constraint = constraint.substr(candidate.length);
					break;
				}
			}
			if (StringTools.startsWith(constraint, "^")) {
				var lower = parseVersion(constraint.substr(1)), current = parseVersion(actual);
				if (compare(current, lower) < 0 || current[0] != lower[0])
					return false;
				continue;
			}
			if (StringTools.startsWith(constraint, "~")) {
				var lower = parseVersion(constraint.substr(1)), current = parseVersion(actual);
				if (compare(current, lower) < 0 || current[0] != lower[0] || current[1] != lower[1])
					return false;
				continue;
			}
			var comparison = compare(parseVersion(actual), parseVersion(constraint));
			if ((comparator == "=" && comparison != 0)
				|| (comparator == ">=" && comparison < 0)
				|| (comparator == "<=" && comparison > 0)
				|| (comparator == ">" && comparison <= 0)
				|| (comparator == "<" && comparison >= 0))
				return false;
		}
		return true;
	}

	static function parseVersion(value:String):Array<Int> {
		var parts = StringTools.trim(value).split("."), result = [0, 0, 0];
		for (index in 0...3) {
			if (index >= parts.length || parts[index] == "")
				continue;
			var parsed = Std.parseInt(parts[index]);
			if (parsed == null)
				throw 'Invalid semantic version "$value"';
			result[index] = parsed;
		}
		return result;
	}

	static function compare(left:Array<Int>, right:Array<Int>):Int {
		for (index in 0...3)
			if (left[index] != right[index])
				return left[index] < right[index] ? -1 : 1;
		return 0;
	}

	static function optionalString(raw:Dynamic, field:String, path:String):Null<String> {
		var value:Dynamic = Reflect.field(raw, field);
		if (value == null)
			return null;
		if (!Std.isOfType(value, String) || (cast value : String).length == 0)
			throw '$path "$field" must be a non-empty string';
		return cast value;
	}

	static function stringArray(raw:Dynamic, field:String, path:String):Array<String> {
		var value:Dynamic = Reflect.field(raw, field);
		if (value == null)
			return [];
		if (!Std.isOfType(value, Array))
			throw '$path "$field" must be an array of strings';
		var result:Array<String> = [];
		for (item in (cast value : Array<Dynamic>)) {
			if (!Std.isOfType(item, String) || (cast item : String).length == 0)
				throw '$path "$field" must contain only non-empty strings';
			result.push(cast item);
		}
		return result;
	}
}
