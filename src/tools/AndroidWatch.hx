package tools;

import haxe.io.Bytes;
import haxe.io.Path;
import project.ResolvedProject;
import sys.FileSystem;
import sys.io.File;

/**
 * `haxeon run --target android --watch`: once the app is installed and running, each saved edit of the project's sources is
 * compiled against the baseline the device's module was built from (`tools.AndroidBuild edit`) and sent to the app's patch
 * port through `adb forward`: a body patch when the edit allows one, a domain reload otherwise. The new baseline is kept only
 * when the device applies it, so a rejected edit leaves the next one compiled against what the device runs.
 *
 * The compiler runs as its own program from the tool cache, not inside the CLI, which it would make slow to start.
 */
class AndroidWatch {
	/** The loopback port the Android host (MainActivity) serves; forwarded to the same port here. */
	static inline final PATCH_PORT = 39817;

	public static function run(home:String, projectConfigPath:String, project:ResolvedProject, adb:String,
			device:String):Int {
		var asset = Path.join([home, "android", "app", "src", "main", "assets", "app.hl"]),
			port = Std.string(PATCH_PORT);
		if (Sys.command(adb, ["-s", device, "forward", 'tcp:$port', 'tcp:$port']) != 0)
			throw 'Could not forward the patch port $port to $device';
		var files = WatchRun.snapshot(project), watcher = WatchRun.openWatcher(project, files);
		Sys.println('Watching ${project.rootPackage.name} for edits; each is sent to $device (Ctrl-C stops)');
		while (true) {
			if (watcher != null) {
				if (!watcher.wait(3600))
					continue;
				WatchRun.coalesce(watcher);
			} else
				Sys.sleep(WatchRun.POLL_SECONDS);
			var current = WatchRun.snapshot(project);
			if (WatchRun.same(files, current))
				continue;
			files = current;
			apply(home, projectConfigPath, asset);
		}
	}

	/** Compiles the edit and sends it; a failure is reported and the watch goes on. */
	static function apply(home:String, projectConfigPath:String, asset:String):Void {
		var previous = Sys.getCwd();
		Sys.setCwd(home);
		var status = new tools.dev.ToolArtifacts(home).run({main: "tools.AndroidBuild", classPaths: [], defines: []},
			[
				"edit",
				"--project",
				projectConfigPath,
				asset
			]);
		Sys.setCwd(previous);
		if (status != 0) {
			Sys.println("haxeon: the edit did not compile; fix it and save again");
			return;
		}
		var stem = asset.substr(0, asset.length - ".hl".length),
			baseline = stem + ".hcs",
			pending = baseline + ".pending",
			artifact = FileSystem.exists(stem + ".hlp") ? stem + ".hlp" : FileSystem.exists(stem + ".hxr")
				? stem + ".hxr" : null;
		if (artifact == null)
			return; // nothing the device runs changed
		var kind = StringTools.endsWith(artifact, ".hlp") ? "patch" : "reload",
			reply = try send(File.getBytes(artifact)) catch (error:Dynamic) {
				Sys.println('haxeon: could not send the $kind: $error (is the app running?)');
				FileSystem.deleteFile(pending);
				return;
			};
		if (reply.status == 0) {
			FileSystem.rename(pending, baseline);
			Sys.println('applied the $kind; the device runs revision ${reply.revision}');
		} else {
			FileSystem.deleteFile(pending);
			Sys.println('haxeon: the device rejected the $kind (status ${reply.status}); it still runs revision ${reply.revision}');
		}
	}

	/** The host's protocol: a big-endian length and the artifact; it answers with its status and its revision. */
	static function send(payload:Bytes):{status:Int, revision:Int} {
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
		} catch (error:Dynamic) {
			socket.close();
			throw error;
		}
	}
}
