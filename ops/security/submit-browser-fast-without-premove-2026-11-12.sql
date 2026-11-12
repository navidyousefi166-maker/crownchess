-- No premove indication accepted by new browser RPC. Legacy overload retained for cached clients.
BEGIN;
CREATE OR REPLACE FUNCTION public.kf_submit_browser_fast_v1(p_game_id uuid, p_expected_fen text, p_from text, p_to text, p_promotion text, p_san text, p_fen text, p_pgn text, p_turn text, p_status text, p_result text, p_winner_id uuid, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
  v_player uuid := auth.uid();
  v_claims jsonb := auth.jwt();
  v_session text;
  v_received_at timestamptz := clock_timestamp();
BEGIN
  -- PostgREST verifies the caller's signed JWT before exposing this RPC.
  -- Never accept a player ID, session ID, or clock timestamp from the browser.
  IF v_player IS NULL OR COALESCE(v_claims->>'role','') <> 'authenticated' THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE='42501';
  END IF;
  v_session := v_claims->>'session_id';
  IF v_session IS NULL OR v_session !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN
    RAISE EXCEPTION 'Missing verified session' USING ERRCODE='42501';
  END IF;
  IF p_from !~ '^[a-h][1-8]$' OR p_to !~ '^[a-h][1-8]$'
     OR p_from=p_to OR p_turn NOT IN ('w','b')
     OR p_promotion IS NOT NULL AND p_promotion NOT IN ('q','r','b','n') THEN
    RAISE EXCEPTION 'Malformed move' USING ERRCODE='22023';
  END IF;
  RETURN public.kf_commit_fast_move_v1(
    p_game_id,
    v_player,
    p_expected_fen,
    CASE p_turn WHEN 'w' THEN 'b' WHEN 'b' THEN 'w' ELSE NULL END,
    p_fen,
    p_pgn,
    jsonb_build_object('from',p_from,'to',p_to,'san',p_san,
                       'promotion',p_promotion,'kf_session_id',v_session),
    p_turn,
    p_status,
    p_result,
    p_winner_id,
    v_received_at,
    p_request_id,
    false
  );
END;
$function$

REVOKE ALL ON FUNCTION public.kf_submit_browser_fast_v1(uuid,text,text,text,text,text,text,text,text,text,text,uuid,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.kf_submit_browser_fast_v1(uuid,text,text,text,text,text,text,text,text,text,text,uuid,uuid) TO authenticated;
COMMIT;
