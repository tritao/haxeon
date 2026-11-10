package haxeon.ui;

/** Paragraph line-breaking policy. */
enum abstract TextWrap(Int) implements RawRepresentable {
	var None = 0;
	var Word = 1;
	var WordCharacter = 2;
}
