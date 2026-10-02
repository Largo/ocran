// Runs an OCRAN PicoRuby export under Node the way init.iife.js runs it in
// the browser: the module is instantiated from the file, the script named
// by the page's <script type="text/ruby"> tag becomes a task, and the
// scheduler is stepped until it has been idle for a while.
const fs = require("fs");
const path = require("path");
const { pathToFileURL } = require("url");
const site = path.resolve(process.argv[2]);
const html = fs.readFileSync(path.join(site, "index.html"), "utf8");
const script = html.match(/<script type="text\/ruby" src="([^"]+)">/)[1];
const code = fs.readFileSync(path.join(site, script), "utf8");
const bytes = fs.readFileSync(path.join(site, "picoruby.wasm"));
(async () => {
  const { default: createModule } = await import(pathToFileURL(path.join(site, "picoruby.js")).href);
  const Module = await createModule({
    print: (text) => console.log(text),
    printErr: (text) => console.error(text),
    instantiateWasm: (imports, done) => {
      WebAssembly.instantiate(bytes, imports).then((r) => done(r.instance, r.module));
      return {};
    },
  });
  Module.ccall("picorb_init", "number", [], []);
  Module.ccall("picorb_create_task_with_filename", "number", ["string", "string"], [code, script]);
  const step = Module._mrb_run_step_status || (() => (Module._mrb_run_step() < 0 ? -1 : 1));
  const deadline = Date.now() + 30000;
  let idle = 0;
  while (Date.now() < deadline && idle < 50) {
    Module._mrb_tick_wasm();
    const status = step();
    if (status < 0) throw new Error("mrb_run_step_status returned " + status);
    if (status === 0) { idle++; await new Promise((r) => setTimeout(r, 4)); } else idle = 0;
  }
  if (idle < 50) throw new Error("the program did not finish in time");
})().catch((e) => { console.error("FAILED:", e.message || e); process.exit(1); });
