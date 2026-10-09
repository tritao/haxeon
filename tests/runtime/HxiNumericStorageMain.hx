import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

/** Numeric records need only owned byte storage, including inside pointer-bearing parents. */
class HxiNumericStorageMain {
	static function main():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot(Sys.getCwd() + "/stdlib");
		compiler.addFfiInterface("numeric-storage.hxi", '
interface NumericStorage @target("x86_64-linux-gnu") @library("unused_numeric_storage") {
 struct Point @layout(8,4) { x: i32 @offset(0); y: i32 @offset(4); }
 type PointAlias = Point;
 struct PointList @layout(16,8) {
  values: ptr<const<PointAlias>> @offset(0) @borrowed @length_field("count");
  count: u32 @offset(8);
 }
 struct Sized @layout(8,4) { struct_size: u32 @offset(0) @struct_size; x: i32 @offset(4); }
 struct Batch @layout(16,4) { points: array<PointAlias,2> @offset(0); }
 struct Mixed @layout(40,8) {
  point: PointAlias @offset(0);
  points: array<PointAlias,2> @offset(8);
  data: ptr<const<u8>> @offset(24) @borrowed @length_field("size");
  size: u32 @offset(32);
 }
}');
		var programSource = '
import NumericStorage;
extern class CopyNative {
 @:hlNative("haxeon_runtime", "structCopy")
 static function copy(destination:haxe.io.Bytes, offset:Int, source:haxe.io.Bytes, length:Int):Void;
 @:hlNative("haxeon_runtime", "structCopyPointer")
 static function copyPointer(source:haxe.io.Bytes, pointerOffset:Int, lengthOffset:Int, lengthBytes:Int):haxe.io.Bytes;
 @:hlNative("haxeon_runtime", "structGetRoots")
 static function roots(source:haxe.io.Bytes):Array<haxe.io.Bytes>;
}
function point(x:Int, y:Int):Point { var p = new Point(); p.set_x(x); p.set_y(y); return p; }
function packedList():PointList {
 var packed = new PointBuffer(2);
 packed.set_x(0,20); packed.set_y(0,22);
 packed.set(1,point(7,9));
 var independent = packed.copy(0);
 independent.set_x(999);
 var holder = new PointList();
 holder.set_values_packed(packed);
 return holder;
}
function mixed():Mixed {
 var m = new Mixed();
 var p = point(20,22);
 m.set_point(p);
 m.set_points(0,p);
 m.set_points(1,point(7,9));
 m.set_data_bytes(haxe.io.Bytes.ofString("retained"));
 p.set_x(999);
 return m;
}
function main():Int {
 var overlap = haxe.io.Bytes.ofString("abcdefgh");
 CopyNative.copy(overlap,2,overlap,6);
 if (overlap.toString() != "ababcdef") return 8;
 var tail = haxe.io.Bytes.view(overlap,2,6);
 CopyNative.copy(overlap,0,tail,6);
 if (overlap.toString() != "abcdefef") return 9;
 var empty = haxe.io.Bytes.alloc(0);
 CopyNative.copy(empty,0,empty,0);
 var copyBounds = 0;
 try CopyNative.copy(overlap,3,tail,6) catch (error:Dynamic) copyBounds++;
 try CopyNative.copy(overlap,0,tail,7) catch (error:Dynamic) copyBounds++;
 if (copyBounds != 2) return 10;
 var copySource = haxe.io.Bytes.ofString("12345678");
 var allocatedBefore = hl.Gc.totalAllocated();
 for (i in 0...10000) CopyNative.copy(overlap,0,copySource,8);
 if (hl.Gc.totalAllocated() - allocatedBefore > 1024) return 11;
 if (overlap.toString() != "12345678") return 12;
 var numericBuffer = new PointBuffer(2);
 numericBuffer.set_x(0,20); numericBuffer.set_y(0,22);
 numericBuffer.set(1,point(7,9));
 var packedBounds = 0;
 try numericBuffer.set_x(-1,1) catch (error:Dynamic) packedBounds++;
 try numericBuffer.set_y(2,1) catch (error:Dynamic) packedBounds++;
 try numericBuffer.copy(2) catch (error:Dynamic) packedBounds++;
 try new PointBuffer(-1) catch (error:Dynamic) packedBounds++;
 try new PointBuffer(33554433) catch (error:Dynamic) packedBounds++;
 if (packedBounds != 5) return 13;
 var zeroBuffer = new PointBuffer(0);
 var emptyHolder = new PointList(); emptyHolder.set_values_packed(zeroBuffer);
 if (emptyHolder.get_count() != 0) return 14;
 var sizedBuffer = new SizedBuffer(2);
 if (sizedBuffer.copy(0).get_struct_size() != 8 || sizedBuffer.copy(1).get_struct_size() != 8) return 15;
 var retainedList = packedList();
 var zero = new Point();
 if (zero.get_x() != 0 || zero.get_y() != 0) return 1;
 var source = point(20,22);
 var batch = new Batch();
 batch.set_points(0,source);
 batch.set_points(1,point(7,9));
 var packed:haxe.io.Bytes = Point.array([source,point(7,9)]);
 var attached = Point.__hxi_attach(packed);
 var retained = mixed();
 source.set_x(999);
 var extracted = batch.get_points(0);
 extracted.set_x(555);
 for (round in 0...4) {
  for (i in 0...10000) { var garbage = [i,i+1]; if (garbage.length != 2) return 2; }
  hl.Gc.major();
  if (batch.get_points(0).get_x() != 20 || batch.get_points(1).get_y() != 9) return 3;
  if (attached.get_x() != 20 || attached.get_y() != 22 || packed.getInt32(8) != 7) return 4;
  if (retained.get_point().get_x() != 20 || retained.get_points(1).get_y() != 9) return 5;
  if (retained.get_data_bytes().toString() != "retained") return 6;
  // Verify both the native pointer and the full retained storage after collection.
  var retainedPacked = CopyNative.copyPointer(cast retainedList,0,8,4);
  var retainedStorage = CopyNative.roots(cast retainedList)[1];
  if (retainedList.get_count() != 2 || retainedPacked.get(0) != 20
   || retainedStorage.getInt32(0) != 20 || retainedStorage.getInt32(12) != 9) return 16;
 }
 var bounds = 0;
 try batch.get_points(-1) catch (error:Dynamic) bounds++;
 try batch.set_points(2,source) catch (error:Dynamic) bounds++;
 if (bounds != 2) return 7;
 return 42;
}';
		compiler.update("Main.hx", programSource);
		var result = compiler.compile("Main");
		for (object in result.ir.objects)
			if (StringTools.endsWith(object.name, "PointBuffer") || StringTools.endsWith(object.name, "BatchBuffer"))
				throw "Typed buffers must not introduce per-record runtime object types";
		for (fn in result.ir.functions)
			if (fn.name.indexOf("BatchBuffer.") >= 0)
				throw "Unused buffer helpers must not reach the final program";
		File.saveBytes(Sys.args()[0], HlWriter.encode(result.module));
		// A later compile can demand a previously unused buffer and its methods.
		var replacement = Sys.args().indexOf("--replace-program") >= 0;
		compiler.update("Main.hx", replacement ? 'import NumericStorage;
function main():Int {
 var point = new Point(); point.set_x(42);
 var batch = new Batch(); batch.set_points(0,point);
 var buffer = new BatchBuffer(1); buffer.set(0,batch);
 return buffer.copy(0).get_points(0).get_x();
}' : StringTools.replace(programSource, " if (bounds != 2) return 7;", '
 if (bounds != 2) return 7;
 var batchBuffer = new BatchBuffer(1); batchBuffer.set(0,batch);
 if (batchBuffer.copy(0).get_points(0).get_x() != 20) return 17;
'));
		var incremental = compiler.compile("Main");
		if (replacement && (!incremental.requiresReload || incremental.module.natives.length >= result.module.natives.length))
			throw "Program replacement must exercise a reload with fewer runtime imports";
		if (!Lambda.exists(incremental.ir.functions, fn -> fn.name.indexOf("BatchBuffer.") >= 0))
			throw "A previously unused buffer must become available on demand";
		// Reloads can remove runtime imports, moving every user-function slot.
		// Check the method tables as well as executing the replacement artifact.
		var functionSlots = [for (fn in incremental.module.functions) fn.functionIndex => true];
		for (type in incremental.module.types)
			switch type {
				case Object(_, _, _, _, methods, _), Structure(_, _, _, methods, _):
					for (method in methods)
						if (!functionSlots.exists(method.functionIndex))
							throw "Reload retained a stale object method slot";
				default:
			}
		File.saveBytes(Sys.args()[0] + ".incremental.hl", HlWriter.encode(incremental.module));
		if (replacement)
			File.saveBytes(Sys.args()[0], HlWriter.encode(incremental.module));
	}
}
