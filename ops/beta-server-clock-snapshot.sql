-- Kingsfall Point Beta (2026-11-10): authoritative server clock implementation
-- To restore Beta from Alpha or later revisions, keep existing kf_games data,
-- restore the two lag-budget columns if absent, then the exact function below.
BEGIN;
ALTER TABLE public.kf_games ADD COLUMN IF NOT EXISTS kf_lag_budget_white numeric(8,3) NOT NULL DEFAULT 5.000;
ALTER TABLE public.kf_games ADD COLUMN IF NOT EXISTS kf_lag_budget_black numeric(8,3) NOT NULL DEFAULT 5.000;
CREATE OR REPLACE FUNCTION public.kf_commit_validated_move_v2(p_game_id uuid, p_player_id uuid, p_expected_fen text, p_expected_turn text, p_new_fen text, p_new_pgn text, p_last_move jsonb, p_new_turn text, p_status text, p_result text, p_winner_id uuid, p_move_received_at timestamp with time zone, p_request_id uuid)
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
 v_credit numeric(12,3);
 v_white numeric(12,3);
 v_black numeric(12,3);
 v_status text;
 v_result text;
 v_winner uuid;
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
 -- TEMP ALPHA TEST: bounded, server-only lag allowance; never trust client-side timestamps.
 -- Every side has a total 5 second allowance; max 250 ms is applied per accepted move.
 v_credit := LEAST(v_elapsed,0.250,
     CASE WHEN g.turn='w' THEN g.kf_lag_budget_white ELSE g.kf_lag_budget_black END);
 v_elapsed := GREATEST(0,v_elapsed-v_credit);
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
 PERFORM set_config('app.kf_validated_move_v2','on',true);
 UPDATE public.kf_games
 SET fen=CASE WHEN (g.turn='w' AND v_white=0) OR (g.turn='b' AND v_black=0) THEN g.fen ELSE p_new_fen END,
     pgn=CASE WHEN (g.turn='w' AND v_white=0) OR (g.turn='b' AND v_black=0) THEN g.pgn ELSE p_new_pgn END,
     turn=CASE WHEN (g.turn='w' AND v_white=0) OR (g.turn='b' AND v_black=0) THEN g.turn ELSE p_new_turn END,
     last_move=CASE WHEN (g.turn='w' AND v_white=0) OR (g.turn='b' AND v_black=0) THEN g.last_move ELSE p_last_move END,
     status=v_status,result=v_result,winner_id=v_winner,
     white_time_left=v_white,black_time_left=v_black,
     kf_lag_budget_white = CASE WHEN g.turn='w' THEN GREATEST(0,g.kf_lag_budget_white-v_credit) ELSE g.kf_lag_budget_white END,
     kf_lag_budget_black = CASE WHEN g.turn='b' THEN GREATEST(0,g.kf_lag_budget_black-v_credit) ELSE g.kf_lag_budget_black END,
     last_move_at=clock_timestamp(),
     completed_at=CASE WHEN v_status='completed' THEN clock_timestamp() ELSE NULL END,
     updated_at=v_now,
     draw_offer_by=NULL,draw_offer_status=NULL,draw_offer_at=NULL,
     kf_last_validated_request=p_request_id
 WHERE id=p_game_id
 RETURNING * INTO g;
 RETURN jsonb_build_object(
   'status',g.status,'result',g.result,'winner_id',g.winner_id,
   'white_time_left',g.white_time_left,'black_time_left',g.black_time_left,
   'last_move_at',g.last_move_at,'clock_started_at',g.clock_started_at,
   'fen',g.fen,'pgn',g.pgn,'turn',g.turn,
   'server_received_at',p_move_received_at,
   'server_completed_at',clock_timestamp());
END;
$function$

COMMIT;
