package tools;

import build.BuildScope;
import build.BuildSession;
import build.HaxeonProjectBuild;
import build.Target;
import compiler.core.InternalError;
import haxe.Json;
import haxe.io.Bytes;
import haxe.io.BytesOutput;
import haxe.io.Path;
import project.ResolvedProject;
import project.ShaderInputs;
import sys.FileSystem;
import sys.io.File;

/** A compiled edit: what is sent to the device, and the baseline that becomes current if the device applies it. */
typedef AndroidEdit = {
	final kind:String;
	final payload:Bytes;
	final baseline:String;
}

/**
 * `haxeon run --target android --watch`: once the app is installed and running, each saved edit of the project's sources is
 * compiled by the structured build against the baseline the device's module was built from (`app.hl.hcs`, which the build
 * wrote beside the module) and sent to the app's patch port through `adb forward`: a body patch when the edit allows one, a
 * domain reload otherwise. The new baseline is kept only when the device applies it, so a rejected edit leaves the next one
 * compiled against what the device runs.
 *
 * The edit is compiled into `edit/` beside the module, by the compiler worker that built the module: while the baseline is
 * the one that worker last wrote, it builds on what it holds instead of loading the baseline again.
 */
class AndroidWatch {
	/** The loopback port the Android host (MainActivity) serves; forwarded to the same port here. */
	static inline final PATCH_PORT = 39817;

	public static function run(home:String, project:ResolvedProject, target:Target, module:String,
			defines:Array<String>,
			jobs:Int, selfHosted:Bool, session:Null<BuildSession>, adb:String, device:String):Int {
		var port = Std.string(PATCH_PORT);
		if (Sys.command(adb, ["-s", device, "forward", 'tcp:$port', 'tcp:$port']) != 0)
			throw new InternalError('Could not forward the patch port $port to $device');
		var files = WatchRun.snapshot(project, target), watcher = WatchRun.openWatcher(project, files);
		Sys.println('Watching ${project.rootPackage.name} for edits; each is sent to $device (Ctrl-C stops)');
		while (true) {
			if (watcher != null) {
				var notified = watcher.wait(WatchRun.POLL_SECONDS);
				if (session != null)
					session.keepWorkersAlive();
				if (notified)
					WatchRun.coalesce(watcher);
				else if (ShaderInputs.roots(project).length == 0)
					continue;
			} else {
				Sys.sleep(WatchRun.POLL_SECONDS);
				if (session != null)
					session.keepWorkersAlive();
			}
			var current = WatchRun.snapshot(project, target);
			if (WatchRun.same(files, current))
				continue;
			files = current;
			var edit = compile(home, project, target, module, defines, jobs, selfHosted, session);
			if (edit != null)
				send(edit, module + ".hcs");
		}
	}

	/** Where an edit of `module` is compiled. */
	public static function editPath(module:String):String
		return Path.join([Path.directory(module), "edit", Path.withoutDirectory(module)]);

	/**
	 * Compiles the sources as they are now against the baseline into a patch or a reload bundle, with the next baseline beside
	 * it; null when the edit did not compile or changed nothing the device runs.
	 */
	public static function compile(home:String, project:ResolvedProject, target:Target, module:String,
			defines:Array<String>, jobs:Int, selfHosted:Bool, session:Null<BuildSession>):Null<AndroidEdit> {
		var baseline = module + ".hcs", output = editPath(module);
		if (!FileSystem.exists(baseline))
			throw new InternalError('No Android baseline at $baseline: build and install the app first');
		// What the last edit left would describe this one if it changed nothing.
		for (suffix in [
			"",
			".hli",
			".hlp",
			".hcs",
			".entry",
			".live.json",
			".live.patch.json",
			".live.stamp",
			".live.full"
		])
			if (FileSystem.exists(output + suffix))
				FileSystem.deleteFile(output + suffix);
		var status = try HaxeonProjectBuild.build(project, home, output, defines, jobs, false, false, false, 0.0,
			selfHosted, CompilerOnly, false, false, session, true, target, baseline) catch (error:Dynamic) {
				Sys.stderr().writeString("haxeon: " + Std.string(error) + "\n");
				1;
			};
		if (status != 0) {
			Sys.println("haxeon: the edit did not compile; fix it and save again");
			return null;
		}
		var description:Dynamic = Json.parse(File.getContent(output + ".live.json"));
		if (description.requiresReload == true) {
			var bundle = reloadBundle(File.getBytes(output), File.getBytes(output + ".hli"),
				Std.parseInt(StringTools.trim(File.getContent(output + ".entry"))));
			Sys.println('compiled Android reload revision ${description.revision} (${bundle.length} bytes)');
			return {kind: "reload", payload: bundle, baseline: output + ".hcs"};
		}
		if (description.patchAvailable == true) {
			var patch = File.getBytes(output + ".hlp");
			Sys.println('compiled Android patch revision ${description.revision} (${patch.length} bytes)');
			return {kind: "patch", payload: patch, baseline: output + ".hcs"};
		}
		return null; // nothing the device runs changed
	}

	/** Sends the edit; the device's acknowledgement makes its baseline the one the next edit compiles against. */
	static function send(edit:AndroidEdit, baseline:String):Void {
		var reply = try exchange(edit.payload) catch (error:Dynamic) {
			Sys.println('haxeon: could not send the ${edit.kind}: $error (is the app running?)');
			FileSystem.deleteFile(edit.baseline);
			return;
		};
		if (reply.status == 0) {
			if (FileSystem.exists(baseline))
				FileSystem.deleteFile(baseline);
			FileSystem.rename(edit.baseline, baseline);
			Sys.println('applied the ${edit.kind}; the device runs revision ${reply.revision}');
		} else {
			FileSystem.deleteFile(edit.baseline);
			Sys.println('haxeon: the device rejected the ${edit.kind} (status ${reply.status}); it still runs revision ${reply.revision}');
		}
	}

	/** HXR v1: magic, version, then little-endian HLB and HLI lengths and the main stable ID, then the HLB and the HLI. */
	public static function reloadBundle(module:Bytes, identity:Bytes, entry:Int):Bytes {
		var output = new BytesOutput();
		output.bigEndian = false;
		output.writeString("HXR");
		output.writeByte(1);
		output.writeInt32(module.length);
		output.writeInt32(identity.length);
		output.writeInt32(entry);
		output.write(module);
		output.write(identity);
		return output.getBytes();
	}

	/** The host's protocol: a big-endian length and the artifact; it answers with its status and its revision. */
	static function exchange(payload:Bytes):{status:Int, revision:Int} {
		var socket = new sys.net.Socket();
		socket.setTimeout(30);
		try {
			socket.connect(new sys.net.Host("127.0.0.1"), PATCH_PORT);
			socket.output.bigEndian = true;
			socket.output.writeInt32(payload.length);
			socket.output.write(payload);
			socket.output.flush();
			socket.input.bigEndian = true;
			var status = socket.input.readInt32(), revision = socket.input.readInt32();
			socket.close();
			return {status: status, revision: revision};
		} catch (error:haxe.Exception) {
			socket.close();
			throw error;
		}
	}
}
