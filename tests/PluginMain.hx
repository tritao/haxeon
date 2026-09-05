import compiler.hl.HlWriter;
import compiler.modules.Compiler;
import runtime.PatchSet;
import runtime.LoadedPlugin;
import runtime.RuntimeDomain;
import runtime.Runtime;
import sys.io.File;

class PluginMain {
	static function main():Void {
		var output = Sys.args()[0], compiler = new Compiler();
		compiler.update("pragtical/api/Editor.hx",
			"package pragtical.api; import pragtical.api.Plugin; class Editor { public var commands:Array<String>; public var counts:Map<String, Int>; public function new():Void { this.commands = new Array<String>(0); this.counts = new Map<String, Int>(); } public function register(name:String):Void { this.commands.push(name); this.counts[name] = this.commands.length; } public function commandCount():Int { return this.commands.length; } }");
		compiler.update("pragtical/api/Plugin.hx", "package pragtical.api; interface Plugin { function activate():Void; function deactivate():Void; }");
		compiler.update("pragtical/plugins/PluginState.hx",
			"package pragtical.plugins; class PluginState { public var activations:Int; public function new():Void { this.activations = 0; } public function bump():Void { this.activations = this.activations + 1; } }");
		var pluginSource = "package pragtical.plugins; import pragtical.api.Editor; import pragtical.api.Plugin; import pragtical.plugins.PluginState; class SearchPlugin implements Plugin { final editor:Editor; final state:PluginState; public function new(editor:Editor):Void { this.editor = editor; this.state = new PluginState(); } public function activate():Void { var callback = () -> { return; }; callback(); callback(); this.editor.register(\"find\"); this.editor.register(\"find\"); this.state.bump(); } public function deactivate():Void { this.editor.register(\"deactivate\"); } public function score():Int { return this.editor.commandCount() + this.state.activations; } }";
		compiler.update("pragtical/plugins/SearchPlugin.hx", pluginSource);
		compiler.update("Main.hx",
			"package pragtical.app; import pragtical.api.Editor; import pragtical.plugins.SearchPlugin; function activate():Void { return; } function deactivate():Void { return; } function saveState():String { return \"cursor:4\"; } function restoreState(state:String):Void { if (state != \"cursor:4\") return; return; } function main():Int { var editor = new Editor(); var plugin = new SearchPlugin(editor); plugin.activate(); if (editor.commands.length != 2 || editor.counts[\"find\"] != 2 || plugin.score() != 3) return 0; return 42; }");
		var first = compiler.compile("Main");
		File.saveBytes(output, HlWriter.encode(first.module));
		if (first.metrics.modules != 5 || first.requiresReload || first.patchBytes != null)
			throw "Initial plugin workload did not compile as a stable module";
		var mainId = first.functionIds.get("main"),
			live = Runtime.load(HlWriter.encode(first.module), first.runtimeIdentity);
		var domain = new RuntimeDomain("search", function(module:Dynamic):Void Runtime.dispose(cast module));
		var firstPlugin = new LoadedPlugin(live, first.functionIds.get("Main.activate"), first.functionIds.get("Main.deactivate"),
			first.functionIds.get("Main.saveState"), first.functionIds.get("Main.restoreState"));
		domain.activateWithModule(firstPlugin, live);
		if (Runtime.callInt(live, mainId) != 42)
			throw "Initial plugin module did not execute through the live runtime";
		compiler.update("pragtical/plugins/SearchPlugin.hx",
			StringTools.replace(pluginSource, "callback(); callback();", "callback(); callback(); callback();"));
		var bodyEdit = compiler.compile("Main");
		if (bodyEdit.requiresReload || bodyEdit.patchBytes == null || bodyEdit.changedFunctions.length == 0)
			throw "Plugin body edit did not produce a compatible patch";
		Runtime.patchSet(live, new PatchSet(first.revision, bodyEdit.revision, bodyEdit.patchBytes, bodyEdit.changedFunctions));
		if (Runtime.callInt(live, mainId) != 42)
			throw "Patched plugin module did not execute through the live runtime";

		compiler.update("pragtical/api/Editor.hx",
			"package pragtical.api; import pragtical.api.Plugin; class Editor { public var commands:Array<String>; public var counts:Map<String, Int>; public var generation:Int; public function new():Void { this.commands = new Array<String>(0); this.counts = new Map<String, Int>(); this.generation = 1; } public function register(name:String):Void { this.commands.push(name); this.counts[name] = this.commands.length; } public function commandCount():Int { return this.commands.length; } }");
		var structural = compiler.compile("Main");
		if (!structural.requiresReload || structural.patchBytes != null)
			throw "Plugin class-layout edit did not require a domain reload";
		var replacement = Runtime.load(HlWriter.encode(structural.module), structural.runtimeIdentity);
		var replacementPlugin = new LoadedPlugin(replacement, structural.functionIds.get("Main.activate"), structural.functionIds.get("Main.deactivate"),
			structural.functionIds.get("Main.saveState"), structural.functionIds.get("Main.restoreState"));
		domain.reloadWithModule(replacementPlugin, replacement);
		if (domain.generation != 2 || replacementPlugin.restoredState != "cursor:4")
			throw "Plugin structural reload did not migrate lifecycle state";
		if (Runtime.callInt(replacement, structural.functionIds.get("main")) != 42)
			throw "Reloaded plugin module did not execute through the live runtime";
		domain.deactivate();
		if (domain.active)
			throw "Plugin domain remained active after deactivation";
		Sys.println("PASS: representative multi-module plugin workload compiled, patched, and classified");
	}
}
