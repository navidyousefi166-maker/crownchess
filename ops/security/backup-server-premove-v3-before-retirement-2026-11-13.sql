-- Backup of server-premoves before retirement 2026-11-13
-- Stored definition only (no personal data).
CREATE OR REPLACE FUNCTION public.kf_commit_validated_move_v3(p_game_id uuid, p_player_id uuid, p_expected_fen text, p_expected_turn text, p_new_fen text, p_new_pgn text, p_last_move jsonb, p_new_turn text, p_status text, p_result text, p_winner_id uuid, p_move_received_at timestamp with time zone, p_request_id uuid, p_pm_player_id uuid DEFAULT NULL::uuid, p_pm_from text DEFAULT NULL::text, p_pm_to text DEFAULT NULL::text, p_pm_new_fen text DEFAULT NULL::text, p_pm_new_pgn text DEFAULT NULL::text, p_pm_last_move jsonb DEFAULT NULL::jsonb, p_pm_new_turn text DEFAULT NULL::text, p_pm_status text DEFAULT NULL::text, p_pm_result text DEFAULT NULL::text, p_pm_winner_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
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
 v_pm public.kf_premoves%ROWTYPE;
 v_use_pm boolean := false;
 v_pm_timeout boolean := false;
 v_final_status text;
 v_final_result text;
 v_final_winner uuid;
BEGIN
 IF p_game_id IS NULL OR p_player_id IS NULL OR p_request_id IS NULL OR
 p_expected_fen IS NULL OR p_new_fen IS NULL OR p_new_pgn IS NULL OR p_last_move IS NULL OR
 p_move_received_at IS NULL THEN
   RAISE EXCEPTION 'Missing validated-move data';
 END IF;
 IF p_new_turn NOT IN ('w','b') OR p_expected_turn NOT IN ('w','b') OR p_new_turn=p_expected_turn THEN
   RAISE EXCEPTION 'Invalid turn transition';
 END IF;
 IF p_move_received_at > v_now + interval '1 second' OR p_move_received_at < v_now - interval '15 seconds' THEN
   RAISE EXCEPTION 'Invalid server receipt timestamp';
 END IF;
 SELECT * INTO g FROM public.kf_games WHERE id=p_game_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Game not found'; END IF;
 IF g.kf_last_validated_request=p_request_id THEN
   RETURN jsonb_build_object('status',g.status,'result',g.result,'winner_id',g.winner_id,
    'white_time_left',g.white_time_left,'black_time_left',g.black_time_left,
    'last_move_at',g.last_move_at,'clock_started_at',g.clock_started_at,
    'server_received_at',g.last_move_at,'duplicate',true);
 END IF;
 IF g.status <> 'active' OR g.fen IS DISTINCT FROM p_expected_fen OR g.turn IS DISTINCT FROM p_expected_turn THEN
   RAISE EXCEPTION 'Stale game position';
 END IF;
 IF p_player_id IS DISTINCT FROM (CASE WHEN g.turn='w' THEN g.white_id ELSE g.black_id END) THEN
   RAISE EXCEPTION 'Not your turn';
 END IF;
 IF g.is_bloodblade AND ((g.turn='w' AND g.white_handicap IS NULL) OR (g.turn='b' AND g.black_handicap IS NULL)) THEN
   RAISE EXCEPTION 'Bloodblade sacrifice required';
 END IF;
 IF g.clock_started_at IS NULL OR p_move_received_at < g.clock_started_at THEN
   RAISE EXCEPTION 'Game clock has not started';
 END IF;
 IF g.turn='w' AND g.white_first_move_at IS NULL AND
     p_move_received_at >= g.clock_started_at + interval '20 seconds' THEN
   RAISE EXCEPTION 'White first-move deadline expired';
 END IF;
 IF g.turn='b' AND g.black_first_move_at IS NULL AND
     (g.last_move_at IS NULL OR p_move_received_at >= g.last_move_at + interval '20 seconds') THEN
   RAISE EXCEPTION 'Black first-move deadline expired';
 END IF;
 v_anchor := GREATEST(COALESCE(g.last_move_at,g.clock_started_at),g.clock_started_at);
 IF p_move_received_at < v_anchor THEN RAISE EXCEPTION 'Invalid move timestamp order'; END IF;
 v_elapsed := GREATEST(0,extract(epoch FROM (p_move_received_at-v_anchor)))::numeric;
 v_white := COALESCE(g.white_time_left,300);
 v_black := COALESCE(g.black_time_left,300);
 v_status := p_status; v_result := p_result; v_winner := p_winner_id;
 IF g.turn='w' THEN
   v_white:=GREATEST(0,v_white-v_elapsed);
   IF v_white=0 THEN v_status:='completed';v_result:='0-1';v_winner:=g.black_id; END IF;
 ELSE
   v_black:=GREATEST(0,v_black-v_elapsed);
   IF v_black=0 THEN v_status:='completed';v_result:='1-0';v_winner:=g.white_id; END IF;
 END IF;
 IF v_status NOT IN ('active','completed') THEN RAISE EXCEPTION 'Invalid move status'; END IF;
 IF v_status='active' AND (v_result IS NOT NULL OR v_winner IS NOT NULL) THEN RAISE EXCEPTION 'Unexpected result'; END IF;
 IF v_status='completed' AND
   NOT ((v_result='1-0' AND v_winner=g.white_id) OR
        (v_result='0-1' AND v_winner=g.black_id) OR
        (v_result='1/2-1/2' AND v_winner IS NULL)) THEN
   RAISE EXCEPTION 'Invalid result and winner'; END IF;
 SELECT * INTO v_pm FROM public.kf_premoves
 WHERE game_id=g.id AND player_id=(CASE WHEN g.turn='w' THEN g.black_id ELSE g.white_id END)
 FOR UPDATE;
 IF FOUND AND v_status='active' AND p_pm_player_id=v_pm.player_id
    AND v_pm.queued_at <= p_move_received_at
    AND v_pm.move_from=p_pm_from AND v_pm.move_to=p_pm_to
    AND p_pm_new_fen IS NOT NULL AND p_pm_new_pgn IS NOT NULL AND p_pm_last_move IS NOT NULL
    AND p_pm_new_turn=g.turn AND p_pm_status IN ('active','completed')
    AND (NOT g.is_bloodblade OR (CASE WHEN g.turn='w' THEN g.black_handicap IS NOT NULL ELSE g.white_handicap IS NOT NULL END))
 THEN
   IF p_pm_status='active' AND p_pm_result IS NULL AND p_pm_winner_id IS NULL THEN v_use_pm := true;
   ELSIF p_pm_status='completed' AND
     ((p_pm_result='1-0' AND p_pm_winner_id=g.white_id) OR
      (p_pm_result='0-1' AND p_pm_winner_id=g.black_id) OR
      (p_pm_result='1/2-1/2' AND p_pm_winner_id IS NULL)) THEN v_use_pm := true;
   END IF;
 END IF;
 DELETE FROM public.kf_premoves WHERE game_id=g.id
   AND player_id=(CASE WHEN g.turn='w' THEN g.black_id ELSE g.white_id END);
 -- A premove costs exactly 0.200 seconds, charged to its own player.
 -- If the player has no time left to pay the charge, their flag falls:
 -- the premove itself must not be applied to the chess position.
 IF v_use_pm THEN
   IF g.turn='w' THEN
     IF v_black <= 0.200 THEN v_pm_timeout := true; v_use_pm := false; v_black := 0;
     ELSE v_black := v_black - 0.200; END IF;
   ELSE
     IF v_white <= 0.200 THEN v_pm_timeout := true; v_use_pm := false; v_white := 0;
     ELSE v_white := v_white - 0.200; END IF;
   END IF;
 END IF;
 v_final_status:=CASE WHEN v_pm_timeout THEN 'completed' WHEN v_use_pm THEN p_pm_status ELSE v_status END;
 v_final_result:=CASE WHEN v_pm_timeout THEN (CASE WHEN g.turn='w' THEN '1-0' ELSE '0-1' END) WHEN v_use_pm THEN p_pm_result ELSE v_result END;
 v_final_winner:=CASE WHEN v_pm_timeout THEN p_player_id WHEN v_use_pm THEN p_pm_winner_id ELSE v_winner END;
 PERFORM set_config('app.kf_validated_move_v2','on',true);
 UPDATE public.kf_games
 SET fen=CASE WHEN (g.turn='w' AND v_white=0) OR (g.turn='b' AND v_black=0) THEN g.fen WHEN v_use_pm THEN p_pm_new_fen ELSE p_new_fen END,
     pgn=CASE WHEN (g.turn='w' AND v_white=0) OR (g.turn='b' AND v_black=0) THEN g.pgn WHEN v_use_pm THEN p_pm_new_pgn ELSE p_new_pgn END,
     turn=CASE WHEN (g.turn='w' AND v_white=0) OR (g.turn='b' AND v_black=0) THEN g.turn WHEN v_use_pm THEN p_pm_new_turn ELSE p_new_turn END,
     last_move=CASE WHEN (g.turn='w' AND v_white=0) OR (g.turn='b' AND v_black=0) THEN g.last_move WHEN v_use_pm THEN p_pm_last_move ELSE p_last_move END,
     status=v_final_status,result=v_final_result,winner_id=v_final_winner,
     white_time_left=v_white,black_time_left=v_black,
     last_move_at=p_move_received_at,
     white_first_move_at=CASE WHEN v_use_pm AND g.turn='b' AND g.white_first_move_at IS NULL THEN p_move_received_at ELSE g.white_first_move_at END,
     black_first_move_at=CASE WHEN v_use_pm AND g.turn='w' AND g.black_first_move_at IS NULL THEN p_move_received_at ELSE g.black_first_move_at END,
     completed_at=CASE WHEN v_final_status='completed' THEN clock_timestamp() ELSE NULL END,
     updated_at=v_now,
     draw_offer_by=NULL,draw_offer_status=NULL,draw_offer_at=NULL,
     kf_last_validated_request=p_request_id
 WHERE id=p_game_id
 RETURNING * INTO g;
 RETURN jsonb_build_object(
   'status',g.status,'result',g.result,'winner_id',g.winner_id,
   'white_time_left',g.white_time_left,'black_time_left',g.black_time_left,
   'last_move_at',g.last_move_at,'clock_started_at',g.clock_started_at,
   'fen',g.fen,'pgn',g.pgn,'turn',g.turn,'last_move',g.last_move,'premove_applied',v_use_pm,
   'server_received_at',p_move_received_at,
   'server_completed_at',clock_timestamp());
END;
$function$


-- Table columns; restore also needs constraints/policies.
-- [{"column_name":"game_id","data_type":"uuid","is_nullable":"NO","column_default":null},{"column_name":"player_id","data_type":"uuid","is_nullable":"NO","column_default":null},{"column_name":"move_from","data_type":"text","is_nullable":"NO","column_default":null},{"column_name":"move_to","data_type":"text","is_nullable":"NO","column_default":null},{"column_name":"promotion","data_type":"text","is_nullable":"NO","column_default":"'q'::text"},{"column_name":"queued_at","data_type":"timestamp with time zone","is_nullable":"NO","column_default":"clock_timestamp()"}]
