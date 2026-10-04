import compiler.Compiler;
import compiler.types.Type.CompilerType;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;
import sys.FileSystem;

/** The malformed sequences use stock Haxe/HL results; NUL rejection is the native String contract. */
class BytesAsciiMain {
	static function main():Void {
		var nativePath = "out/bytes_decode_guards.hdll";
		var built = Sys.command("cc", [
			"-shared",
			"-fPIC",
			"-Ivendor/hashlink/src",
			"tests/native/bytes_decode_guards.c",
			"-L.tools/hashlink",
			"-lhl",
			"-o",
			nativePath
		]);
		if (built != 0)
			throw "Could not build byte snapshot guard";
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		compiler.registerNative("armSnapshot", "bytes_decode_guards", "arm", [CompilerType.TBytes], CompilerType.TVoid);
		compiler.registerNative("disarmSnapshot", "bytes_decode_guards", "disarm", [], CompilerType.TInt);
		compiler.update("Main.hx", '
import haxe.io.Bytes;
import haxe.io.BytesInput;
function main():Int {
 var cases:Array<Array<Int>> = [[128,65,66,67],[65,128,66,67],[194,65,66,67],[226,130,65,66],[240,159,65,66]];
 var lengths:Array<Int> = [0,1,0,0,0];
 for (index in 0...cases.length) {
  var bytes = Bytes.alloc(4);
  for (i in 0...4) bytes.set(i,cases[index][i]);
  var text = bytes.toString();
  if (text.length != lengths[index]) return 1;
  if (text.length == 1 && text.charCodeAt(0) != 65) return 2;
 }
 var bytes = Bytes.alloc(4);
 for (i in 0...4) bytes.set(i,65+i);
 bytes.set(1,0);
 var caught = 0;
 try { bytes.toString(); } catch (error:Dynamic) { caught++; }
 try { bytes.getString(0,2); } catch (error:Dynamic) { caught++; }
 var input = new BytesInput(bytes);
 try { input.readString(4); } catch (error:Dynamic) { caught++; }
 if (caught != 3 || input.position != 0) return 3;
 if (bytes.getString(2,2) != "CD") return 4;
 try { bytes.getString(-1,1); } catch (error:Dynamic) { caught++; }
 try { bytes.getString(3,2); } catch (error:Dynamic) { caught++; }
 if (caught != 5) return 5;
 for (length in [1, 60, 128, 129]) {
  var mutable = Bytes.alloc(length);
  for (i in 0...length) mutable.set(i,65);
  armSnapshot(mutable);
  var snapshot = mutable.toString();
  var calls = disarmSnapshot();
  if (calls != 1 || mutable.get(0) != 90 || snapshot.charCodeAt(0) != 65) return 6;
 }
 return 42;
}');
		var path = "out/bytes-ascii-edge.hl";
		File.saveBytes(path, HlWriter.encode(compiler.compile("Main").module));
		var status = Sys.command(".tools/hashlink/hl", [path]);
		FileSystem.deleteFile(path);
		FileSystem.deleteFile(nativePath);
		if (status != 42)
			throw 'byte decoder edge checks failed: $status';
		Sys.println("PASS: malformed UTF-8 fallback, NUL rejection, byte-range bounds and allocation-time snapshots");
	}
}
