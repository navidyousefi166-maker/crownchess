-- kf_audit_complete
CREATE OR REPLACE FUNCTION public.kf_audit_complete(p_id bigint, p_verdict text, p_detail text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'kf_audit', 'pg_temp'
AS $function$
DECLARE
 j kf_audit.move_jobs%ROWTYPE;
 v_forfeit_game public.kf_games%ROWTYPE;
 v_new_winner uuid;
BEGIN
 IF p_verdict NOT IN ('passed','flagged','review') THEN RAISE EXCEPTION 'Invalid verdict'; END IF;
 SELECT * INTO j FROM kf_audit.move_jobs WHERE id=p_id FOR UPDATE;
 IF NOT FOUND OR j.status <> 'processing' THEN RETURN FALSE; END IF;
 UPDATE kf_audit.move_jobs
 SET status=p_verdict,detail=left(p_detail,500),finished_at=clock_timestamp()
 WHERE id=p_id;

 IF p_verdict IN ('flagged','review') THEN
  INSERT INTO kf_audit.alerts(job_id,game_id,player_id,verdict,detail,move_data,
                              archived_pgn,before_pgn,after_pgn,before_fen,after_fen,
                              white_username,black_username)
  SELECT j.id,j.game_id,j.player_id,p_verdict,left(p_detail,500),j.move_data,
         COALESCE(g.pgn,j.after_pgn),j.before_pgn,j.after_pgn,j.before_fen,j.after_fen,
         g.white_username,g.black_username
    FROM (SELECT 1) v
    LEFT JOIN public.kf_games g ON g.id=j.game_id
  ON CONFLICT(job_id) DO NOTHING;
 END IF;

 -- Only incontrovertible illegal chess moves cause an in-progress forfeit.
 -- FEN differences, SAN differences, malformed metadata and audit errors are review-only.
 -- Lock the current game row so a concurrent legal game finish cannot be overwritten.
 IF p_verdict='flagged'
    AND p_detail='Move illegal from authoritative previous FEN'
    AND j.before_fen IS NOT NULL
    AND j.after_fen IS NOT NULL
    AND j.player_id IS NOT NULL
    AND j.move_data ? 'from'
    AND j.move_data ? 'to' THEN
   SELECT * INTO v_forfeit_game
     FROM public.kf_games
     WHERE id=j.game_id
     FOR UPDATE;

   IF FOUND AND v_forfeit_game.status='active'
      AND j.player_id IN (v_forfeit_game.white_id,v_forfeit_game.black_id) THEN

     v_new_winner := CASE WHEN j.player_id=v_forfeit_game.white_id
                          THEN v_forfeit_game.black_id
                          ELSE v_forfeit_game.white_id END;

     IF v_new_winner IS NOT NULL AND v_new_winner<>j.player_id THEN
       UPDATE public.kf_games
       SET status='completed',
           completed_at=clock_timestamp(),
           winner_id=v_new_winner,
           result=CASE WHEN v_new_winner=v_forfeit_game.white_id THEN '1-0' ELSE '0-1' END,
           updated_at=clock_timestamp()
       WHERE id=j.game_id AND status='active';

       UPDATE kf_audit.alerts
       SET detail=left(p_detail || ' | Automatic forfeit while game was active',500)
       WHERE job_id=j.id;
     END IF;
   END IF;
 END IF;
 RETURN TRUE;
END;
$function$


-- kf_commit_fast_move_v1
CREATE OR REPLACE FUNCTION public.kf_commit_fast_move_v1(p_game_id uuid, p_player_id uuid, p_expected_fen text, p_expected_turn text, p_new_fen text, p_new_pgn text, p_last_move jsonb, p_new_turn text, p_status text, p_result text, p_winner_id uuid, p_move_received_at timestamp with time zone, p_request_id uuid, p_is_premove boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'kf_audit', 'pg_temp'
AS $function$
DECLARE
 g public.kf_games%ROWTYPE;
 v_now timestamptz := clock_timestamp();
 v_anchor timestamptz;
 v_elapsed numeric(12,3);
 v_white numeric(12,3);
 v_black numeric(12,3);
 v_status text;
 v_result text;
 v_winner uuid;
 v_apply boolean;
 v_before_pgn text;
BEGIN
 IF p_game_id IS NULL OR p_player_id IS NULL OR p_request_id IS NULL
   OR p_expected_fen IS NULL OR p_new_fen IS NULL OR p_new_pgn IS NULL
   OR p_last_move IS NULL OR p_move_received_at IS NULL THEN
   RAISE EXCEPTION 'Missing move data';
 END IF;
 IF p_expected_turn NOT IN ('w','b') OR p_new_turn NOT IN ('w','b')
   OR p_expected_turn = p_new_turn THEN
   RAISE EXCEPTION 'Invalid turn transition';
 END IF;
 IF length(p_new_fen)>250 OR length(p_new_fen)<20 OR length(p_new_pgn)>80000
   OR jsonb_typeof(p_last_move)<>'object'
   OR COALESCE(p_last_move->>'from','') !~ '^[a-h][1-8]$'
   OR COALESCE(p_last_move->>'to','') !~ '^[a-h][1-8]$' THEN
   RAISE EXCEPTION 'Malformed move data';
 END IF;
 IF p_move_received_at > v_now + interval '1 second'
   OR p_move_received_at < v_now - interval '15 seconds' THEN
   RAISE EXCEPTION 'Invalid server receipt timestamp';
 END IF;
 SELECT * INTO g FROM public.kf_games WHERE id=p_game_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Game not found'; END IF;
 IF g.kf_last_validated_request=p_request_id THEN
  RETURN jsonb_build_object('status',g.status,'result',g.result,
   'winner_id',g.winner_id,'white_time_left',g.white_time_left,
   'black_time_left',g.black_time_left,'last_move_at',g.last_move_at,
   'clock_started_at',g.clock_started_at,'duplicate',true,
   'server_received_at',g.last_move_at);
 END IF;
 IF g.status<>'active' OR g.fen IS DISTINCT FROM p_expected_fen
   OR g.turn IS DISTINCT FROM p_expected_turn THEN
   RAISE EXCEPTION 'Stale game position';
 END IF;
 IF p_player_id IS DISTINCT FROM (CASE WHEN g.turn='w' THEN g.white_id ELSE g.black_id END) THEN
   RAISE EXCEPTION 'Not your turn';
 END IF;
 IF NOT EXISTS (
   SELECT 1 FROM auth.users u WHERE u.id=p_player_id AND u.deleted_at IS NULL
     AND (u.banned_until IS NULL OR u.banned_until <= clock_timestamp())
 ) THEN RAISE EXCEPTION 'Not authenticated'; END IF;
 IF (p_last_move ? 'kf_session_id') THEN
   IF (p_last_move->>'kf_session_id') IS NULL
   THEN RAISE EXCEPTION 'Not authenticated'; END IF;
   IF NOT EXISTS (SELECT 1 FROM auth.sessions s
       WHERE s.id=(p_last_move->>'kf_session_id')::uuid AND s.user_id=p_player_id
       AND (s.not_after IS NULL OR s.not_after>clock_timestamp()))
   THEN RAISE EXCEPTION 'Not authenticated'; END IF;
 END IF;
 IF g.is_bloodblade AND ((g.turn='w' AND g.white_handicap IS NULL)
   OR (g.turn='b' AND g.black_handicap IS NULL)) THEN
   RAISE EXCEPTION 'Bloodblade sacrifice required';
 END IF;
 IF g.clock_started_at IS NULL OR p_move_received_at<g.clock_started_at THEN
   RAISE EXCEPTION 'Game clock has not started';
 END IF;
 IF g.turn='w' AND g.white_first_move_at IS NULL
   AND p_move_received_at>=g.clock_started_at+interval '20 seconds' THEN
   RAISE EXCEPTION 'White first-move deadline expired';
 END IF;
 IF g.turn='b' AND g.black_first_move_at IS NULL
   AND (g.last_move_at IS NULL OR p_move_received_at>=g.last_move_at+interval '20 seconds') THEN
   RAISE EXCEPTION 'Black first-move deadline expired';
 END IF;
 v_anchor:=GREATEST(COALESCE(g.last_move_at,g.clock_started_at),g.clock_started_at);
 IF p_move_received_at < v_anchor THEN RAISE EXCEPTION 'Invalid move timestamp order'; END IF;
 v_elapsed:=GREATEST(0,extract(epoch FROM (p_move_received_at-v_anchor)))::numeric;
 -- Every move, including a locally queued premove, receives the same
 -- 300ms forgiveness. No artificial 200ms premove minimum.
 v_elapsed:=GREATEST(0,v_elapsed-LEAST(v_elapsed,0.300));
 v_before_pgn:=g.pgn;
 v_white:=COALESCE(g.white_time_left,300);
 v_black:=COALESCE(g.black_time_left,300);
 v_status:=p_status;v_result:=p_result;v_winner:=p_winner_id;
 IF g.turn='w' THEN
   v_white:=GREATEST(0,v_white-v_elapsed);
   IF v_white=0 THEN v_status:='completed';v_result:='0-1';v_winner:=g.black_id;END IF;
 ELSE
   v_black:=GREATEST(0,v_black-v_elapsed);
   IF v_black=0 THEN v_status:='completed';v_result:='1-0';v_winner:=g.white_id;END IF;
 END IF;
 IF v_status NOT IN ('active','completed')
   OR (v_status='active' AND (v_result IS NOT NULL OR v_winner IS NOT NULL))
   OR (v_status='completed' AND NOT (
      (v_result='1-0' AND v_winner=g.white_id) OR
      (v_result='0-1' AND v_winner=g.black_id) OR
      (v_result='1/2-1/2' AND v_winner IS NULL))) THEN
   RAISE EXCEPTION 'Invalid result and winner';
 END IF;
 v_apply:=(g.turn='w' AND v_white>0) OR (g.turn='b' AND v_black>0);
 PERFORM set_config('app.kf_validated_move_v2','on',true);
 UPDATE public.kf_games SET
  fen=CASE WHEN v_apply THEN p_new_fen ELSE g.fen END,
  pgn=CASE WHEN v_apply THEN p_new_pgn ELSE g.pgn END,
  turn=CASE WHEN v_apply THEN p_new_turn ELSE g.turn END,
  last_move=CASE WHEN v_apply THEN (p_last_move - 'kf_session_id') ELSE g.last_move END,
  status=v_status,result=v_result,winner_id=v_winner,
  white_time_left=v_white,black_time_left=v_black,
  last_move_at=p_move_received_at,
  white_first_move_at=CASE WHEN v_apply AND g.turn='w'
     AND g.white_first_move_at IS NULL THEN p_move_received_at ELSE g.white_first_move_at END,
  black_first_move_at=CASE WHEN v_apply AND g.turn='b'
     AND g.black_first_move_at IS NULL THEN p_move_received_at ELSE g.black_first_move_at END,
  completed_at=CASE WHEN v_status='completed' THEN clock_timestamp() ELSE NULL END,
  updated_at=v_now,
  draw_offer_by=NULL,draw_offer_status=NULL,draw_offer_at=NULL,
  kf_last_validated_request=p_request_id
 WHERE id=p_game_id
 RETURNING * INTO g;
 IF v_apply THEN
  INSERT INTO kf_audit.move_jobs(
    game_id,player_id,before_fen,after_fen,before_pgn,after_pgn,move_data,status)
  VALUES(p_game_id,p_player_id,p_expected_fen,p_new_fen,
    v_before_pgn,p_new_pgn,(p_last_move - 'kf_session_id'),'pending');
 END IF;
 RETURN jsonb_build_object('status',g.status,'result',g.result,
   'winner_id',g.winner_id,'white_time_left',g.white_time_left,
   'black_time_left',g.black_time_left,'last_move_at',g.last_move_at,
   'clock_started_at',g.clock_started_at,
   'server_received_at',p_move_received_at,'server_completed_at',clock_timestamp());
END;$function$

