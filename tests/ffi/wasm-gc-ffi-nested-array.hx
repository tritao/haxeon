import GcNested;
import haxe.io.Bytes;

// Three levels of borrowed storage, as SceneKit's geometry batch has: an array of records, each borrowing an array
// of records that each borrow bytes. C must see real addresses at every level.
function blob(values:Array<Int>):GcNested.gc_blob {
	var bytes = Bytes.alloc(values.length);
	for (index in 0...values.length)
		bytes.set(index, values[index]);
	var result = new GcNested.gc_blob();
	result.set_data_bytes(bytes);
	return result;
}

function main():Int {
	var first = new GcNested.gc_blob_list();
	first.set_blobs([blob([1, 2]), blob([3])]);
	var second = new GcNested.gc_blob_list();
	second.set_blobs([blob([4, 5, 6]), blob([7, 8]), blob([6])]);
	// 1 + 2 + 3 + 4 + 5 + 6 + 7 + 8 + 6 = 42
	return GcNested.sumBlobs([first, second]);
}
