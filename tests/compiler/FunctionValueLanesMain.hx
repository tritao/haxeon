import compiler.backend.Backend.BackendTarget;
import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrObjectTable;
import compiler.ir.IrValueArrayAccess;
import compiler.ir.IrValueArrayFactory;
import compiler.ir.IrValueLaneLayout.IrValueLaneTarget;

/** Independently resolved callback signatures address the same inline value slots. */
class FunctionValueLanesMain {
	static function main():Void {
		var targets:Array<IrValueLaneTarget> = [HashLink, Wasm32, WasmGc];
		for (target in targets) {
			var object:IrObject = {name:"CallbackValue", isValue:true, base:null, interfaces:[], methods:[],
				fields:[{name:"first", type:Function([I32], I32)}, {name:"second", type:Function([I32], I32)}]};
			var objects = IrObjectTable.of([object.name => object]);
			var factory = new IrValueArrayFactory(objects, Obj(object.name), target == HashLink ? 64 : 32, target);
			var copies = factory.helpers.copySlots(["first"], ["second"]);
			if (copies.length != 1) throw "equal function fields must support value copies";
			var builder = new IrBuilder(), index = builder.constInt(0), array = builder.call(factory.allocateName(), [builder.constInt(1)], Array(Obj(object.name)));
			var callback = builder.staticClosure("increment", Function([I32], I32)), access = new IrValueArrayAccess(factory.layout.lanes.scalarWordBits);
			builder.call("__value_array_ensure", [array, index], Void);
			access.write(builder, array, index, factory.layout.lanes.slots[0], callback);
			builder.call("__value_array_mark", [array, index], Void);
			var restored = access.read(builder, array, index, factory.layout.lanes.slots[0]);
			builder.returnValue(builder.callClosure(restored, [builder.constInt(41)], I32));
			var inc = new IrBuilder(), input = inc.argument("input", I32); inc.returnValue(inc.add(input, inc.constInt(1)));
			var program = new IrProgram("main");
			program.objects = [object];
			program.functions = [new IrFunction("main",builder.arguments,I32,builder.blocks), new IrFunction("increment",inc.arguments,I32,inc.blocks)]
				.concat(factory.functions()).concat(factory.helpers.functions());
			var natives:Map<String, IrNative> = [];
			for (native in factory.natives().concat(factory.helpers.natives()).concat(access.natives())) natives.set(native.name,native);
			program.natives = [for (native in natives) native];
			compiler.ir.IrVerifier.verify(program);
			if (target == HashLink) {
				var wrapper=new IrBuilder(), result=wrapper.call("main",[],I32);
				wrapper.call("exit",[result],Void); wrapper.returnValue(wrapper.constVoid());
				program.functions.push(new IrFunction("run",wrapper.arguments,Void,wrapper.blocks));
				program.natives.push({name:"exit",library:"std",symbol:"sys_exit",arguments:[I32],result:Void}); program.entryPoint="run";
				var path="out/function-value-lanes.hl";
				sys.io.File.saveBytes(path,compiler.hl.HlWriter.encode(compiler.ir.hl.HlLower.lower(program)).flatten());
				var process=new sys.io.Process(Sys.getEnv("HAXEON_HASHLINK_DIR") + "/hl",[path]), error=process.stderr.readAll().toString(), status=process.exitCode(); process.close();
				if(status!=42) throw 'HashLink callback lane returned $status: $error';
			} else {
				var backend:BackendTarget=target==Wasm32 ? Wasm32 : WasmGc, path='out/function-value-lanes-$target.wasm';
				sys.io.File.saveBytes(path,new compiler.backend.wasm.WasmBackend().compile(program,{target:backend,debugNames:true}).bytes);
				var js='const fs=require("fs"), e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports; if(e.main()!==42) throw Error("wrong callback");';
				var process=new sys.io.Process("node",["-e",js,path]), error=process.stderr.readAll().toString(), status=process.exitCode(); process.close();
				if(status!=0) throw '$target callback lane failed: $error';
			}
		}
		Sys.println("PASS: equivalent callback signatures share inline value slots on every target");
	}
}
