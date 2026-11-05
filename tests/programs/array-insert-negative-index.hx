class InsertOwner {
	public var id:Int;
	public function new(id:Int) this.id=id;
}

function normalized(position:Int, length:Int):Int {
	if(position<0) position+=length;
	if(position<0) return 0;
	return position>length ? length : position;
}

function main():Int {
	for(position in [-1,-3,-4,-2147483647-1,0,2,3,2147483647]) {
		var at=normalized(position,3), ints=[10,20,30], originalInts=ints.copy();
		ints.insert(position,42);
		for(i in 0...4) if(ints[i]!=(i==at ? 42 : originalInts[i<at ? i : i-1])) return 1;
		var floats=[1.25,2.25,3.25], originalFloats=floats.copy();
		floats.insert(position,4.25);
		for(i in 0...4) if(floats[i]!=(i==at ? 4.25 : originalFloats[i<at ? i : i-1])) return 2;
		var bools=[false,false,false]; bools.insert(position,true);
		for(i in 0...4) if(bools[i]!=(i==at)) return 3;
		var strings=["one","two","three"], originalStrings=strings.copy();
		strings.insert(position,"inserted");
		for(i in 0...4) if(strings[i]!=(i==at ? "inserted" : originalStrings[i<at ? i : i-1])) return 4;
		var objects=[new InsertOwner(10),new InsertOwner(20),new InsertOwner(30)], originalObjects=objects.copy(), inserted=new InsertOwner(42);
		objects.insert(position,inserted);
		for(i in 0...4) if(objects[i]!=(i==at ? inserted : originalObjects[i<at ? i : i-1])) return 5;
		var a:Int64=10, b:Int64=20, c:Int64=30, d:Int64=42, wide=[a,b,c], originalWide=wide.copy();
		wide.insert(position,d);
		for(i in 0...4) if(wide[i]!=(i==at ? d : originalWide[i<at ? i : i-1])) return 6;
		var storage=[10,20,30], originalStorage=storage.copy(), view:Array<Dynamic>=cast storage;
		view.insert(position,42);
		for(i in 0...4) if(storage[i]!=(i==at ? 42 : originalStorage[i<at ? i : i-1])) return 7;
	}
	var empty:Array<Int>=[];empty.insert(-1,42);
	return empty.length==1 && empty[0]==42 ? 42 : 8;
}
