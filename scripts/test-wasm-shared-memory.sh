#!/usr/bin/env bash
set -euo pipefail
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir=$(mktemp -d)
trap 'rm -rf -- "$build_dir"' EXIT
"$root_dir/.tools/haxe/haxe" --cwd "$root_dir" -cp src -cp tests/compiler --run WasmSharedMemoryMain "$build_dir/shared.wasm" "$build_dir/unshared.wasm"
node - "$build_dir" <<'JS'
const fs=require('fs'),dir=process.argv[2];
const shared=new WebAssembly.Module(fs.readFileSync(dir+'/shared.wasm'));
const unshared=new WebAssembly.Module(fs.readFileSync(dir+'/unshared.wasm'));
new WebAssembly.Instance(shared,{env:{memory:new WebAssembly.Memory({initial:1,maximum:2,shared:true})}});
new WebAssembly.Instance(unshared,{env:{memory:new WebAssembly.Memory({initial:1,maximum:2})}});
for(const [module,memory] of [[shared,new WebAssembly.Memory({initial:1,maximum:2})],[shared,new WebAssembly.Memory({initial:1,maximum:3,shared:true})],[unshared,new WebAssembly.Memory({initial:1,maximum:2,shared:true})]]){
 let rejected=false;try{new WebAssembly.Instance(module,{env:{memory}})}catch(e){if(!(e instanceof WebAssembly.LinkError))throw e;rejected=true}
 if(!rejected)throw Error('Memory contract mismatch admitted');
}
console.log('PASS: shared/unshared imports and bounded memory link validation');
JS
"$root_dir/.tools/haxe/haxe" --cwd "$root_dir" -cp src -main compiler.tools.HaxeonCompiler -hl "$build_dir/compiler.hl"
cat > "$build_dir/contract.json" <<'JSON'
{"name":"nativekit-haxeon-linear-memory","version":1,"address_model":"wasm32","page_size":65536,"host_base":0,"host_limit":1048576,"guest_base":1048576,"guest_limit":4194304,"memory_size":4194304}
JSON
for target in wasm32 wasm-gc; do
  (
    cd "$root_dir"
    export LD_LIBRARY_PATH="$root_dir/out:$root_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export HAXEON_WASM_LEGACY_EXCEPTIONS=1
    for fixture in wasm-host-shared-memory wasm-utf8-field; do
      source_dir=tests/programs
      [[ $fixture == wasm-utf8-field ]] && source_dir=tests/ffi
      exports=("--export=$fixture.callback")
      [[ $fixture == wasm-utf8-field ]] && exports=("--export=$fixture.copy" "--export=$fixture.verify")
      "$root_dir/.tools/hashlink/hl" "$build_dir/compiler.hl" \
        --target="$target" --entry="$fixture" --output="$build_dir/$fixture-$target.wasm" \
        --wasm-import-memory --wasm-shared-memory --wasm-memory-contract="$build_dir/contract.json" \
        --root="$source_dir" "${exports[@]}" "$source_dir/$fixture.hx"
    done
  )
done
node - "$root_dir" "$build_dir" <<'JS'
const fs=require('fs'),vm=require('vm'),[root,dir]=process.argv.slice(2);
vm.runInThisContext(fs.readFileSync(root+'/stdlib/haxeon/wasm/haxeon-host.js','utf8'));
(async()=>{
 for(const target of ['wasm32','wasm-gc']) {
  const memory=new WebAssembly.Memory({initial:64,maximum:64,shared:true});
  const lines=[];let callbackResult=null;
  const {exports,unavailable}=await HaxeonWasmHost.instantiate(new WebAssembly.Module(fs.readFileSync(dir+'/wasm-host-shared-memory-'+target+'.wasm')),{memory,print:x=>lines.push(x),emscripten:{addFunction(fn,signature){if(signature!=='ii')throw Error(signature);callbackResult=fn(7);return 1},removeFunction(token){if(token!==1)throw Error(token)}}});
  if(exports.main()!==42 || lines.join('')!=='冰🙂' || callbackResult!==10 || unavailable.length)throw Error(target+': shared host services failed');
  const p=1024,bytes=new Uint8Array(memory.buffer);bytes.set(new TextEncoder().encode('é🙂\0'),p);
  const field=await HaxeonWasmHost.instantiate(new WebAssembly.Module(fs.readFileSync(dir+'/wasm-utf8-field-'+target+'.wasm')),{memory,emscripten:{}});
  if(field.exports['wasm-utf8-field.copy'](p)!==42)throw Error(target+': UTF-8 field read failed');
  bytes.fill(120,p,p+6);
  if(field.exports['wasm-utf8-field.verify']()!==42)throw Error(target+': UTF-8 field did not copy');
 }
 console.log('PASS: both shared-memory backends, UTF-8 fields, printing, callbacks and math');
})().catch(e=>{console.error(e);process.exitCode=1});
JS
