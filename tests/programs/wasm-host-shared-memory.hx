import haxeon.wasm.HaxeonHost;
function callback(id:Int,value:Int):Int return id+value;
function main():Int {
    Sys.println("冰🙂");
    var value=Math.log(Math.exp(2))+Math.min(-3,1)+Math.max(5,4)+Math.abs(-2);
    if(Math.abs(value-6)>0.000001) return 1;
    var token=HaxeonHost.callback_create("wasm-host-shared-memory.callback","ii",3);
    HaxeonHost.callback_close(token);
    return 42;
}
