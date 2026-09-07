enum Kind {
	C0;
	C1;
	C2;
	C3;
	C4;
	C5;
	C6;
	C7;
	C8;
	C9;
	C10;
	C11;
	C12;
	C13;
	C14;
	C15;
	C16;
	C17;
	C18;
	C19;
	C20;
	C21;
	C22;
	C23;
}

function render(kind:Kind):String
	return Std.string(kind);

function main():Int
	return render(C23) == "C23" ? 42 : 0;
