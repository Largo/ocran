// Runs an OCRAN ruby.wasm export under Node: the same module and loader
// the page uses, and the page's own Ruby boot code read from index.html.
const fs = require("fs");
const path = require("path");
const site = path.resolve(process.argv[2]);
globalThis.window = globalThis;
const lib = require(path.join(site, "browser.umd.js"));
const api = lib.DefaultRubyVM ? lib : globalThis["ruby-wasm-wasi"];
const html = fs.readFileSync(path.join(site, "index.html"), "utf8");
const boot = JSON.parse(html.match(/vm\.evalAsync\((".*?")\);/s)[1]);
(async () => {
  const mod = await WebAssembly.compile(fs.readFileSync(path.join(site, "app.wasm")));
  const { vm } = await api.DefaultRubyVM(mod);
  await vm.evalAsync(boot);
})().catch((e) => { console.error("FAILED:", e.message || e); process.exit(1); });
