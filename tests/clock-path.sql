-- Run inside BEGIN/ROLLBACK; no test game or stats are committed.

DO $test$
DECLARE w uuid; b uuid; gid uuid := gen_random_uuid(); r jsonb; row_game public.kf_games%ROWTYPE; n integer;
BEGIN
SELECT white_id,black_id INTO w,b FROM public.kf_games WHERE white_id IS NOT NULL AND black_id IS NOT NULL AND white_id<>black_id LIMIT 1;
IF w IS NULL THEN RAISE EXCEPTION 'No player pair available for isolated rollback test'; END IF;
INSERT INTO public.kf_games(id,status,turn,white_id,black_id,white_username,black_username,fen,pgn,white_time_left,black_time_left,clock_started_at,created_at,is_tournament,is_roulette,is_bloodblade)
VALUES(gid,'active','w',w,b,'clock-test-white','clock-test-black','rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1','',300,300,clock_timestamp()-interval '2 seconds',clock_timestamp(),false,false,false);
PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',w,'role','authenticated')::text,true);
r:=public.kf_submit_move(gid,'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1','1. e4','b','{"from":"e2","to":"e4","san":"e4"}','active',null,null,999999,999999);
IF (r->>'white_time_left')::numeric NOT BETWEEN 295 AND 299 THEN RAISE EXCEPTION 'White clock or untrusted client time regression: %',r; END IF;
IF r->>'server_received_at' IS NULL OR r->>'write_ms' IS NULL OR (r->>'server_completed_at')::timestamptz < (r->>'server_received_at')::timestamptz THEN RAISE EXCEPTION 'Missing diagnostic timings'; END IF;
SELECT * INTO row_game FROM public.kf_games WHERE id=gid;
IF row_game.white_time_left<>(r->>'white_time_left')::numeric OR row_game.turn<>'b' THEN RAISE EXCEPTION 'Persisted time differs'; END IF;
PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',b,'role','authenticated')::text,true);
r:=public.kf_submit_move(gid,'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2','1. e4 e5','w','{"from":"e7","to":"e5","san":"e5"}','active',null,null,999999,999999);
IF (r->>'black_time_left')::numeric NOT BETWEEN 295 AND 300 THEN RAISE EXCEPTION 'Black clock regression'; END IF;
SELECT count(*) INTO n FROM kf_audit.move_jobs WHERE game_id=gid;
IF n<>2 THEN RAISE EXCEPTION 'Move audit queue regression'; END IF;
PERFORM set_config('request.jwt.claims','{}',true);
BEGIN
PERFORM public.kf_submit_move(gid,'x','x','b','{}','active',null,null,300,300);
RAISE EXCEPTION 'Unauthenticated submission accepted';
EXCEPTION WHEN OTHERS THEN
IF SQLERRM<>'Please sign in first' THEN RAISE; END IF;
END;
END
$test$;

