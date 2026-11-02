function same(left:Null<Float>, right:Null<Float>):Bool return left == right;
function main():Int {
 var zero = 0.0;
 var nan:Null<Float> = zero / zero;
 var one:Null<Float> = 1.0;
 var none:Null<Float> = null;
 if (same(nan, nan)) return 1;
 if (!same(none, none) || same(none, one) || same(one, none)) return 2;
 if (!same(one, one) || !same(0.0, -0.0)) return 3;
 return 42;
}
