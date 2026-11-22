// A structure named only by a local's written type, which no value of it ever has, is still a type of the program: the
// local, a lambda capturing it and a field read through it all name it.
function capturedNull():Int {
	var point:{x:Int} = null;
	var read = () -> point.x;
	try {
		read();
	} catch (e:Dynamic) {
		return 1;
	}
	return 0;
}

function readNull():Int {
	var size:{width:Int, height:Int} = null;
	try {
		return size.width;
	} catch (e:Dynamic) {
		return 1;
	}
}

function declaredLater():Int {
	var label:{text:String};
	label = null;
	var read = () -> label == null ? 1 : 0;
	return read();
}

function nested():Int {
	var rows:Array<{cells:Array<{value:Int}>}> = [null];
	var read = () -> rows[0].cells.length;
	try {
		read();
	} catch (e:Dynamic) {
		return 1;
	}
	return 0;
}

function main():Int
	return (capturedNull() + readNull() + declaredLater() + nested()) * 10 + 2;
