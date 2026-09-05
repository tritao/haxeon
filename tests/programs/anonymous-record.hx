typedef Pair = {
	final left:Int;
	final right:Int;
}

function sum(pair:Pair):Int
	return pair.left + pair.right;

function main():Int
	return sum({left: 20, right: 22});
