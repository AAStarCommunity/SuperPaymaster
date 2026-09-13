// D5 gate G1 — our own geth-style JS tracer for the §3.4 line-by-line check.
// It is run by g1-proxy.mjs on EXACTLY the debug_traceCall request a bundler sent for its
// validation simulation (same call object, same block, same state overrides — only the
// `tracer` field is swapped), so it sees the same execution the bundler's tracer saw.
//
// Unlike the bundlers' tracers (which merge TLOAD/TSTORE into reads/writes, OP-070), it keeps
// the four storage opcodes apart, tracks every call frame (type, from, to, storage context,
// selector), attributes each frame to the validation phase that the EntryPoint opened
// (factory via SenderCreator / account.validateUserOp / paymaster.validatePaymasterUserOp),
// records banned opcodes per frame, and collects KECCAK256 preimages so slots can be mapped
// back to `variable[key]` offline (script/b-layer/access-check.mjs).
//
// Phase detection works for both call shapes seen here:
//   Rundler v0.11.0: debug_traceCall(to = EntryPoint, code overridden with EntryPointSimulations)
//   Alto v1.2.5:     debug_traceCall(to = PimlicoEntryPointSimulations) → EP.delegateAndRevert
//                    → DELEGATECALL EntryPointSimulations (storage context stays = EntryPoint)
// A CALL/STATICCALL whose CALLER's storage context is the EntryPoint opens a phase.

export function g1TracerSource(entryPoint) {
    const ep = entryPoint.toLowerCase();
    return `{
  EP: "${ep}",
  frames: [], acc: [], ops: [], kec: [], stack: [], phases: [], nextId: 0, lastOp: "",
  BANNED: {TIMESTAMP:1,NUMBER:1,ORIGIN:1,GASPRICE:1,BLOCKHASH:1,COINBASE:1,DIFFICULTY:1,PREVRANDAO:1,
    BASEFEE:1,GASLIMIT:1,SELFBALANCE:1,BALANCE:1,BLOBHASH:1,BLOBBASEFEE:1,SELFDESTRUCT:1,INVALID:1,
    CREATE:1,CREATE2:1},
  hex: function(b) { return toHex(b); },
  top: function() { return this.stack.length ? this.stack[this.stack.length - 1] : null; },
  ensureRoot: function(log) {
    if (this.stack.length) return;
    var a = toHex(log.contract.getAddress()).toLowerCase();
    var f = {id: this.nextId++, parent: -1, type: "ROOT", from: "", to: a, ctx: a, sel: "", depth: 1, phase: -1};
    this.frames.push(f); this.stack.push(f);
  },
  enter: function(frame) {
    var p = this.top();
    if (!p) return;
    var type = frame.getType();
    var to = toHex(frame.getTo()).toLowerCase();
    var input = toHex(frame.getInput());
    var ctx = (type === "DELEGATECALL" || type === "CALLCODE") ? p.ctx : to;
    var phase = p.phase;
    if (p.ctx === this.EP && (type === "CALL" || type === "STATICCALL")) {
      phase = this.phases.length;
      this.phases.push({i: phase, target: to, sel: input.slice(0, 10), frame: this.nextId});
    }
    var f = {id: this.nextId++, parent: p.id, type: type, from: toHex(frame.getFrom()).toLowerCase(), to: to,
      ctx: ctx, sel: input.slice(0, 10), depth: p.depth + 1, phase: phase};
    this.frames.push(f); this.stack.push(f);
  },
  exit: function(res) {
    var f = this.stack.pop();
    if (f) { f.err = res.getError() ? String(res.getError()) : null; f.gasUsed = res.getGasUsed(); }
  },
  step: function(log, db) {
    this.ensureRoot(log);
    var op = log.op.toString();
    var f = this.top();
    if (this.lastOp === "GAS" && op.indexOf("CALL") < 0) this.ops.push({f: f.id, op: "GAS"});
    this.lastOp = op;
    if (op === "SLOAD" || op === "SSTORE" || op === "TLOAD" || op === "TSTORE") {
      var slot = toHex(toWord(log.stack.peek(0).toString(16)));
      this.acc.push({f: f.id, op: op, a: toHex(log.contract.getAddress()).toLowerCase(), s: slot});
    } else if (op === "KECCAK256" || op === "SHA3") {
      var off = parseInt(log.stack.peek(0).toString());
      var len = parseInt(log.stack.peek(1).toString());
      if (len > 0 && len <= 160) this.kec.push(toHex(log.memory.slice(off, off + len)));
    } else if (this.BANNED[op]) {
      this.ops.push({f: f.id, op: op});
    }
  },
  fault: function(log, db) {},
  result: function(ctx, db) {
    return {entryPoint: this.EP, phases: this.phases, frames: this.frames, acc: this.acc, ops: this.ops, kec: this.kec};
  }
}`;
}
