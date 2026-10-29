package compiler.ir;

import compiler.ir.Ir;

/** One operation on a path from a root that creates, or may create, a heap object. */
typedef AllocationFinding = {
	/**
	 * `alloc` creates a heap object every time it runs. `grow` creates one only when a container's capacity runs out.
	 * `store` is an array store, which allocates only when the index is past the end; bounds are not checked here.
	 * `unknown` is an operation this report does not classify. `dynamic` is a call whose target cannot be resolved.
	 */
	final kind:String;

	final what:String;
	final inFunction:String;
	final path:Null<String>;
	final line:Int;

	/** Function names from the root to `inFunction`, along the shortest path found. */
	final chain:Array<String>;
}

typedef AllocationRootReport = {
	final root:String;
	final reachable:Int;
	final findings:Array<AllocationFinding>;
}

/**
 * Read-only report of what a function can allocate, followed through every call it can reach. It runs on the final
 * post-inline IR, because inlining and scalar replacement are what remove value-class temporaries.
 *
 * Blocks that end in a throw are skipped, since they only build an error. Whether a path runs often is not known: an
 * allocation behind a flag or a rare branch is still reported. Calls to program functions are followed. A method call is followed into every override of the receiver's class, or
 * of every class that implements its interface, unless there are more than `FanOutLimit` of them. A closure's body is followed from the point where the closure is
 * created. Runtime natives are classified by name and signature (`classifyNative`); their implementations were not read.
 *
 * Enable with `HAXEON_IR_ALLOC_ROOTS=Name,Prefix*`: exact IR function names, or a prefix ending in `*`, or `@file` with one
 * pattern per line. Rows are written to stderr as `IR_ALLOC` JSON lines (a compiler server writes them to its log under
 * `~/.cache/haxeon/compiler`). Nothing is mutated and no fingerprint changes.
 */
class IrAllocationReport {
	public static inline var Alloc = "alloc";
	public static inline var Grow = "grow";
	public static inline var Store = "store";
	public static inline var Unknown = "unknown";
	public static inline var Dynamic = "dynamic";

	/** A method call with more implementations than this is a boundary: reported, not followed. A frame root would otherwise reach every widget. */
	public static inline var FanOutLimit = 8;

	public static function report(program:IrProgram):Void {
		var spec = Sys.getEnv("HAXEON_IR_ALLOC_ROOTS");
		if (spec == null || spec == "")
			return;
		// `@path` names a file of patterns, one per line, read on every compile: a compiler server reads its environment once.
		var patterns = StringTools.startsWith(spec, "@") ? sys.io.File.getContent(spec.substr(1)).split("\n") : spec.split(",");
		for (row in analyze(program, patterns))
			Sys.stderr().writeString("IR_ALLOC " + haxe.Json.stringify(row) + "\n");
	}

	public static function analyze(program:IrProgram, patterns:Array<String>):Array<AllocationRootReport> {
		var walker = new Walker(program);
		var roots = [for (fn in program.functions) if (matches(fn.name, patterns)) fn.name];
		roots.sort(Reflect.compare);
		return [for (root in roots) walker.from(root)];
	}

	static function matches(name:String, patterns:Array<String>):Bool {
		for (pattern in patterns) {
			var text = StringTools.trim(pattern);
			if (text.length == 0)
				continue;
			if (StringTools.endsWith(text, "*") ? StringTools.startsWith(name, text.substr(0, text.length - 1)) : name == text)
				return true;
		}
		return false;
	}

	/** How a runtime native relates to the heap, or null when it never allocates. */
	public static function classifyNative(name:String):Null<{kind:String, what:String}> {
		if (!StringTools.startsWith(name, "__"))
			return {kind: Unknown, what: "unresolved call " + name};
		var body = name.substr(2);
		var map = ~/^map_([a-z0-9]+)_([a-z0-9]+)_([a-z]+)$/;
		if (map.match(body))
			return switch map.matched(3) {
				case "alloc", "copy", "keys", "values": {kind: Alloc, what: name};
				case "set": {kind: Grow, what: name};
				// A map of references returns the stored reference; any other value type comes back boxed.
				case "get": map.matched(2) == "ref" ? null : {kind: Alloc, what: name + " (boxes the value)"};
				case "exists", "remove", "clear", "size": null;
				default: {kind: Unknown, what: name};
			};
		if (StringTools.startsWith(body, "array_")) {
			var operation = body.substr(6);
			if (StringTools.startsWith(operation, "alloc_") || StringTools.startsWith(operation, "concat_") || StringTools.startsWith(operation, "copy_")
				|| StringTools.startsWith(operation, "slice_") || StringTools.startsWith(operation, "splice_") || StringTools.startsWith(operation, "join_"))
				return {kind: Alloc, what: name};
			if (StringTools.startsWith(operation, "push_") || StringTools.startsWith(operation, "insert_") || StringTools.startsWith(operation, "unshift_")
				|| StringTools.startsWith(operation, "resize_") || operation == "set_any")
				return {kind: Grow, what: name};
			return null;
		}
		if (StringTools.startsWith(body, "string_buffer_"))
			return switch body {
				case "string_buffer_length": null;
				case "string_buffer_add": {kind: Grow, what: name};
				default: {kind: Alloc, what: name};
			};
		if (StringTools.startsWith(body, "string_"))
			return switch body {
				case "string_length", "string_equal", "string_compare_full", "string_char_code_at", "string_starts_with", "string_ends_with",
					"string_index_of", "string_index_of_from", "string_last_index_of", "string_last_index_of_from", "string_is_space":
					null;
				default: {kind: Alloc, what: name};
			};
		if (body == "std_string")
			return {kind: Alloc, what: name};
		if (StringTools.startsWith(body, "bytes_"))
			return switch body {
				case "bytes_get", "bytes_get_i32", "bytes_get_data", "bytes_set", "bytes_set_i32", "bytes_length", "bytes_compare", "bytes_blit": null;
				default: {kind: StringTools.startsWith(body, "bytes_input_") || StringTools.startsWith(body, "bytes_output_") ? Unknown : Alloc, what: name};
			};
		if (StringTools.startsWith(body, "math_"))
			return null;
		if (StringTools.startsWith(body, "int64_"))
			return body == "int64_compare" || body == "int64_unsigned_compare" ? null : {kind: Unknown, what: name + " (Int64 representation not checked)"};
		if (body == "iterator_new")
			return {kind: Alloc, what: name};
		if (body == "iterator_has_next" || body == "iterator_next_i32" || body == "iterator_next_f64")
			return null;
		switch body {
			case "exit", "dynamic_equal", "f64_to_i64_bits", "i64_to_f64_bits", "std_int_f64", "std_int_dynamic", "std_is_exact_type", "std_is_of_type",
				"std_parse_float", "std_parse_int", "std_random", "exception_matches", "sys_profile_counter", "sys_profile_frame", "sys_profile_span":
				return null;
			default:
		}
		return {kind: Unknown, what: name};
	}
}

private class Walker {
	final byName:Map<String, IrFunction> = [];
	final objects:Map<String, IrObject> = [];
	final children:Map<String, Array<String>> = [];
	final interfaces:Map<String, IrInterface> = [];
	final implementorCache:Map<String, Array<String>> = [];

	public function new(program:IrProgram) {
		for (fn in program.functions)
			byName.set(fn.name, fn);
		for (object in program.objects) {
			objects.set(object.name, object);
			if (object.base != null) {
				var base = Std.string(object.base);
				var list = children.get(base);
				if (list == null)
					children.set(base, list = []);
				list.push(object.name);
			}
		}
		for (declaration in program.interfaces)
			interfaces.set(declaration.name, declaration);
	}

	public function from(root:String):AllocationRootReport {
		var parent:Map<String, Null<String>> = [root => null], queue = [root], findings:Array<AllocationFinding> = [], head = 0;
		var chainTo = function(name:String):Array<String> {
			var chain = [];
			var step:Null<String> = name;
			while (step != null) {
				chain.push(step);
				step = parent.get(step);
			}
			chain.reverse();
			return chain;
		};
		while (head < queue.length) {
			var name = queue[head++], fn = byName.get(name);
			if (fn == null)
				continue;
			var reach = function(target:String):Void {
				if (!parent.exists(target) && byName.exists(target)) {
					parent.set(target, name);
					queue.push(target);
				}
			};
			for (block in fn.blocks) {
				// A block that ends in a throw builds an error and leaves; it does not run on the path being measured.
				if (block.terminator != null)
					switch block.terminator.value {
						case Throw(_), Rethrow(_):
							continue;
						default:
					}
				for (located in block.instructions) {
					var found = function(kind:String, what:String):Void {
						var location = located.provenance.location;
						findings.push({
							kind: kind,
							what: what,
							inFunction: name,
							path: location == null ? null : location.path,
							line: location == null ? 0 : location.line,
							chain: chainTo(name)
						});
					};
					switch located.value {
						case NewObject(_, typeName):
							var object = objects.get(typeName);
							found(IrAllocationReport.Alloc, object != null && object.isValue ? "value-class temporary " + typeName : "new " + typeName);
						case MakeEnum(_, typeName, _, arguments):
							if (arguments.length > 0)
								found(IrAllocationReport.Alloc, "enum " + typeName + " with payload");
						case ToDyn(_, value):
							switch value.type {
								case I32, I64, F32, F64, Bool:
									found(IrAllocationReport.Alloc, "boxes " + Std.string(value.type));
								default:
							}
						case InstanceClosure(_, functionName, _):
							found(IrAllocationReport.Alloc, "closure " + functionName);
							reach(functionName);
						case StaticClosure(_, functionName):
							found(IrAllocationReport.Unknown, "static closure " + functionName + " (allocation not checked)");
							reach(functionName);
						case ToVirtual(_, _):
							found(IrAllocationReport.Unknown, "virtual wrapper (allocation not checked)");
						case IteratorNew(_, _):
							found(IrAllocationReport.Alloc, "iterator");
						case ArraySet(_, _, _):
							found(IrAllocationReport.Store, "array store, grows the array if past the end");
						case CallClosure(_, _, _):
							found(IrAllocationReport.Dynamic, "closure call, target not resolved");
						case CNativeCall(_, functionName, _):
							found(IrAllocationReport.Unknown, "C native " + functionName);
						case Call(_, functionName, _):
							if (byName.exists(functionName))
								reach(functionName);
							else {
								var native = IrAllocationReport.classifyNative(functionName);
								if (native != null)
									found(native.kind, native.what);
							}
						case MethodCall(_, receiver, methodName, _):
							var targets = implementations(receiver, methodName);
							if (targets == null)
								found(IrAllocationReport.Dynamic, "method call " + methodName + ", target not resolved");
							else if (targets.length > IrAllocationReport.FanOutLimit)
								found(IrAllocationReport.Dynamic, "method call " + methodName + ", " + targets.length + " implementations, not followed");
							else
								for (target in targets)
									reach(target);
						default:
					}
				}
			}
		}
		var reachable = 0;
		for (_ in parent)
			reachable++;
		return {root: root, reachable: reachable, findings: findings};
	}

	/** Every function a method call can reach, or null when the receiver does not name a class or interface in the program. */
	function implementations(receiver:IrValue, method:String):Null<Array<String>> {
		var classes:Array<String>;
		switch receiver.type {
			case Obj(name):
				classes = withDescendants([name]);
			case Virtual(name):
				classes = implementors(name);
			default:
				return null;
		}
		var result:Array<String> = [];
		for (name in classes) {
			var implementation = implementationIn(name, method);
			if (implementation != null && result.indexOf(implementation) < 0)
				result.push(implementation);
		}
		return result.length == 0 ? null : result;
	}

	function implementationIn(typeName:String, method:String):Null<String> {
		var name:Null<String> = typeName, steps = 0;
		while (name != null && steps < 64) {
			var descriptor = objects.get(name);
			if (descriptor == null)
				return null;
			for (candidate in descriptor.methods)
				if (candidate.name == method)
					return candidate.functionName;
			name = descriptor.base == null ? null : Std.string(descriptor.base);
			steps++;
		}
		return null;
	}

	function withDescendants(start:Array<String>):Array<String> {
		var seen:Map<String, Bool> = [], order:Array<String> = [], work = start.copy();
		while (work.length > 0) {
			var name = work.pop();
			if (seen.exists(name))
				continue;
			seen.set(name, true);
			order.push(name);
			var list = children.get(name);
			if (list != null)
				for (child in list)
					work.push(child);
		}
		return order;
	}

	/** Classes that implement an interface, directly or through one that extends it, with their subclasses. */
	function implementors(interfaceName:String):Array<String> {
		var known = implementorCache.get(interfaceName);
		if (known != null)
			return known;
		var names:Map<String, Bool> = [interfaceName => true], changed = true;
		while (changed) {
			changed = false;
			for (name => declaration in interfaces)
				if (!names.exists(name))
					for (base in declaration.bases)
						if (names.exists(base)) {
							names.set(name, true);
							changed = true;
							break;
						}
		}
		var direct:Array<String> = [];
		for (name => object in objects)
			for (implemented in object.interfaces)
				if (names.exists(implemented)) {
					direct.push(name);
					break;
				}
		direct.sort(Reflect.compare);
		var result = withDescendants(direct);
		implementorCache.set(interfaceName, result);
		return result;
	}
}
