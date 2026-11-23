// An imported enum's constructor comes before a type of the program with the same name in an expression, as in Haxe:
// `Lambda(3)` is Step's constructor, not the stdlib class Lambda, which keeps the name in type positions.
import ctorscope.Step;

function count(step:Step):Int
	return switch step {
		case Lambda(n): n;
		case List: -1;
	};

function main():Int {
	var made = Lambda(40), listed = List;
	var typed:Step = Lambda(2);
	return count(made) + count(typed) + (count(listed) == -1 ? 0 : 100);
}
