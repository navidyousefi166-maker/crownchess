const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const html = fs.readFileSync(require('node:path').join(__dirname, '../index.html'), 'utf8');
for (const match of html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/g)) new vm.Script(match[1]);
function section(start, end) { return html.slice(html.indexOf(start), html.indexOf(end, html.indexOf(start))); }
const submit = section('async function submitMove(', '/* ===== askPromotion');
const fetchCode = section('function kfTimedFetch(', 'var sb =');
async function check(color, {error=false, stale=false, instant=false}={}) {
  const events=[]; let undo=0;
  const stopped=color==='w'?290.1:280.1;
  const response={error:error?{message:'rejected'}:null,data:{status:'active',white_time_left:color==='w'?stopped:300,black_time_left:color==='b'?stopped:300,last_move_at:'2026-11-09T21:00:00Z',server_received_at:'2026-11-09T21:00:00Z',server_completed_at:'2026-11-09T21:00:00.005Z',lock_wait_ms:1,write_ms:2}};
  const c={performance,Date,Number,Math,Promise,setTimeout,clearTimeout,window:{},console:{debug(){}},
    onlineGameId:'test',onlineGame:{white_id:'w',black_id:'b'},submittingMove:false,gameSyncGeneration:0,kfMoveTrace:null,
    clockWhite:295,clockBlack:285,clockExpired:false,
    draw(){events.push('paint');},say(){},updateHumilBadge(){},paintClocks(){},anchorClockToServerTime(){},syncGameState(){},reloadGameState(){},
    game:{game_over(){return false;},fen(){return 'test fen';},pgn(){return 'test pgn';},turn(){return color==='w'?'b':'w';},undo(){undo++;}},
    fetch(){events.push('fetch');return instant?Promise.resolve({}):new Promise(r=>setTimeout(()=>r({}),30));}
  };
  c.sb={rpc(){events.push('rpc');return {then(resolve,reject){return c.kfTimedFetch('https://example.test/rest/v1/rpc/kf_submit_move',{}).then(()=>resolve(response),reject);}};}};
  vm.createContext(c);vm.runInContext(fetchCode+submit,c);
  const promise=c.submitMove({color,from:'e2',to:'e4',san:'e4'},295,285,performance.now());
  // A second move cannot start while the first is pending.
  await c.submitMove({color,from:'d2',to:'d4',san:'d4'},295,285);
  if(stale)c.onlineGameId='other';
  await promise;
  assert.equal(events.filter(x=>x==='rpc').length,1);
  assert.ok(events.indexOf('fetch')>=0);
  if(!stale)assert.ok(events.indexOf('fetch')<events.indexOf('paint'),'network must start before board/history rendering');
  assert.equal(c.submittingMove,false);
  assert.equal(c.kfMoveTrace,null);
  assert.equal(c.window.kfClockDiagnostics.length,1);
  assert.equal(c.window.kfClockDiagnostics[0].serverMs,5);
  if(error&&!stale)assert.equal(undo,1);
  if(!error&&!stale)assert.equal(color==='w'?c.clockWhite:c.clockBlack,stopped,'keep exact authoritative time');
  if(stale)assert.equal(c.clockWhite,295,'old-game reply must not overwrite a different game');
}
(async()=>{
  for(const color of ['w','b']){await check(color);await check(color,{instant:true});await check(color,{error:true});await check(color,{stale:true});}
  const elements=new Map();let checks=0;
  const c={game:{game_over(){checks++;return false;},turn(){return 'w';}},clockExpired:false,computerMode:false,onlineGameId:'x',onlineGame:{turn:'w'},clockWhite:300,clockBlack:300,fsPlayerColor:'w',fmtClock:String,document:{body:{classList:{contains(){return true;}}}},$(id){if(!elements.has(id))elements.set(id,{classList:{toggle(){}}});return elements.get(id);}};
  vm.createContext(c);vm.runInContext(section('function paintClocks(){','// Keep the visible clock'),c);c.paintClocks();assert.equal(checks,1);
  console.log('PASS: inline JavaScript syntax; send before render; both colors; instant/slow replies; rejection; duplicate submission; stale game response; exact server clocks; single terminal check per repaint.');
})().catch(e=>{console.error(e);process.exitCode=1;});
