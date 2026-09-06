/*
 * Copyright (C)2005-2019 Haxe Foundation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

package haxe.ds;

/** Stable in-place merge sort, adapted from the Haxe 4.3.7 standard library. */
class ArraySort {
	public static function sort<T>(a:Array<T>, cmp:(T, T)->Int):Void {
		ArraySort.rec(a, cmp, 0, a.length);
	}

	static function rec<T>(a:Array<T>, cmp:(T, T)->Int, from:Int, to:Int):Void {
		var middle:Int = (from + to) >> 1;
		if (to - from < 12) {
			if (to <= from)
				return;
			for (i in (from + 1)...to) {
				var j:Int = i;
				while (j > from) {
					if (ArraySort.compare(a, cmp, j, j - 1) < 0)
						ArraySort.swap(a, j - 1, j);
					else
						break;
					j--;
				}
			}
			return;
		}
		ArraySort.rec(a, cmp, from, middle);
		ArraySort.rec(a, cmp, middle, to);
		ArraySort.doMerge(a, cmp, from, middle, to, middle - from, to - middle);
	}

	static function doMerge<T>(a:Array<T>, cmp:(T, T)->Int, from:Int, pivot:Int, to:Int, len1:Int, len2:Int):Void {
		var firstCut:Int = 0, secondCut:Int = 0, len11:Int = 0, len22:Int = 0, newMid:Int = 0;
		if (len1 == 0 || len2 == 0)
			return;
		if (len1 + len2 == 2) {
			if (ArraySort.compare(a, cmp, pivot, from) < 0)
				ArraySort.swap(a, pivot, from);
			return;
		}
		if (len1 > len2) {
			len11 = len1 >> 1;
			firstCut = from + len11;
			secondCut = ArraySort.lower(a, cmp, pivot, to, firstCut);
			len22 = secondCut - pivot;
		} else {
			len22 = len2 >> 1;
			secondCut = pivot + len22;
			firstCut = ArraySort.upper(a, cmp, from, pivot, secondCut);
			len11 = firstCut - from;
		}
		ArraySort.rotate(a, firstCut, pivot, secondCut);
		newMid = firstCut + len22;
		ArraySort.doMerge(a, cmp, from, firstCut, newMid, len11, len22);
		ArraySort.doMerge(a, cmp, newMid, secondCut, to, len1 - len11, len2 - len22);
	}

	static function rotate<T>(a:Array<T>, from:Int, mid:Int, to:Int):Void {
		if (from == mid || mid == to)
			return;
		var n:Int = ArraySort.gcd(to - from, mid - from);
		while (n-- != 0) {
			var value:T = a[from + n];
			var shift:Int = mid - from;
			var p1:Int = from + n, p2:Int = from + n + shift;
			while (p2 != from + n) {
				a[p1] = a[p2];
				p1 = p2;
				if (to - p2 > shift)
					p2 += shift;
				else
					p2 = from + (shift - (to - p2));
			}
			a[p1] = value;
		}
	}

	static function gcd(m:Int, n:Int):Int {
		while (n != 0) {
			var temporary:Int = m % n;
			m = n;
			n = temporary;
		}
		return m;
	}

	static function upper<T>(a:Array<T>, cmp:(T, T)->Int, from:Int, to:Int, valueIndex:Int):Int {
		var length:Int = to - from, half:Int = 0, middle:Int = 0;
		while (length > 0) {
			half = length >> 1;
			middle = from + half;
			if (ArraySort.compare(a, cmp, valueIndex, middle) < 0)
				length = half;
			else {
				from = middle + 1;
				length = length - half - 1;
			}
		}
		return from;
	}

	static function lower<T>(a:Array<T>, cmp:(T, T)->Int, from:Int, to:Int, valueIndex:Int):Int {
		var length:Int = to - from, half:Int = 0, middle:Int = 0;
		while (length > 0) {
			half = length >> 1;
			middle = from + half;
			if (ArraySort.compare(a, cmp, middle, valueIndex) < 0) {
				from = middle + 1;
				length = length - half - 1;
			} else
				length = half;
		}
		return from;
	}

	static function swap<T>(a:Array<T>, first:Int, second:Int):Void {
		var temporary:T = a[first];
		a[first] = a[second];
		a[second] = temporary;
	}

	static inline function compare<T>(a:Array<T>, cmp:(T, T)->Int, first:Int, second:Int):Int {
		return cmp(a[first], a[second]);
	}
}
