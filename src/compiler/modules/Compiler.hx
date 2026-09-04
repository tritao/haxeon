package compiler.modules;

import compiler.Ast;
import compiler.Ast.AstExpression;
import compiler.Ast.AstFunction;
import compiler.Ast.AstStatement;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Lexer;
import compiler.Parser;
import compiler.Source.SourceFile;
import compiler.ir.Ir.IrProgram;
import compiler.ir.IrGenerator;
import compiler.types.Typer;
import compiler.types.TypedAst.TypedProgram;
import compiler.hl.HlCode;
import compiler.hl.HlModuleAssembler;
import compiler.hl.HlPatchWriter;
import compiler.hl.HlRuntimeIdentity;
import haxe.io.Bytes;
import compiler.types.Type.CompilerType;
import compiler.ir.Ir.IrNative;
import compiler.types.TypeRegistry;

typedef NativeFunction = {final name:String; final library:String; final symbol:String; final arguments:Array<CompilerType>; final result:CompilerType;}

typedef CompileResult = {
	final ir:IrProgram;
	final module:HlCode;
	final retyped:Array<String>;
	final regenerated:Array<String>;
	final changedFunctions:Array<Int>;
	final requiresReload:Bool;
	final functionIndices:Map<String, Int>;
	final functionIds:Map<String, Int>;
	final runtimeIdentity:Bytes;
	final revision:Int;
	final patchBytes:Null<Bytes>;
}

class Compiler {
	public final modules:Map<String, ModuleState> = [];

	final graph = new ModuleGraph();
	var assembler:HlModuleAssembler;
	final moduleId:Bytes;

	public final types:TypeRegistry;

	final natives:Map<String, NativeFunction> = [];
	var compiledOnce = false;

	public function new(?identityState:Bytes) {
		if (identityState == null) {
			moduleId = HlRuntimeIdentity.createModuleId();
			assembler = new HlModuleAssembler();
			types = new TypeRegistry();
		} else {
			var identity = HlRuntimeIdentity.decodePersistent(identityState);
			moduleId = identity.moduleId;
			assembler = new HlModuleAssembler(identity.stableIds);
			types = new TypeRegistry(identity.typeState);
		}
	}

	public function exportIdentityState():Bytes
		return HlRuntimeIdentity.encodePersistent(moduleId, assembler.cache.stableIds, types.exportState());

	public function registerNative(name:String, library:String, symbol:String, arguments:Array<CompilerType>, result:CompilerType):Void {
		if (compiledOnce)
			throw "Native registrations are frozen after the first compilation";
		if (natives.exists(name))
			throw 'Native "$name" is already registered';
		natives.set(name, {
			name: name,
			library: library,
			symbol: symbol,
			arguments: arguments.copy(),
			result: result
		});
	}

	public function compact(entryModule:String):CompileResult {
		assembler = new HlModuleAssembler(assembler.cache.stableIds);
		return compile(entryModule);
	}

	public function update(path:String, source:String):ModuleState {
		var name = ModulePath.fromFile(path),
			file = new SourceFile(path, source);
		var state = modules.get(name);
		if (state == null) {
			state = new ModuleState(name, file);
			modules.set(name, state);
		} else
			state.update(file);
		return state;
	}

	public function compile(entryModule:String):CompileResult {
		if (!modules.exists(entryModule))
			throw 'Missing entry module "$entryModule"';
		var names = [for (name in modules.keys()) name];
		names.sort(Reflect.compare);
		var bodyChanged:Map<String, Bool> = [],
			signatureChanged:Map<String, Bool> = [];
		for (name in names)
			parse(modules.get(name), entryModule, bodyChanged, signatureChanged);
		graph.rebuild(modules);
		for (name in names)
			for (dependency in modules.get(name).dependencies)
				if (!modules.exists(dependency)) {
					var state = modules.get(name),
						span = state.source.span(0, state.source.text.length);
					var diagnostic = new Diagnostic("E2001", 'Missing module "$dependency"', span);
					state.diagnostics.push(diagnostic);
					throw new CompileError(diagnostic);
				}

		var functions:Array<AstFunction> = [],
			owners:Map<String, String> = [],
			reverseCalls:Map<String, Array<String>> = [];
		for (name in names) {
			var state = modules.get(name), locals:Map<String, Bool> = [];
			for (fn in state.ast.functions)
				locals.set(fn.name, true);
			for (fn in state.ast.functions) {
				var canonical = canonicalFunction(fn, name, entryModule, locals);
				functions.push(canonical);
				owners.set(canonical.name, name);
				var calls:Map<String, Bool> = [];
				for (statement in canonical.statements)
					scanCalls(statement, calls);
				for (callee in calls.keys()) {
					var callers = reverseCalls.get(callee);
					if (callers == null) {
						callers = [];
						reverseCalls.set(callee, callers);
					}
					callers.push(canonical.name);
				}
			}
		}
		var invalid:Map<String, Bool> = [];
		for (name in bodyChanged.keys())
			invalid.set(name, true);
		var work = [for (name in signatureChanged.keys()) name];
		while (work.length > 0) {
			var changed = work.pop();
			if (invalid.exists(changed)) {} else
				invalid.set(changed, true);
			var callers = reverseCalls.get(changed);
			if (callers != null)
				for (caller in callers)
					if (!invalid.exists(caller))
						work.push(caller);
		}
		var selected:Map<String, Bool> = [];
		for (fn in functions)
			if (invalid.exists(fn.name))
				selected.set(fn.name, true);
		var typedNew:TypedProgram;
		try
			typedNew = Typer.typeSelected({
				packageName: null,
				imports: [],
				classes: [],
				functions: functions
			}, selected, nativeSignatures())
		catch (error:CompileError) {
			for (name in names) {
				var state = modules.get(name);
				if (state.source.path == error.diagnostic.span.file.path)
					state.diagnostics.push(error.diagnostic);
			}
			throw error;
		}
		var retyped = [], regenerated = [];
		var touchedModules:Map<String, Bool> = [];
		for (fn in typedNew.functions) {
			var module = owners.get(fn.name), state = modules.get(module);
			state.typedFunctions.set(fn.name, fn);
			retyped.push(fn.name);
			touchedModules.set(module, true);
			state.irFunctions.set(fn.name, IrGenerator.generateFunction(fn));
			regenerated.push(fn.name);
			var version = state.irVersions.get(fn.name);
			state.irVersions.set(fn.name, version == null ? 1 : version + 1);
		}
		for (module in touchedModules.keys())
			modules.get(module).typeVersion++;
		for (name in names) {
			var state = modules.get(name), valid:Map<String, Bool> = [];
			for (fn in functions)
				if (owners.get(fn.name) == name)
					valid.set(fn.name, true);
			for (cached in state.typedFunctions.keys())
				if (!valid.exists(cached)) {
					state.typedFunctions.remove(cached);
					state.irFunctions.remove(cached);
					state.irVersions.remove(cached);
				}
		}
		retyped.sort(Reflect.compare);
		regenerated.sort(Reflect.compare);
		var cached = [];
		for (fn in functions)
			cached.push(modules.get(owners.get(fn.name)).irFunctions.get(fn.name));
		var ir = IrGenerator.assemble(cached, irNatives());
		var signatureChanges = [for (name in signatureChanged.keys()) name];
		signatureChanges.sort(Reflect.compare);
		var assembly = assembler.assemble(ir, regenerated, signatureChanges);
		compiledOnce = true;
		var patchBytes = assembly.requiresReload
			|| assembly.changedFunctions.length == 0 ? null : HlPatchWriter.encode(assembly.module, moduleId, assembly.changedSlots,
				stableIdsBySlot(assembly.functionIndices), assembly.revision - 1, assembly.revision, assembly.baseInts, assembly.baseFloats,
				assembly.baseStrings, assembly.baseTypes);
		return {
			ir: ir,
			module: assembly.module,
			retyped: retyped,
			regenerated: regenerated,
			changedFunctions: assembly.changedFunctions,
			requiresReload: assembly.requiresReload,
			functionIndices: copyIndices(assembly.functionIndices),
			functionIds: copyIndices(assembler.cache.stableIds),
			runtimeIdentity: HlRuntimeIdentity.encode(moduleId, assembly.functionIndices, assembler.cache.stableIds),
			revision: assembly.revision,
			patchBytes: patchBytes
		};
	}

	function nativeSignatures():Map<String, {arguments:Array<CompilerType>, result:CompilerType}> {
		var result:Map<String, {arguments:Array<CompilerType>, result:CompilerType}> = [];
		for (name => native in natives)
			result.set(name, {arguments: native.arguments, result: native.result});
		return result;
	}

	function irNatives():Array<IrNative> {
		var names = [for (name in natives.keys()) name];
		names.sort(Reflect.compare);
		return [
			for (name in names) {
				var native = natives.get(name);
				{
					name: native.name,
					library: native.library,
					symbol: native.symbol,
					arguments: [for (type in native.arguments) irType(type)],
					result: irType(native.result)
				}
			}
		];
	}

	static function irType(type:CompilerType):compiler.ir.Ir.IrType
		return switch type {
			case TInt: I32;
			case TBool: Bool;
			case TFloat: F64;
			case TString: Bytes;
			case TVoid: Void;
			case TClass(name): throw 'Class type "$name" is not lowered yet';
		};

	function stableIdsBySlot(layout:Map<String, Int>):Map<Int, Int> {
		var result:Map<Int, Int> = [];
		for (name => id in assembler.cache.stableIds)
			if (layout.exists(name))
				result.set(layout.get(name), id);
		return result;
	}

	function parse(state:ModuleState, entry:String, bodyChanged:Map<String, Bool>, signatureChanged:Map<String, Bool>):Void {
		if (state.ast != null)
			return;
		try {
			state.tokens = new Lexer(state.source).tokenize();
			state.ast = new Parser(state.tokens).parseProgram();
			state.parseVersion++;
		} catch (error:CompileError) {
			state.diagnostics.push(error.diagnostic);
			throw error;
		}
		var dependencies:Map<String, Bool> = [];
		if (state.ast.imports != null)
			for (dependency in state.ast.imports)
				dependencies.set(dependency, true);
		for (fn in state.ast.functions)
			for (statement in fn.statements)
				scanStatement(statement, dependencies);
		state.dependencies = [for (name in dependencies.keys()) name];
		state.dependencies.sort(Reflect.compare);
		var signatures:Map<String, String> = [],
			bodies:Map<String, String> = [];
		for (fn in state.ast.functions) {
			var canonical = state.name == entry && fn.name == "main" ? "main" : state.name + "." + fn.name;
			var signature = signatureFingerprint(fn),
				body = state.source.text.substring(fn.span.start, fn.span.end);
			signatures.set(fn.name, signature);
			bodies.set(fn.name, body);
			if (state.signatureFingerprints.get(fn.name) != signature)
				signatureChanged.set(canonical, true);
			else if (state.bodyFingerprints.get(fn.name) != body)
				bodyChanged.set(canonical, true);
		}
		for (old in state.signatureFingerprints.keys())
			if (!signatures.exists(old)) {
				var canonical = state.name == entry && old == "main" ? "main" : state.name + "." + old;
				signatureChanged.set(canonical, true);
			}
		state.signatureFingerprints = signatures;
		state.bodyFingerprints = bodies;
		state.dirty = false;
	}

	static function canonicalFunction(fn:AstFunction, module:String, entry:String, locals:Map<String, Bool>):AstFunction {
		var name = module == entry && fn.name == "main" ? "main" : module + "." + fn.name;
		return {
			name: name,
			arguments: fn.arguments,
			result: fn.result,
			span: fn.span,
			statements: [for (s in fn.statements) canonicalStatement(s, module, entry, locals)]
		};
	}

	static function canonicalStatement(s, module, entry, locals):AstStatement
		return switch s {
			case VarDeclaration(n, t, e, span): VarDeclaration(n, t, canonicalExpression(e, module, entry, locals), span);
			case Assignment(n, e, span): Assignment(n, canonicalExpression(e, module, entry, locals), span);
			case Return(e, span): Return(canonicalExpression(e, module, entry, locals), span);
			case If(c, y, n,
				span): If(canonicalExpression(c, module, entry, locals), [for (x in y) canonicalStatement(x, module, entry, locals)],
					[for (x in n) canonicalStatement(x, module, entry, locals)], span);
			case While(c, b, span): While(canonicalExpression(c, module, entry, locals), [for (x in b) canonicalStatement(x, module, entry, locals)], span);
			case Expression(e, span): Expression(canonicalExpression(e, module, entry, locals), span);
		}

	static function canonicalExpression(e, module, entry, locals):AstExpression
		return switch e {
			case IntegerLiteral(_, _), FloatLiteral(_, _), StringLiteral(_, _), Variable(_, _): e;
			case Add(a, b, s): Add(canonicalExpression(a, module, entry, locals), canonicalExpression(b, module, entry, locals), s);
			case Sub(a, b, s): Sub(canonicalExpression(a, module, entry, locals), canonicalExpression(b, module, entry, locals), s);
			case Mul(a, b, s): Mul(canonicalExpression(a, module, entry, locals), canonicalExpression(b, module, entry, locals), s);
			case Div(a, b, s): Div(canonicalExpression(a, module, entry, locals), canonicalExpression(b, module, entry, locals), s);
			case Less(a, b, s): Less(canonicalExpression(a, module, entry, locals), canonicalExpression(b, module, entry, locals), s);
			case LessEqual(a, b, s): LessEqual(canonicalExpression(a, module, entry, locals), canonicalExpression(b, module, entry, locals), s);
			case Equal(a, b, s): Equal(canonicalExpression(a, module, entry, locals), canonicalExpression(b, module, entry, locals), s);
			case Call(name, args, s):
				var resolved = name;
				if (name.indexOf(".") < 0 && locals.exists(name))
					resolved = module == entry && name == "main" ? "main" : module + "." + name;
				Call(resolved, [for (a in args) canonicalExpression(a, module, entry, locals)], s);
		}

	static function scanStatement(s, dependencies):Void
		switch s {
			case VarDeclaration(_, _, e, _), Assignment(_, e, _), Return(e, _):
				scanExpression(e, dependencies);
			case If(c, y, n, _):
				scanExpression(c, dependencies);
				for (x in y)
					scanStatement(x, dependencies);
				for (x in n)
					scanStatement(x, dependencies);
			case While(c, b, _):
				scanExpression(c, dependencies);
				for (x in b)
					scanStatement(x, dependencies);
			case Expression(e, _):
				scanExpression(e, dependencies);
		}

	static function scanExpression(e, dependencies):Void
		switch e {
			case Add(a, b, _), Sub(a, b, _), Mul(a, b, _), Div(a, b, _), Less(a, b, _), LessEqual(a, b, _), Equal(a, b, _):
				scanExpression(a, dependencies);
				scanExpression(b, dependencies);
			case Call(name, args, _):
				var dot = name.indexOf(".");
				if (dot > 0)
					dependencies.set(name.substr(0, dot), true);
				for (a in args)
					scanExpression(a, dependencies);
			default:
		}

	static function scanCalls(statement:AstStatement, calls:Map<String, Bool>):Void
		switch statement {
			case VarDeclaration(_, _, e, _), Assignment(_, e, _), Return(e, _):
				scanCallExpression(e, calls);
			case If(c, y, n, _):
				scanCallExpression(c, calls);
				for (s in y)
					scanCalls(s, calls);
				for (s in n)
					scanCalls(s, calls);
			case While(c, b, _):
				scanCallExpression(c, calls);
				for (s in b)
					scanCalls(s, calls);
			case Expression(e, _):
				scanCallExpression(e, calls);
		}

	static function scanCallExpression(e:AstExpression, calls:Map<String, Bool>):Void
		switch e {
			case Call(name, args, _):
				calls.set(name, true);
				for (a in args)
					scanCallExpression(a, calls);
			case Add(a, b, _), Sub(a, b, _), Mul(a, b, _), Div(a, b, _), Less(a, b, _), LessEqual(a, b, _), Equal(a, b, _):
				scanCallExpression(a, calls);
				scanCallExpression(b, calls);
			default:
		}

	static function signatureFingerprint(fn:AstFunction):String
		return fn.name + "(" + [for (a in fn.arguments) Std.string(a.type)].join(",") + ")->" + Std.string(fn.result);

	static function owner(name:String, entry:String):String {
		var dot = name.indexOf(".");
		return dot < 0 ? entry : name.substr(0, dot);
	}

	static function copyIndices(source:Map<String, Int>):Map<String, Int> {
		var result:Map<String, Int> = [];
		for (name => index in source)
			result.set(name, index);
		return result;
	}
}
