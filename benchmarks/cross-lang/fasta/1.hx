/*
	The Computer Language Benchmarks Game
	http://shootout.alioth.debian.org/
	contributed by Ian Martins
	modified by hanabi1224
 */
class App {
	static function main() {
		var nn = Std.parseInt(Sys.args()[0]);
		var fasta = new Fasta();
		fasta.run(nn);
	}
}

class Fasta {
	private var rnd:Int;

	private var aluChar:String;

	private var iubChar:String;
	private var iubProb:Array<Float>;

	private var homosapiensChar:String;
	private var homosapiensProb:Array<Float>;

	public function new() {
		rnd = 42;

		aluChar = 'GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGG' + 'GAGGCCGAGGCGGGCGGATCACCTGAGGTCAGGAGTTCGAGA' + 'CCAGCCTGGCCAACATGGTGAAACCCCGTCTCTACTAAAAAT'
			+ 'ACAAAAATTAGCCGGGCGTGGTGGCGCGCGCCTGTAATCCCA' + 'GCTACTCGGGAGGCTGAGGCAGGAGAATCGCTTGAACCCGGG' + 'AGGCGGAGGTTGCAGTGAGCCGAGATCGCGCCACTGCACTCC'
			+ 'AGCCTGGGCGACAGAGCGAGACTCCGTCTCAAAAA';

		iubChar = 'acgtBDHKMNRSVWY';
		iubProb = [
			0.27, 0.12, 0.12, 0.27, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02
		];

		homosapiensChar = 'acgt';
		homosapiensProb = [0.3029549426680, 0.1979883004921, 0.1975473066391, 0.3015094502008];
	}

	public function run(nn:Int):Void {
		Sys.println('>ONE Homo sapiens alu');
		repeatFasta(aluChar, nn * 2);

		Sys.println('>TWO IUB ambiguity codes');
		randomFasta(iubChar, iubProb, nn * 3);

		Sys.println('>THREE Homo sapiens frequency');
		randomFasta(homosapiensChar, homosapiensProb, nn * 5);
	}

	public function repeatFasta(src:String, nn:Int) {
		var width = 60;
		var rr = src.length;
		var ss = src + src + src.substr(0, nn % rr);
		var ii = 0;
		for (jj in 0...Std.int(nn / width)) {
			ii = (jj * width) % rr;
			Sys.println(ss.substr(ii, width));
		}

		if ((nn % width) != 0)
			Sys.println(ss.substr(-(nn % width)));
	}

	public function randomFasta(tableChar:String, tableProb:Array<Float>, nn:Int):Void {
		var width = 60;
		var probList = makeCumulative(tableProb);
		var codes = [for (i in 0...tableChar.length) tableChar.charCodeAt(i)];
		var line = haxe.io.Bytes.alloc(width);
		var length = 0;
		for (ii in 0...nn) {
			var pick = bisect(probList, genRandom());
			if (pick >= 0) {
				line.set(length, codes[pick]);
				length++;
			}
			if ((ii + 1) % width == 0) {
				Sys.println(line.getString(0, length));
				length = 0;
			}
		}
		if (nn % width != 0)
			Sys.println(line.getString(0, length));
	}

	private function genRandom():Float {
		rnd = (rnd * 3877 + 29573) % 139968;
		return rnd / 139968;
	}

	private function makeCumulative(tableProb:Array<Float>):Array<Float> {
		var probList = new Array<Float>();
		var prob = 0.0;
		for (ii in 0...tableProb.length) {
			prob += tableProb[ii];
			probList.push(prob);
		}
		return probList;
	}

	// replace this with binary search
	private function bisect(list:Array<Float>, item:Float):Int {
		for (ret in 0...list.length)
			if (item < list[ret])
				return ret;
		return -1;
	}
}
