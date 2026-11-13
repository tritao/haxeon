'use strict';
const fs = require('fs');
const runtime = {
  __math_is_finite: Number.isFinite,
  __math_ceil: Math.ceil,
  __math_floor: Math.floor,
  __math_round: value => Math.floor(value + 0.5) | 0,
  __math_pow: Math.pow,
  __math_sqrt: Math.sqrt,
  __math_fmod: (left, right) => left % right,
  __math_sin: Math.sin,
  __math_cos: Math.cos,
  __math_tan: Math.tan,
  __math_atan2: Math.atan2,
  __math_exp: Math.exp,
  __math_log: Math.log,
  __std_int_f64: Math.trunc
};
const std = {sys_exit: code => { throw new Error(`Unexpected exit ${code}`); }};
WebAssembly.instantiate(fs.readFileSync(process.argv[2]), {haxeon_runtime: runtime, std})
  .then(({instance}) => {
    const result = instance.exports.main();
    if (result !== 42) throw new Error(`Equality guard returned ${result}, expected 42`);
  })
  .catch(error => { console.error(error); process.exitCode = 1; });
