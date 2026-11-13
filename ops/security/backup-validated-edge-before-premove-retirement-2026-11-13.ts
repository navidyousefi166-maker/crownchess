import { createClient } from "npm:@supabase/supabase-js@2.95.0";
import { Chess } from "npm:chess.js@1.4.0";

const cors = {"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization,apikey,content-type,x-client-info","Access-Control-Allow-Methods":"POST, OPTIONS"};
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,"Content-Type":"application/json"}});
const startFen="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
// Best-effort audit in a background task, separate from live game timing.
function logInvalidMove(admin:ReturnType<typeof createClient>, data:{
  request_id:string;game_id:string;player_id:string;white_id:string;black_id:string;
  white_username:string|null;black_username:string|null;
  move_from:string;move_to:string;promotion:string|null;
  position_fen:string;position_pgn:string|null;
}):void{
  const task=(async()=>{
    try{
      const since=new Date(Date.now()-10000).toISOString();
      const {data:recent,error:readError}=await admin.from("kf_invalid_move_reports")
        .select("id").eq("game_id",data.game_id).eq("player_id",data.player_id)
        .gte("reported_at",since).limit(1);
      if(readError){console.warn("[Kingsfall audit] rate check failed",readError.message);return;}
      if(recent?.length)return;
      const {error}=await admin.from("kf_invalid_move_reports").insert({...data,reason:"illegal_chess_move"});
      if(error)console.warn("[Kingsfall audit] write failed",error.message);
    }catch(e){console.warn("[Kingsfall audit] background error",e);}
  })();
  EdgeRuntime.waitUntil(task);
}
type Input={game_id?:string;from?:string;to?:string;promotion?:string;request_id?:string};
function appendPgn(before:string,startingFen:string,move:{san:string,color:string},result:string|null){
  const parts=startingFen.split(" ");
  const number=Number(parts[5]||1);
  const next=(before||"").trim().replace(/\s+(?:1-0|0-1|1\/2-1\/2|\*)\s*$/,"");
  const prefix=move.color==="w"?number+". "+move.san:(next?" "+move.san:number+"... "+move.san);
  const setup=!next && startingFen!==startFen ? '[SetUp "1"]\n[FEN "'+startingFen+'"]\n\n' : "";
  return setup+next+(next&&move.color==="w"?" ":"")+prefix+(result?" "+result:"");
}
// Single rules engine for both ordinary moves and queued premoves.
// Only the caller decides whether a rejected move is an audit event.
function validateChessTurn(board:Chess, request:{from:string;to:string;promotion?:string},
    context:{previousPgn:string;startingFen:string;historyLoaded:boolean}){
  let move:ReturnType<Chess["move"]>|null=null;
  try{move=board.move(request);}catch{move=null;}
  if(!move)return null;
  const fen=board.fen();
  const mate=board.isCheckmate(),draw=board.isDraw();
  const ended=mate||draw;
  const result=mate?(move.color==="w"?"1-0":"0-1"):(draw?"1/2-1/2":null);
  let pgn=context.historyLoaded||!context.previousPgn
    ?board.pgn():appendPgn(context.previousPgn,context.startingFen,move,result);
  if(ended&&pgn&&!pgn.includes("[Result "))pgn=pgn.trim();
  return {move,fen,pgn,ended,result,status:ended?"completed":"active" as "completed"|"active"};
}
Deno.serve(async req=>{
  // Server-controlled receipt time captured before authentication, DB reads or validation.
  const receivedAt=new Date().toISOString();
  if(req.method==="OPTIONS")return new Response(null,{status:204,headers:cors});
  if(req.method!=="POST")return json({error:"POST required"},405);
  try{
    const auth=req.headers.get("Authorization")||"";
    if(!auth.startsWith("Bearer "))return json({error:"Not signed in"},401);
    const token=auth.slice(7);
    const input:Input=await req.json();
    if(!input || !/^[0-9a-f-]{36}$/i.test(input.game_id||"") ||
       !/^[a-h][1-8]$/.test(input.from||"") || !/^[a-h][1-8]$/.test(input.to||"") ||
       (input.promotion!==undefined&&!/^[qrbn]$/.test(input.promotion)) ||
       !/^[0-9a-f-]{36}$/i.test(input.request_id||"")) return json({error:"Malformed move request"},400);
    const url=Deno.env.get("SUPABASE_URL")||"";
    const anonKey=Deno.env.get("SUPABASE_ANON_KEY")||"";
    const secret=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")||"";
    if(!url||!anonKey||!secret) return json({error:"Server configuration unavailable"},503);
    const client=createClient(url,anonKey,{global:{headers:{Authorization:auth}},auth:{persistSession:false}});
    const {data:userData,error:userError}=await client.auth.getUser(token);
    if(userError||!userData.user)return json({error:"Not authenticated"},401);
    // Fetch the queued opponent move in parallel with the game position.
    const premoveAdmin=createClient(url,secret,{auth:{persistSession:false}});
    const [read,queueRead]=await Promise.all([
      client.from("kf_games").select("id,white_id,black_id,white_username,black_username,status,fen,pgn,turn,clock_started_at,last_move_at,is_roulette,is_bloodblade,white_handicap,black_handicap").eq("id",input.game_id).maybeSingle(),
      premoveAdmin.from("kf_premoves").select("player_id,move_from,move_to,promotion,queued_at").eq("game_id",input.game_id)
    ]);
    const {data:row,error:readError}=read;
    if(readError||!row)return json({error:"Game unavailable"},404);
    if(row.status!=="active")return json({error:"Game not active"},409);
    const uid=userData.user.id;
    if(uid!==(row.turn==="w"?row.white_id:row.black_id))return json({error:"Not your turn"},403);
    if(row.is_bloodblade && (row.turn==="w"?!row.white_handicap:!row.black_handicap))return json({error:"Bloodblade sacrifice required"},422);
    const fen=row.fen==="startpos"?startFen:row.fen;
    let board:Chess;
    try{board=new Chess(fen);}catch{return json({error:"Invalid server chess position"},409);}
    let loaded=false;
    if(row.pgn){
      try{
        const historical=new Chess();
        historical.loadPgn(row.pgn);
        if(historical.fen()===fen){board=historical;loaded=true;}
      }catch{/* Keep the FEN as authoritative when older PGN cannot be reconstructed. */}
    }
    const requested={from:input.from,to:input.to,...(input.promotion?{promotion:input.promotion}:{})};
    const checked=validateChessTurn(board,requested,{previousPgn:row.pgn||"",startingFen:fen,historyLoaded:loaded});
    const move=checked?.move||null;
    if(!move){
      const admin=createClient(url,secret,{auth:{persistSession:false}});
      logInvalidMove(admin,{
        request_id:input.request_id!,game_id:row.id,player_id:uid,
        white_id:row.white_id,black_id:row.black_id,
        white_username:row.white_username||null,black_username:row.black_username||null,
        move_from:input.from!,move_to:input.to!,promotion:input.promotion||null,
        position_fen:row.fen,position_pgn:row.pgn||null
      });
      return json({error:"Illegal chess move",code:"ILLEGAL_MOVE"},422);
    }
    const newFen=checked!.fen, pgn=checked!.pgn;
    const isOver=checked!.ended, result=checked!.result;
    const winner=board.isCheckmate()?uid:null;
    // Validate an already queued move against the position after this move.
    // Both resulting plies are committed atomically by PostgreSQL, with zero
    // additional elapsed clock time for the premove.
    let pmArgs:Record<string,unknown>={};
    const opponentId=row.turn==="w"?row.black_id:row.white_id;
    const queued=(queueRead.data||[]).find(p=>p.player_id===opponentId);
    if(!isOver && queued && Date.parse(queued.queued_at)<=Date.parse(receivedAt) &&
       (!row.is_bloodblade || (row.turn==="w"?!!row.black_handicap:!!row.white_handicap))){
      try{
        const premove=validateChessTurn(board,
          {from:queued.move_from,to:queued.move_to,promotion:queued.promotion||"q"},
          {previousPgn:pgn,startingFen:newFen,historyLoaded:loaded});
        if(premove){
          const pmMove=premove.move,pmFen=premove.fen,pmStatus=premove.status;
          const pmResult=premove.result,pmPgn=premove.pgn;
          pmArgs={
            p_pm_player_id:opponentId,p_pm_from:queued.move_from,p_pm_to:queued.move_to,
            p_pm_new_fen:pmFen,p_pm_new_pgn:pmPgn,
            p_pm_last_move:{from:pmMove.from,to:pmMove.to,san:pmMove.san,promotion:pmMove.promotion||null},
            p_pm_new_turn:board.turn(),p_pm_status:pmStatus,p_pm_result:pmResult,
            p_pm_winner_id:premove.result===(row.turn==='w'?'0-1':'1-0')?opponentId:null
          };
        }
      }catch{/* Illegal or obsolete premoves are discarded, never audited as cheating. */}
    }
    const admin=createClient(url,secret,{auth:{persistSession:false}});
    const {data,error}=await admin.rpc("kf_commit_validated_move_v3",{
      p_game_id:row.id,p_player_id:uid,p_expected_fen:row.fen,p_expected_turn:row.turn,
      p_new_fen:newFen,p_new_pgn:pgn,
      p_last_move:{from:move.from,to:move.to,san:move.san,promotion:move.promotion||null},
      p_new_turn:row.turn==="w"?"b":"w",p_status:isOver?"completed":"active",p_result:result,
      p_winner_id:winner,p_move_received_at:receivedAt,p_request_id:input.request_id,...pmArgs
    });
    if(error){
      const msg=String(error.message||"Commit rejected");
      return json({error:/stale|turn|already|finished|deadline|time/i.test(msg)?msg:"Move could not be committed",code:"MOVE_REJECTED"},409);
    }
    return json(data);
  }catch(error){
    console.error("[Kingsfall validation v2]",error);
    return json({error:"Move validation unavailable"},500);
  }
});