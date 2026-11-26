package compiler.semantic;

import compiler.core.QualifiedName;
import compiler.modules.ModuleState;
import compiler.semantic.DeclarationFacts.FactAspect;
import compiler.syntax.Ast;
import compiler.types.analysis.NoReturnDeclarations;
import compiler.types.analysis.PurityAnnotations;
import compiler.types.analysis.PurityInference;
import compiler.types.analysis.ReceiverMutationInference;

/** What one module contributed to the program purity is inferred over: its canonical declarations, as its state holds them. */
private class Contribution {
	public final aliases:Array<AstTypeAlias>;
	public final enums:Array<AstEnum>;
	public final abstracts:Array<AstAbstract>;
	public final interfaces:Array<AstInterface>;
	public final classes:Array<AstClass>;
	public final functions:Array<AstFunction>;

	public function new(state:ModuleState) {
		aliases = state.canonicalAliases;
		enums = state.canonicalEnums;
		abstracts = state.canonicalAbstracts;
		interfaces = state.canonicalInterfaces;
		classes = state.canonicalClasses;
		functions = state.canonicalProgramFunctions;
	}

	/** Whether `state` holds these declarations still: a module made again holds new ones. */
	public function heldBy(state:ModuleState):Bool
		return aliases == state.canonicalAliases && enums == state.canonicalEnums
			&& abstracts == state.canonicalAbstracts && interfaces == state.canonicalInterfaces
			&& classes == state.canonicalClasses && functions == state.canonicalProgramFunctions;
}

/**
 * The program's purity and never-returns answers (`ProgramFacts`), kept for the session and brought up to date by each build in
 * proportion to its edit (`update`). Every copy of the session state shares them: they are taken from whatever program they were
 * last over, and the answers they move (`FactAspect.Purity`, `FactAspect.NoReturn`) only move forward.
 *
 * Purity is the greatest fixpoint `PurityInference.infer` finds: a function whose walk found no direct effect is pure while every
 * function it depends on is. Each function or construction the inference walks is a node, with what its walk found it depends on
 * and the facts the walk read (`PurityDependencyEntry`). A build walks again the nodes of the modules it made again and the nodes
 * that read a fact that changed (found by module, `ReadFilter`); a node whose dependencies come out the same changes nothing. When
 * some do change, the fixpoint is settled again over the nodes that can reach them: those that were impure become pure tentatively
 * where they reach a change through impure nodes, and every node that is found impure makes its pure dependents checked again,
 * which gives the greatest fixpoint again, cycles included. `--check-reuse` compares the answers with `PurityInference.infer`'s.
 */
class ProgramPurity {
	final facts:DeclarationFacts;

	/** The inferred-pure functions and constructions, and the value-class methods that write nothing of their receiver. */
	public var pure(default, null):Map<String, Bool> = [];

	/** The functions declared never to return. */
	public var noReturn(default, null):Map<String, Bool> = [];

	// The program: what each module contributed, and its declarations by name over all of them, the signature table as
	// `SemanticProgram.fillSignatures` makes it. A declaration whose facts did not change may be held as an earlier build made it.
	var contributed:Map<String, Contribution> = [];
	var signatures:Map<String, AstFunction> = [];
	var classes:Map<String, AstClass> = [];
	var interfaces:Map<String, AstInterface> = [];
	var enums:Map<String, AstEnum> = [];
	var abstracts:Map<String, AstAbstract> = [];
	var aliases:Map<String, AstTypeAlias> = [];

	/** The classes held with methods made from other declarations (an implicit constructor, interface accessors). */
	var derivedClasses:Map<String, Bool> = [];

	var inference:Null<PurityInference> = null;

	// The nodes, by id; a node gone keeps its id with role 0. Two nodes stand for sets: every string conversion (`TO_STRING`, which
	// `+` depends on) and every abstract operator (`OPERATORS`), on which every published answer depends.
	var ids:Map<String, Int> = [];
	var names:Array<String> = [];
	var roles:Array<Int> = [];
	var entries:Array<Null<PurityDependencyEntry>> = [];
	var nodePure:Array<Bool> = [];
	var nodeGroups:Array<Int> = [];

	/** The nodes whose dependencies name each function. */
	var dependents:Map<String, Array<Int>> = [];

	var strings:Map<String, Bool> = [];
	var operators:Map<String, Bool> = [];
	var readers = new compiler.query.ReadFilter();
	var groups:Map<String, Int> = [];

	/** The facts' changes the last update was brought up to date with (`DeclarationFacts.changeCount`); -1 for none. */
	var solvedAt = -1;

	/** Whether the declarations are held by name without two of the same name; otherwise each update starts over. */
	var unique = false;

	static inline final OPERATORS = "$operators";

	/** A node's role besides `PurityInference`'s: a construction fact, published when pure. */
	static inline final FRESH = 8;

	/** A node that stands for a set of functions. */
	static inline final SET = 16;

	public function new(facts:DeclarationFacts)
		this.facts = facts;

	/** Forgets everything: the next update starts over. */
	public function clear():Void {
		pure = [];
		noReturn = [];
		reset();
		solvedAt = -1;
	}

	function reset():Void {
		contributed = [];
		signatures = [];
		classes = [];
		interfaces = [];
		enums = [];
		abstracts = [];
		aliases = [];
		derivedClasses = [];
		inference = null;
		ids = [];
		names = [];
		roles = [];
		entries = [];
		nodePure = [];
		nodeGroups = [];
		dependents = [];
		strings = [];
		operators = [];
		readers = new compiler.query.ReadFilter();
		groups = [];
	}

	/**
	 * Brings the answers up to date with the program made of `names`' modules, and moves each answer a typed body read that
	 * changed. `derived` maps each class given methods made from other declarations to the class with them, and `derivedMethods`
	 * names those methods; `owners` gives each function's module (`Class.new` a class's).
	 */
	public function update(modules:Map<String, ModuleState>, names:Array<String>, derived:Map<String, AstClass>,
			derivedMethods:Array<String>, owners:Map<String, String>):Void {
		var changes = solvedAt < 0 || !unique ? null : facts.changesSince(solvedAt);
		solvedAt = facts.changeCount;
		if (readers.full)
			rebuildReaders();
		if (changes == null) {
			solveAnew(modules, names, derived, owners);
			return;
		}
		var changed:Map<Int, Bool> = [for (id in changes) id => true];
		// What arrives and what leaves: every module made again, gone or new, and every class whose made methods changed.
		var present:Map<String, Bool> = [], leaving:Array<String> = [], arriving:Array<String> = [];
		for (name in names) {
			var state = modules.get(name);
			if (state == null)
				continue;
			present.set(name, true);
			var held = contributed.get(name);
			if (held != null && held.heldBy(state))
				continue;
			if (held != null)
				leaving.push(name);
			arriving.push(name);
		}
		for (name in contributed.keys())
			if (!present.exists(name))
				leaving.push(name);
		var touched:Map<String, Bool> = [], touchedClasses:Map<String, Bool> = [];
		var leavingKeys:Map<String, Bool> = [], leavingTypes:Map<String, Bool> = [];
		for (module in leaving) {
			var contribution = contributed.get(module);
			if (contribution == null)
				continue;
			eachKey(contribution, true, key -> {
				leavingKeys.set(key, true);
				return true;
			});
			eachType(contribution, name -> leavingTypes.set(name, true));
			for (decl in contribution.classes)
				touchedClasses.set(decl.name, true);
		}
		for (key in leavingKeys.keys())
			touched.set(key, true);
		// A name declared twice is held as the signature table holds it only when every update starts over.
		var arrivingKeys:Map<String, Bool> = [], arrivingTypes:Map<String, Bool> = [], clash = false;
		for (module in arriving) {
			var contribution = new Contribution(modules.get(module));
			eachKey(contribution, false, key -> {
				if (arrivingKeys.exists(key) || signatures.exists(key) && !leavingKeys.exists(key))
					clash = true;
				arrivingKeys.set(key, true);
				touched.set(key, true);
				return true;
			});
			eachType(contribution, name -> {
				if (arrivingTypes.exists(name) || (isTypeName(name) || aliases.exists(name))
					&& !leavingTypes.exists(name))
					clash = true;
				arrivingTypes.set(name, true);
			});
			for (decl in contribution.classes) {
				touchedClasses.set(decl.name, true);
				var made = derived.get(decl.name);
				if (made != null)
					for (method in made.methods)
						touched.set(decl.name + "." + method.name, true);
			}
		}
		if (clash) {
			solveAnew(modules, names, derived, owners);
			return;
		}
		// A class whose made methods changed is held again: one given them or losing them, or one whose made method's signature
		// goes through a change (an implicit constructor's, through its base's).
		var refreshed:Map<String, Bool> = [];
		for (name in derivedMethods)
			if (changed.exists(facts.existing(FactAspect.Signature, name)))
				refreshed.set(QualifiedName.parentOrEmpty(name), true);
		for (name => declaration in derived)
			if (!derivedClasses.exists(name) || !sameMethodNames(classes.get(name), declaration))
				refreshed.set(name, true);
		for (name in derivedClasses.keys())
			if (!derived.exists(name))
				refreshed.set(name, true);
		var holdAgain = [for (name in refreshed.keys()) if (!touchedClasses.exists(name)) name];
		for (name in holdAgain) {
			touchedClasses.set(name, true);
			var held = classes.get(name);
			if (held != null)
				for (method in held.methods)
					touched.set(name + "." + method.name, true);
			var made = derived.get(name);
			if (made != null)
				for (method in made.methods)
					touched.set(name + "." + method.name, true);
		}
		// A type whose shape changed can change what the functions named under it are taken for (`roleOf`), and the constructions
		// of the classes extending it; those of its own module are touched already.
		var shapes:Map<String, Bool> = [], scalars = false;
		for (id in changes)
			if (facts.aspect(id) == FactAspect.Shape) {
				var name = facts.name(id);
				shapes.set(name, true);
				if (aliases.exists(name) || abstracts.exists(name))
					scalars = true;
			}
		if (shapes.iterator().hasNext()) {
			for (key in signatures.keys())
				if (shapes.exists(QualifiedName.parentOrEmpty(key)))
					touched.set(key, true);
			for (name in classes.keys())
				if (extendsAny(name, shapes))
					touchedClasses.set(name, true);
		}
		var before:Map<String, Bool> = [],
			noReturnBefore:Map<String, Bool> = [],
			annotatedBefore:Map<String, Bool> = [];
		for (key in touched.keys()) {
			remember(before, key);
			remember(before, ReceiverMutationInference.PREFIX + key);
			noReturnBefore.set(key, noReturn.exists(key));
			annotatedBefore.set(key, isAnnotatedPure(key));
		}
		for (name in touchedClasses.keys())
			remember(before, PurityInference.constructorFact(name));

		for (module in leaving)
			forget(module);
		for (name in holdAgain) {
			var made = derived.get(name);
			hold(name, made ?? contributedClass(name, owners), made != null);
		}
		for (module in arriving)
			add(module, modules.get(module), derived);
		for (name in shapes.keys())
			if (aliases.exists(name) || abstracts.exists(name))
				scalars = true;

		var kinds = false;
		for (id in changes)
			if (facts.aspect(id) == FactAspect.Kind)
				kinds = true;
		if (kinds || holdAgain.length > 0)
			inference = newInference();
		var nodesChanged:Map<String, Bool> = [];
		for (key in touched.keys()) {
			walkFunction(key, owners, nodesChanged, false);
			var answer = noReturnOf(key);
			if (answer != noReturnBefore.get(key)) {
				if (answer)
					noReturn.set(key, true);
				else
					noReturn.remove(key);
				var id = facts.existing(FactAspect.NoReturn, key);
				if (id >= 0)
					facts.changed(id);
			}
			if (annotatedBefore.get(key) != isAnnotatedPure(key))
				nodesChanged.set(key, true);
		}
		for (name in touchedClasses.keys())
			walkConstruction(name, owners, nodesChanged, false);
		// The nodes of other modules that read a fact that changed.
		for (group in 0...readers.groups) {
			var hit = false;
			for (id in changes)
				if (readers.mayRead(group, id)) {
					hit = true;
					break;
				}
			if (hit)
				for (node in readers.membersOf(group)) {
					var entry = entries[node];
					if (entry == null || roles[node] & SET != 0 || facts.currentSince(entry.reads, entry.revision))
						continue;
					var name = this.names[node];
					if (roles[node] & FRESH != 0)
						walkConstruction(name.substr(PurityInference.constructorFact("").length), owners, nodesChanged,
							true);
					else
						walkFunction(name, owners, nodesChanged, true);
				}
		}
		updateSets(nodesChanged);
		receivers(scalars ? null : touched, before);
		publish(settle(nodesChanged), before);
		for (name => answer in before)
			if (answerOf(name) != answer) {
				var id = facts.existing(FactAspect.Purity, name);
				if (id >= 0)
					facts.changed(id);
			}
	}

	/** Infers every answer anew, and moves each one a typed body read that it changes. */
	function solveAnew(modules:Map<String, ModuleState>, names:Array<String>, derived:Map<String, AstClass>,
			owners:Map<String, String>):Void {
		var previousPure = pure,
			previousNoReturn = noReturn,
			wasAnnotated = annotatedIn(signatures, classes),
			moves = contributed.iterator().hasNext();
		pure = [];
		noReturn = [];
		reset();
		unique = true;
		// In the signature table's order (`SemanticProgram.fillSignatures`), so that a name declared twice is held as it holds it.
		var states = [for (name in names) if (modules.exists(name)) modules.get(name)];
		var types:Map<String, Bool> = [];
		for (state in states) {
			var contribution = new Contribution(state);
			contributed.set(state.name, contribution);
			eachType(contribution, name -> {
				if (types.exists(name))
					unique = false;
				types.set(name, true);
			});
			for (decl in contribution.aliases)
				aliases.set(decl.name, decl);
			for (decl in contribution.enums)
				enums.set(decl.name, decl);
		}
		for (state in states)
			for (decl in state.canonicalInterfaces) {
				interfaces.set(decl.name, decl);
				for (method in decl.methods)
					claim(decl.name + "." + method.name, method);
			}
		for (state in states)
			for (decl in state.canonicalClasses) {
				var held = derived.get(decl.name) ?? decl;
				if (held != decl)
					derivedClasses.set(decl.name, true);
				classes.set(decl.name, held);
				for (method in held.methods)
					claim(decl.name + "." + method.name, method);
			}
		for (state in states)
			for (decl in state.canonicalAbstracts) {
				abstracts.set(decl.name, decl);
				for (method in decl.methods)
					claim(decl.name + "." + method.name,
						SemanticProgram.withOwnerTypeParameters(method, decl.typeParameters));
			}
		for (state in states)
			for (fn in state.canonicalProgramFunctions)
				claim(fn.name, fn);
		inference = newInference();
		for (key => fn in signatures) {
			walkFunction(key, owners, null, false);
			if (NoReturnDeclarations.has(fn))
				noReturn.set(key, true);
		}
		for (name in classes.keys())
			walkConstruction(name, owners, null, false);
		updateSets(null);
		receivers(null, null);
		publish(settle(null), null);
		if (!moves)
			return;
		facts.forEach(FactAspect.Purity, (id, name) -> {
			if ((previousPure.exists(name) || wasAnnotated(name)) != answerOf(name))
				facts.changed(id);
		});
		facts.forEach(FactAspect.NoReturn, (id, name) -> {
			if (previousNoReturn.exists(name) != noReturn.exists(name))
				facts.changed(id);
		});
	}

	/** Holds `fn` under `key`, noting a name held twice. */
	function claim(key:String, fn:AstFunction):Void {
		if (signatures.exists(key))
			unique = false;
		signatures.set(key, fn);
	}

	/**
	 * Calls `key` with the signature table's key of each function `contribution` declares: a class's methods as the class is held
	 * (with its made methods) when `held`, as contributed otherwise.
	 */
	function eachKey(contribution:Contribution, held:Bool, key:String->Bool):Void {
		for (decl in contribution.interfaces)
			for (method in decl.methods)
				key(decl.name + "." + method.name);
		for (decl in contribution.classes) {
			var holding = held ? classes.get(decl.name) : null;
			for (method in (holding ?? decl).methods)
				key(decl.name + "." + method.name);
		}
		for (decl in contribution.abstracts)
			for (method in decl.methods)
				key(decl.name + "." + method.name);
		for (fn in contribution.functions)
			key(fn.name);
	}

	/** Calls `type` with the name of each type `contribution` declares. */
	static function eachType(contribution:Contribution, type:String->Void):Void {
		for (decl in contribution.aliases)
			type(decl.name);
		for (decl in contribution.enums)
			type(decl.name);
		for (decl in contribution.abstracts)
			type(decl.name);
		for (decl in contribution.interfaces)
			type(decl.name);
		for (decl in contribution.classes)
			type(decl.name);
	}

	/** Drops what module `module` contributed. */
	function forget(module:String):Void {
		var contribution = contributed.get(module);
		if (contribution == null)
			return;
		contributed.remove(module);
		eachKey(contribution, true, key -> signatures.remove(key));
		for (decl in contribution.classes) {
			classes.remove(decl.name);
			derivedClasses.remove(decl.name);
		}
		for (decl in contribution.interfaces)
			interfaces.remove(decl.name);
		for (decl in contribution.abstracts)
			abstracts.remove(decl.name);
		for (decl in contribution.enums)
			enums.remove(decl.name);
		for (decl in contribution.aliases)
			aliases.remove(decl.name);
	}

	/** Holds what module `module` contributes (`state`), its classes as `derived` gives them where it does. */
	function add(module:String, state:ModuleState, derived:Map<String, AstClass>):Void {
		var contribution = new Contribution(state);
		contributed.set(module, contribution);
		for (decl in contribution.aliases)
			aliases.set(decl.name, decl);
		for (decl in contribution.enums)
			enums.set(decl.name, decl);
		for (decl in contribution.interfaces) {
			interfaces.set(decl.name, decl);
			for (method in decl.methods)
				signatures.set(decl.name + "." + method.name, method);
		}
		for (decl in contribution.classes) {
			var made = derived.get(decl.name);
			hold(decl.name, made ?? decl, made != null);
		}
		for (decl in contribution.abstracts) {
			abstracts.set(decl.name, decl);
			for (method in decl.methods)
				signatures.set(decl.name + "." + method.name,
					SemanticProgram.withOwnerTypeParameters(method, decl.typeParameters));
		}
		for (fn in contribution.functions)
			signatures.set(fn.name, fn);
	}

	/** Holds class `declaration` under its name, with its methods, in place of the one held; `made` when given made methods. */
	function hold(name:String, declaration:Null<AstClass>, made:Bool):Void {
		var held = classes.get(name);
		if (held != null)
			for (method in held.methods)
				signatures.remove(name + "." + method.name);
		derivedClasses.remove(name);
		if (declaration == null) {
			classes.remove(name);
			return;
		}
		classes.set(name, declaration);
		for (method in declaration.methods)
			signatures.set(name + "." + method.name, method);
		if (made)
			derivedClasses.set(name, true);
	}

	/** The class `name` as its module contributed it, without methods made from other declarations. */
	function contributedClass(name:String, owners:Map<String, String>):Null<AstClass> {
		var module = owners.get(name + ".new"), contribution = module == null ? null : contributed.get(module);
		if (contribution != null)
			for (decl in contribution.classes)
				if (decl.name == name)
					return decl;
		return null;
	}

	static function sameMethodNames(left:Null<AstClass>, right:AstClass):Bool {
		if (left == null || left.methods.length != right.methods.length)
			return false;
		for (index in 0...left.methods.length)
			if (left.methods[index].name != right.methods[index].name)
				return false;
		return true;
	}

	/** Whether class `name` extends, directly or not, a class in `bases`. */
	function extendsAny(name:String, bases:Map<String, Bool>):Bool {
		var seen:Map<String, Bool> = [], current = classes.get(name);
		while (current != null && current.base != null) {
			var base = switch current.base {
				case NamedType(baseName), AppliedType(baseName, _): baseName;
				default: null;
			};
			if (base == null || seen.exists(base))
				return false;
			if (bases.exists(base))
				return true;
			seen.set(base, true);
			current = classes.get(base);
		}
		return false;
	}

	function newInference():PurityInference
		return PurityInference.create(signatures, classes, enums, isAnnotatedPure, isTypeName);

	function isAnnotatedPure(name:String):Bool
		return PurityAnnotations.isDeclaredPure(name, signatures, classes);

	function isTypeName(name:String):Bool
		return PurityAnnotations.isTypeName(name, classes, interfaces, enums, abstracts);

	static function annotatedIn(signatures:Map<String, AstFunction>, classes:Map<String, AstClass>):String->Bool
		return name -> PurityAnnotations.isDeclaredPure(name, signatures, classes);

	/** The answer a typed body reads for `name` (`TypingSession.isPureCall`). */
	function answerOf(name:String):Bool
		return pure.exists(name) || isAnnotatedPure(name);

	function noReturnOf(name:String):Bool {
		var fn = signatures.get(name);
		return fn != null && NoReturnDeclarations.has(fn);
	}

	/** Keeps `name`'s answer as it is now, the first time it is asked to. */
	function remember(before:Null<Map<String, Bool>>, name:String):Void
		if (before != null && !before.exists(name))
			before.set(name, answerOf(name));

	function nodeOf(name:String):Int {
		var id = ids.get(name);
		if (id == null) {
			id = this.names.length;
			ids.set(name, id);
			this.names.push(name);
			roles.push(0);
			entries.push(null);
			nodePure.push(false);
			nodeGroups.push(-1);
		}
		return id;
	}

	function groupOf(module:Null<String>):Int {
		var key = module ?? "", known = groups.get(key);
		if (known == null) {
			known = readers.groups;
			groups.set(key, known);
			readers.add(known, -1, [], true);
		}
		return known;
	}

	/** Walks function `key` again where what it is taken for or what its walk read changed, or always (`force`). */
	function walkFunction(key:String, owners:Map<String, String>, nodesChanged:Null<Map<String, Bool>>,
			force:Bool):Void {
		var fn = signatures.get(key);
		var role = fn == null ? 0 : inference.roleOf(key, fn, abstracts);
		setNode(key, role, [FactAspect.Signature, key, FactAspect.Body, key], () -> inference.dependenciesOf(fn, key),
			owners.get(key), nodesChanged, force);
	}

	/** Walks the construction of class `name` again where it changed, or always (`force`). */
	function walkConstruction(name:String, owners:Map<String, String>, nodesChanged:Null<Map<String, Bool>>,
			force:Bool):Void {
		var declaration = classes.get(name), fn = signatures.get(name + ".new");
		var role = declaration == null || inference.freshConstructorKey(name) == null || fn != null
			&& fn.isExtern == true
			? 0 : FRESH;
		setNode(PurityInference.constructorFact(name), role, [
			FactAspect.Shape,
			name,
			FactAspect.Members,
			name,
			FactAspect.Signature,
			name + ".new",
			FactAspect.Body,
			name + ".new"
		], () -> inference.constructionDependencies(name, declaration, fn), owners.get(name + ".new"),
			nodesChanged, force);
	}

	/**
	 * Gives node `name` role `role`, walking it (`compute`, its own facts `own`) when it is new, its role changed, what its walk read
	 * changed, or `force`; a node whose role or dependencies changed is put in `nodesChanged`.
	 */
	function setNode(name:String, role:Int, own:Array<Dynamic>, compute:() -> Null<Map<String, Bool>>,
			module:Null<String>, nodesChanged:Null<Map<String, Bool>>, force:Bool):Void {
		var id = ids.get(name);
		if (role == 0) {
			if (id != null && roles[id] != 0) {
				detach(id);
				roles[id] = 0;
				entries[id] = null;
				if (nodesChanged != null)
					nodesChanged.set(name, true);
			}
			return;
		}
		if (id == null)
			id = nodeOf(name);
		var entry = entries[id];
		if (!force && roles[id] == role && entry != null && facts.currentSince(entry.reads, entry.revision))
			return;
		var found = inference.record(facts, own, compute), group = groupOf(module);
		readers.add(group, id, found.reads, nodeGroups[id] == group);
		nodeGroups[id] = group;
		var same = roles[id] == role && entry != null && sameDependencies(entry.dependencies, found.dependencies);
		if (!same)
			detach(id);
		roles[id] = role;
		entries[id] = found;
		if (!same) {
			attach(id);
			if (nodesChanged != null)
				nodesChanged.set(name, true);
		}
	}

	function attach(id:Int):Void {
		var entry = entries[id], needs = entry == null ? null : entry.dependencies;
		if (needs != null)
			for (dependency in needs.keys()) {
				var list = dependents.get(dependency);
				if (list == null)
					dependents.set(dependency, list = []);
				list.push(id);
			}
	}

	function detach(id:Int):Void {
		var entry = entries[id];
		if (entry != null && entry.dependencies != null)
			for (dependency in entry.dependencies.keys()) {
				var list = dependents.get(dependency);
				if (list != null)
					list.remove(id);
			}
	}

	/** Makes the two set nodes depend on the string conversions and the operators there are now, of `nodesChanged` (every node when null). */
	function updateSets(nodesChanged:Null<Map<String, Bool>>):Void {
		var stringsNow = false, operatorsNow = false;
		var changedNames:Iterator<String> = nodesChanged == null ? names.iterator() : nodesChanged.keys();
		for (name in changedNames) {
			var id = ids.get(name), role = id == null ? 0 : roles[id];
			if ((role & PurityInference.STRING != 0) != strings.exists(name)) {
				stringsNow = true;
				role & PurityInference.STRING != 0 ? strings.set(name, true) : strings.remove(name);
			}
			if ((role & PurityInference.OPERATOR != 0) != operators.exists(name)) {
				operatorsNow = true;
				role & PurityInference.OPERATOR != 0 ? operators.set(name, true) : operators.remove(name);
			}
		}
		if (stringsNow || !ids.exists(PurityInference.TO_STRING))
			setSet(PurityInference.TO_STRING, strings, nodesChanged);
		if (operatorsNow || !ids.exists(OPERATORS))
			setSet(OPERATORS, operators, nodesChanged);
	}

	function setSet(name:String, members:Map<String, Bool>, nodesChanged:Null<Map<String, Bool>>):Void {
		var id = nodeOf(name);
		detach(id);
		roles[id] = SET;
		entries[id] = new PurityDependencyEntry(facts.revision, [], [for (member in members.keys()) member => true]);
		attach(id);
		if (nodesChanged != null)
			nodesChanged.set(name, true);
	}

	/** Whether `name` is pure as a dependency: a node in the fixpoint, or else by annotation. */
	inline function valueOf(name:String):Bool {
		var id = ids.get(name);
		return id != null && roles[id] != 0 ? nodePure[id] : isAnnotatedPure(name);
	}

	/**
	 * Settles the greatest fixpoint again after the nodes and names in `changed` changed, from the one before, or from nothing when
	 * null; returns the nodes whose answer moved, with each one's answer before.
	 */
	function settle(changed:Null<Map<String, Bool>>):Map<Int, Bool> {
		var was:Map<Int, Bool> = [], work:Array<Int> = [];
		if (changed == null) {
			// From nothing: every node is pure until it is found impure.
			for (id in 0...names.length)
				if (roles[id] != 0) {
					nodePure[id] = true;
					work.push(id);
				}
			propagate(work, null);
			return was;
		}
		var region:Array<Int> = [], inRegion:Map<Int, Bool> = [];
		// The nodes that can become pure: those that reach a change through impure nodes.
		var queue = [for (name in changed.keys()) name], index = 0;
		for (name in queue) {
			var id = ids.get(name);
			if (id != null && roles[id] != 0 && !inRegion.exists(id)) {
				inRegion.set(id, true);
				region.push(id);
			}
		}
		while (index < queue.length) {
			var list = dependents.get(queue[index++]);
			if (list != null)
				for (id in list)
					if (!inRegion.exists(id) && !nodePure[id]) {
						inRegion.set(id, true);
						region.push(id);
						queue.push(names[id]);
					}
		}
		for (id in region) {
			was.set(id, nodePure[id]);
			nodePure[id] = true;
			work.push(id);
		}
		// What else may be impure now: the dependents of a changed name that is no node, or no longer one.
		for (name in changed.keys()) {
			var id = ids.get(name);
			if (id == null || roles[id] == 0) {
				if (id != null && !was.exists(id)) {
					was.set(id, nodePure[id]);
					nodePure[id] = false;
				}
				var list = dependents.get(name);
				if (list != null)
					for (dependent in list)
						work.push(dependent);
			}
		}
		propagate(work, was);
		for (id => before in was)
			if (before == nodePure[id] && !changed.exists(names[id]))
				was.remove(id);
		return was;
	}

	/**
	 * Makes impure each node of `work` with a dependency that is impure, and each pure node depending on one made impure, keeping
	 * in `was` that it was pure.
	 */
	function propagate(work:Array<Int>, was:Null<Map<Int, Bool>>):Void {
		while (work.length > 0) {
			var id:Int = work.pop() ?? 0;
			var entry = entries[id];
			if (roles[id] == 0 || !nodePure[id] || entry == null)
				continue;
			var needs = entry.dependencies, impure = needs == null;
			if (needs != null)
				for (dependency in needs.keys())
					if (!valueOf(dependency)) {
						impure = true;
						break;
					}
			if (!impure)
				continue;
			if (was != null && !was.exists(id))
				was.set(id, true);
			nodePure[id] = false;
			var list = dependents.get(names[id]);
			if (list != null)
				for (dependent in list)
					if (nodePure[dependent])
						work.push(dependent);
		}
	}

	/**
	 * Publishes the answers of the nodes in `moved` (every node when the operators' answer moved), keeping in `before` each
	 * published answer as it was.
	 */
	function publish(moved:Map<Int, Bool>, before:Null<Map<String, Bool>>):Void {
		var operatorsPure = nodePure[ids.get(OPERATORS)];
		var every = before == null || moved.exists(ids.get(OPERATORS));
		var nodes = every ? [for (id in 0...names.length) id] : [for (id in moved.keys()) id];
		for (id in nodes) {
			var name = names[id],
				answer = operatorsPure && nodePure[id] && roles[id] & (PurityInference.CANDIDATE | FRESH) != 0;
			if (answer == pure.exists(name))
				continue;
			remember(before, name);
			if (answer)
				pure.set(name, true);
			else
				pure.remove(name);
		}
	}

	/**
	 * Decides again which methods write nothing of their value-class receiver, of `names` (every method of a value class when
	 * null, as after a typedef or abstract changed, which decide what a field holds).
	 */
	function receivers(names:Null<Map<String, Bool>>, before:Null<Map<String, Bool>>):Void {
		var keys = names == null ? [
			for (name => declaration in classes)
				if (PurityInference.isValueClass(declaration))
				for (method in declaration.methods)
				name + "." + method.name
		] : [for (name in names.keys()) name];
		if (names == null)
			for (key in pure.keys())
				if (StringTools.startsWith(key, ReceiverMutationInference.PREFIX))
					keys.push(key.substr(ReceiverMutationInference.PREFIX.length));
		for (name in keys) {
			var fn = signatures.get(name), key = ReceiverMutationInference.PREFIX + name;
			var answer = fn != null && PurityInference.readOnlyReceiver(name, fn, classes, abstracts, aliases);
			if (answer == pure.exists(key))
				continue;
			remember(before, key);
			if (answer)
				pure.set(key, true);
			else
				pure.remove(key);
		}
	}

	function rebuildReaders():Void
		readers.rebuild(facts.size() > names.length ? facts.size() : names.length, visit -> {
			for (id in 0...names.length) {
				var entry = entries[id];
				if (entry != null && nodeGroups[id] >= 0)
					visit(nodeGroups[id], id, entry.reads);
			}
			// Every module's group stays, members or not, so that a group's index does not move.
			for (group in groups)
				visit(group, -1, []);
		});

	/**
	 * `--check-reuse`: the answers and what each node was found to depend on are what `PurityInference.infer` finds over
	 * `signatures` and the rest, the tables made anew from the program.
	 */
	public function check(signatures:Map<String, AstFunction>, classes:Map<String, AstClass>,
			interfaces:Map<String, AstInterface>, enums:Map<String, AstEnum>, abstracts:Map<String, AstAbstract>,
			aliases:Map<String, AstTypeAlias>):Void {
		var found:Map<String, Null<Map<String, Bool>>> = [];
		var fresh = PurityInference.infer(signatures, classes, abstracts, aliases, enums,
			annotatedIn(signatures, classes),
			name -> PurityAnnotations.isTypeName(name, classes, interfaces, enums, abstracts), found);
		function fail(message:String):Void
			throw new compiler.core.InternalError("--check-reuse: purity kept across builds " + message);
		for (name in pure.keys())
			if (!fresh.exists(name))
				fail('makes $name pure, which inference anew leaves impure');
		for (name in fresh.keys())
			if (!pure.exists(name))
				fail('leaves $name impure, which inference anew makes pure');
		var freshNoReturn = NoReturnDeclarations.declared(signatures);
		for (name in noReturn.keys())
			if (!freshNoReturn.exists(name))
				fail('says $name never returns');
		for (name in freshNoReturn.keys())
			if (!noReturn.exists(name))
				fail('misses that $name never returns');
		for (name => needs in found) {
			var id = ids.get(name), entry = id == null ? null : entries[id];
			if (id == null || entry == null || roles[id] & SET != 0)
				fail('has no node for $name');
			else if (!sameDependencies(entry.dependencies, needs))
				fail('takes $name to depend on other functions than inference anew');
		}
		for (id in 0...names.length)
			if (roles[id] != 0 && roles[id] & SET == 0 && !found.exists(names[id]))
				fail('has a node for ${names[id]}, which inference anew does not walk');
	}

	static function sameDependencies(left:Null<Map<String, Bool>>, right:Null<Map<String, Bool>>):Bool {
		if (left == null || right == null)
			return left == right;
		var count = 0;
		for (name in left.keys()) {
			if (!right.exists(name))
				return false;
			count++;
		}
		for (_ in right.keys())
			count--;
		return count == 0;
	}
}
