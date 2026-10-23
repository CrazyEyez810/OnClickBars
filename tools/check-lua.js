// Syntax check and list of globals for each addon Lua file.
// Usage: node tools/check-lua.js <file.lua>...
const fs = require('fs'), lp = require('luaparse');
let failed = false;
for (const file of process.argv.slice(2)) {
  try {
    const ast = lp.parse(fs.readFileSync(file, 'utf8'), { luaVersion: '5.1', scope: true });
    const globals = new Set();
    (function walk(n) {
      if (!n || typeof n !== 'object') return;
      if (Array.isArray(n)) return n.forEach(walk);
      if (n.type === 'Identifier' && n.isLocal === false) globals.add(n.name);
      for (const k in n) walk(n[k]);
    })(ast);
    console.log('OK', file, '\n  globals:', [...globals].sort().join(' '));
  } catch (e) { console.log('FAIL', file, e.message); failed = true; }
}
process.exit(failed ? 1 : 0);
