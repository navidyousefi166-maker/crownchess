import { createClient } from "npm:@supabase/supabase-js@2.95.0";
import { Chess } from "npm:chess.js@1.4.0";

// Only terminal chess states are validated here. Ordinary moves keep the
// fast browser->RPC path with asynchronous audit.
const cors = {
 "Access-Control-Allow-Origin":"*",
 "Access-Control-Allow-Headers":"authorization,apikey,content-type,x-client-info",
 "Access-Control-Allow-Methods":"POST, OPTIONS",
};
const reply = (data:unknown,status=200)=>new Response(JSON.stringify(data),{
 status,headers:{...cors,"Content-Type":"application/json"}
});
const uuid=(value:unknown)=>typeof value==="string"&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
const square=(value:unknown)=>typeof value==="string"&&/^[a-h][1-8]$/.test(value);
const START="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
const normalized=(fen:string)=>fen==="startpos"?START:fen;

Deno.serve(async(req:Request)=>{
 const receivedAt=new Date().toISOString();
 if(req.method==="OPTIONS") return new Response(null,{status:204,headers:cors});
 if(req.method!=="POST") return reply({error:"POST required"},405);
 try{
  const auth=req.headers.get("Authorization")||"";
  if(!auth.startsWith("Bearer ")) return reply({error:"Not authenticated"},401);
  const input=await req.json();
  if(!input||!uuid(input.game_id)||!uuid(input.request_id)||
     !square(input.from)||!square(input.to)||input.from===input.to||
     (input.promotion!=null&&!["q","r","b","n"].includes(input.promotion))||
     input.status!=="completed") return reply({error:"Malformed terminal move"},400);
  const url=Deno.env.get("SUPABASE_URL")||"";
  const anon=Deno.env.get("SUPABASE_ANON_KEY")||"";
  const secret=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")||"";
  if(!url||!anon||!secret) return reply({error:"Server configuration unavailable"},503);
  const userClient=createClient(url,anon,{global:{headers:{Authorization:auth}},auth:{persistSession:false}});
  const {data:identity,error:authError}=await userClient.auth.getClaims(auth.slice(7));
  const claims=identity?.claims;
  if(authError||!claims||!uuid(claims.sub)||!uuid(claims.session_id)||claims.role!=="authenticated")
    return reply({error:"Not authenticated"},401);
  const db=createClient(url,secret,{auth:{persistSession:false}});
  const {data:g,error:readError}=await userClient.from("kf_games")
    .select("id,white_id,black_id,status,turn,fen,pgn")
    .eq("id",input.game_id).maybeSingle();
  if(readError||!g) return reply({error:"Game unavailable"},404);
  if(g.status!=="active")return reply({error:"Game already finished"},409);
  const userId=claims.sub as string;
  if(userId!==(g.turn==="w"?g.white_id:g.black_id))
    return reply({error:"Not your turn"},403);
  if(typeof g.fen!=="string"||g.fen.length>250||!["w","b"].includes(g.turn))
    return reply({error:"Invalid stored game position"},409);
  const original=normalized(g.fen);
  let board:Chess;
  try{board=new Chess(original);}catch{return reply({error:"Invalid server chess position"},409);}
  // Recover history when possible so that repetition draws are recognised.
  if(typeof g.pgn==="string"&&g.pgn.trim()){
    try{
      const history=new Chess();
      history.loadPgn(g.pgn);
      if(history.fen()===original)board=history;
    }catch{/* Valid FEN still supports mate, stalemate, material and 50-move draws. */}
  }
  let moved:ReturnType<Chess["move"]>|null=null;
  try{
    moved=board.move({
      from:input.from,to:input.to,
      ...(input.promotion?{promotion:input.promotion}:{})
    });
  }catch{/* Move rejected below. */}
  if(!moved)return reply({error:"Illegal terminal chess move"},422);
  if(!board.isGameOver())return reply({error:"Game is not over: terminal result rejected"},422);
  const actualResult=board.isCheckmate()
    ?(moved.color==="w"?"1-0":"0-1")
    :"1/2-1/2";
  const actualWinner=board.isCheckmate()?userId:null;
  const calculatedFen=board.fen();
  // The client cannot supply a fake mate or forged position/history.
  // In case of a legacy FEN ep-field difference, compare piece placement,
  // active colour, castling and move counters; the server's FEN is committed.
  const calculatedParts=calculatedFen.split(" ");
  const receivedParts=String(input.fen||"").split(" ");
  if(receivedParts.length!==6 ||
     calculatedParts[0]!==receivedParts[0]||
     calculatedParts[1]!==receivedParts[1]||
     calculatedParts[2]!==receivedParts[2]||
     calculatedParts[4]!==receivedParts[4]||
     calculatedParts[5]!==receivedParts[5])return reply({error:"Terminal position mismatch"},422);
  // Ignore submitted PGN/result; derive trusted result and SAN. Existing
  // game history is authoritative. Append SAN in the same format as browser.
  const beforePgn=typeof g.pgn==="string"?g.pgn:"";
  const whiteMove=moved.color==="w";
  const moveNumber=Number(original.split(" ")[5]||"1");
  const prefix=whiteMove?String(moveNumber)+". "+moved.san:(beforePgn?" "+moved.san:String(moveNumber)+"... "+moved.san);
  const calculatedPgn=beforePgn?beforePgn.trim()+(whiteMove?" ":"")+prefix:prefix;
  const {data:committed,error:commitError}=await db.rpc("kf_commit_verified_terminal_move_v1",{
   p_game_id:g.id,p_player_id:userId,p_expected_fen:g.fen,p_expected_turn:g.turn,
   p_new_fen:calculatedFen,p_new_pgn:calculatedPgn,
   p_last_move:{from:moved.from,to:moved.to,san:moved.san,promotion:moved.promotion||null,kf_session_id:claims.session_id},
   p_new_turn:board.turn(),p_status:"completed",p_result:actualResult,
   p_winner_id:actualWinner,p_move_received_at:receivedAt,p_request_id:input.request_id
  });
  if(commitError){
    const msg=String(commitError.message||"Commit rejected");
    return reply({error:/stale|turn|clock|deadline|finished|timestamp/i.test(msg)?msg:"Terminal move rejected"},409);
  }
  return reply(committed);
 }catch(err){
  console.error("[Kingsfall terminal move verification]",err);
  return reply({error:"Terminal verification unavailable"},500);
 }
});
