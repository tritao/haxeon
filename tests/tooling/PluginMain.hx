using compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.Compiler;
import compiler.compilation.CompilerPublication.ReconnectDecision;
import compiler.core.Diagnostic.CompileError;
import compiler.hl.HlWriter;
import runtime.LoadedPlugin;
import runtime.PatchSet;
import runtime.Runtime;
import runtime.RuntimeDomain;
import sys.io.File;

class PluginMain {
	static final fixtureRoot = "tests/fixtures/pragtical/";

	static function main():Void {
		var output = Sys.args()[0], compiler = new Compiler();
		compiler.enablePublicationTracking();
		loadFixture(compiler, "pragtical/api/Plugin.hx");
		loadFixture(compiler, "pragtical/api/Document.hx");
		var editorSource = loadFixture(compiler, "pragtical/api/Editor.hx");
		loadFixture(compiler, "pragtical/plugins/PluginState.hx");
		var pluginSource = loadFixture(compiler, "pragtical/plugins/SearchPlugin.hx");
		var mainSource = loadFixture(compiler, "Main.hx", "pragtical/app/Main.hx");

		var first = compiler.compile("Main");
		File.saveBytes(output, HlWriter.encode(first.artifact.hashLink().module).flatten());
		if (first.metrics.modules != 6 || first.requiresReload || first.artifact.hashLink().patchBytes != null)
			throw "Initial plugin workload did not compile as a stable module";
		var disposedModules = 0,
			live = Runtime.load(HlWriter.encode(first.artifact.hashLink().module).flatten(),
				first.artifact.hashLink().runtimeIdentity),
			domain = new RuntimeDomain("search", function(module:Dynamic):Void {
				disposedModules++;
				Runtime.dispose(cast module);
			}),
				firstPlugin = loadedPlugin(live, first.artifact.hashLink().functionIds);
		domain.activateWithModule(firstPlugin, live);
		compiler.acknowledgePublication(first.revision);
		if (call(live, first.artifact.hashLink().functionIds, "Main.documentCount") != 1
			|| call(live, first.artifact.hashLink().functionIds, "Main.callbackCount") != 1
			|| call(live, first.artifact.hashLink().functionIds, "Main.runCommand") != 5)
			throw "Initial plugin did not open a document and execute its command callback";

		var patchedSource = StringTools.replace(pluginSource, "state.cursor + 1", "state.cursor + 2");
		compiler.update("pragtical/plugins/SearchPlugin.hx", patchedSource);
		var bodyEdit = compiler.compile("Main");
		if (bodyEdit.requiresReload || bodyEdit.artifact.hashLink().patchBytes == null
			|| bodyEdit.changedFunctions.length == 0)
			throw "Plugin body edit did not produce a compatible patch";
		var pluginPrefix = "pragtical.plugins.SearchPlugin.";
		if (bodyEdit.retyped.length == 0
			|| bodyEdit.metrics.retypedFunctions != bodyEdit.retyped.length
			|| bodyEdit.metrics.regeneratedFunctions != bodyEdit.regenerated.length
			|| bodyEdit.metrics.elapsedMs < 0.0)
			throw 'Plugin body invalidation was broader than expected (${bodyEdit.retyped}/${bodyEdit.metrics.elapsedMs}ms)';
		for (name in bodyEdit.retyped)
			if (bodyEdit.regenerated.indexOf(name) < 0)
				throw 'Plugin body edit did not regenerate invalidated function "$name"';
			else if (!StringTools.startsWith(name, pluginPrefix)
				&& !StringTools.startsWith(name, "$lambda:" + pluginPrefix))
				throw 'Plugin body edit invalidated another module function "$name"';
		Runtime.patchSet(live,
			new PatchSet(first.revision, bodyEdit.revision, bodyEdit.artifact.hashLink().patchBytes,
			bodyEdit.changedFunctions));
		compiler.acknowledgePublication(bodyEdit.revision);
		var patchedCommand = call(live, bodyEdit.artifact.hashLink().functionIds, "Main.runCommand"),
			patchedCursor = call(live, bodyEdit.artifact.hashLink().functionIds, "Main.cursor");
		if (patchedCommand != 7 || patchedCursor != 7)
			throw 'Body patch did not preserve plugin state or update callback behavior ($patchedCommand/$patchedCursor)';
		try {
			Runtime.patchSet(live,
				new PatchSet(first.revision, bodyEdit.revision, bodyEdit.artifact.hashLink().patchBytes,
				bodyEdit.changedFunctions));
			throw "Stale plugin patch unexpectedly succeeded";
		} catch (error:runtime.RuntimeError) {
			if (error.status != runtime.RuntimeStatus.StalePatch)
				throw error;
		}

		var resumed = new Compiler(compiler.exportIdentityState());
		switch resumed.reconcileRuntime(first.artifact.hashLink().runtimeIdentity.sub(4, 16), bodyEdit.revision) {
			case ContinuePatching:
			case ReloadDomain(reason):
				throw 'Plugin compiler reconnect required reload: $reason';
		}
		loadFixture(resumed, "pragtical/api/Plugin.hx");
		loadFixture(resumed, "pragtical/api/Document.hx");
		resumed.update("pragtical/api/Editor.hx", editorSource);
		loadFixture(resumed, "pragtical/plugins/PluginState.hx");
		resumed.update("pragtical/plugins/SearchPlugin.hx", patchedSource);
		resumed.update("Main.hx", mainSource);
		compiler = resumed;

		compiler.update("pragtical/plugins/SearchPlugin.hx",
			StringTools.replace(patchedSource, "public function find():Int", "public function find():Bool"));
		try {
			compiler.compile("Main");
			throw "Invalid plugin edit unexpectedly compiled";
		} catch (error:CompileError) {}
		if (call(live, bodyEdit.artifact.hashLink().functionIds, "Main.cursor") != 7)
			throw "Invalid plugin edit replaced the last good generation";
		compiler.update("pragtical/plugins/SearchPlugin.hx", patchedSource);

		var structuralEditor = StringTools.replace(editorSource, "public var documents:Array<Document>;",
			"public var documents:Array<Document>; public var generation:Int;");
		structuralEditor = StringTools.replace(structuralEditor,
			"this.documents = new Array<pragtical.api.Document>(0);",
			"this.documents = new Array<pragtical.api.Document>(0); this.generation = 2;");
		// An added field alone patches into a reserved slot; a new base class changes the layout every subclass field sits at.
		structuralEditor = StringTools.replace(structuralEditor, "class Editor {",
			"class EditorBase {}\n\nclass Editor extends EditorBase {");
		compiler.update("pragtical/api/Editor.hx", structuralEditor);
		var activationFailureSource = StringTools.replace(mainSource, "searchPlugin.activate();",
			"throw \"activation failed\";");
		compiler.update("Main.hx", activationFailureSource);
		var activationFailure = compiler.compile("Main"),
			activationCandidate = Runtime.load(HlWriter.encode(activationFailure.artifact.hashLink().module).flatten(),
				activationFailure.artifact.hashLink().runtimeIdentity);
		try {
			domain.reloadWithModule(loadedPlugin(activationCandidate,
				activationFailure.artifact.hashLink().functionIds),
				activationCandidate);
			throw "Plugin activation failure unexpectedly published";
		} catch (_:Dynamic) {}
		if (!domain.active || domain.generation != 1 || disposedModules != 1
			|| call(live, bodyEdit.artifact.hashLink().functionIds, "Main.cursor") != 7)
			throw "Plugin activation failure did not recover the previous generation";
		compiler.rejectPublication(activationFailure.revision);

		var restoreFailureSource = StringTools.replace(mainSource, "searchPlugin.restoreState(value);",
			"throw \"restore failed\";");
		compiler.update("Main.hx", restoreFailureSource);
		var restoreFailure = compiler.compile("Main"),
			restoreCandidate = Runtime.load(HlWriter.encode(restoreFailure.artifact.hashLink().module).flatten(),
				restoreFailure.artifact.hashLink().runtimeIdentity);
		try {
			domain.reloadWithModule(loadedPlugin(restoreCandidate, restoreFailure.artifact.hashLink().functionIds),
				restoreCandidate);
			throw "Plugin restore failure unexpectedly published";
		} catch (_:Dynamic) {}
		if (!domain.active || domain.generation != 1 || disposedModules != 2
			|| call(live, bodyEdit.artifact.hashLink().functionIds, "Main.cursor") != 7)
			throw "Plugin restore failure did not retire its callbacks and recover";
		compiler.rejectPublication(restoreFailure.revision);
		compiler.update("Main.hx", mainSource);
		var structural = compiler.compile("Main");
		if (!structural.requiresReload || structural.artifact.hashLink().patchBytes != null)
			throw "Plugin editor-layout edit did not require a domain reload";
		var replacement = Runtime.load(HlWriter.encode(structural.artifact.hashLink().module).flatten(),
			structural.artifact.hashLink().runtimeIdentity),
			replacementPlugin = loadedPlugin(replacement, structural.artifact.hashLink().functionIds);
		domain.reloadWithModule(replacementPlugin, replacement);
		compiler.acknowledgePublication(structural.revision);
		if (domain.generation != 2
			|| replacementPlugin.restoredState != "cursor:7"
			|| call(replacement, structural.artifact.hashLink().functionIds, "Main.cursor") != 7
			|| call(replacement, structural.artifact.hashLink().functionIds, "Main.documentCount") != 1
			|| call(replacement, structural.artifact.hashLink().functionIds, "Main.callbackCount") != 1
			|| disposedModules != 3)
			throw "Structural reload did not restore observable editor/plugin state";

		compiler.update("pragtical/plugins/SearchPlugin.hx",
			StringTools.replace(patchedSource, "state.cursor + 2", "state.cursor + 3"));
		var afterReloadPatch = compiler.compile("Main");
		if (afterReloadPatch.requiresReload || afterReloadPatch.artifact.hashLink().patchBytes == null)
			throw "Post-reload plugin body edit did not produce a patch";
		Runtime.patchSet(replacement,
			new PatchSet(structural.revision, afterReloadPatch.revision,
			afterReloadPatch.artifact.hashLink().patchBytes,
			afterReloadPatch.changedFunctions));
		compiler.acknowledgePublication(afterReloadPatch.revision);
		if (call(replacement, afterReloadPatch.artifact.hashLink().functionIds, "Main.runCommand") != 10)
			throw "Post-reload patch did not retain restored state";
		domain.deactivate();
		if (domain.active || disposedModules != 4)
			throw "Plugin domain remained active after callback unregistration and shutdown";
		Sys.println("PASS: stateful Pragtical facade patched, reloaded, restored, and retired callbacks");
	}

	static function loadFixture(compiler:Compiler, modulePath:String, ?sourcePath:String):String {
		var source = File.getContent(fixtureRoot + (sourcePath == null ? modulePath : sourcePath));
		compiler.update(modulePath, source);
		return source;
	}

	static function loadedPlugin(module:Dynamic, ids:Map<String, Int>):LoadedPlugin
		return new LoadedPlugin(cast module, ids.get("Main.activate"), ids.get("Main.deactivate"),
			ids.get("Main.saveState"), ids.get("Main.restoreState"));

	static function call(module:Dynamic, ids:Map<String, Int>, name:String):Int
		return Runtime.callInt(cast module, ids.get(name));
}
