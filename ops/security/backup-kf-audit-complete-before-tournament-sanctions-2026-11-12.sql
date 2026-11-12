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
 v_session_id uuid;
 v_received_at timestamptz;
 v_session_owner uuid;
 v_session_expires timestamptz;
 v_old_winner uuid;
 v_old_loser uuid;
 v_new_loser uuid;
 v_old_hcp text;
 v_new_hcp text;
 v_old_bonus integer;
 v_new_bonus integer;
 v_expected_player uuid;
 v_account_id uuid;
 v_deleted_at timestamptz;
 v_banned_until timestamptz;
BEGIN
 IF p_verdict NOT IN ('passed','flagged','review') THEN RAISE EXCEPTION 'Invalid verdict'; END IF;
 SELECT * INTO j FROM kf_audit.move_jobs WHERE id=p_id FOR UPDATE;
 IF NOT FOUND OR j.status <> 'processing' THEN RETURN FALSE; END IF;
 -- In the background, independently validate the saved signed-token evidence.
 -- Missing session rows alone are not proof of a forged identity.
 IF p_verdict='passed' AND j.move_data ? 'kf_session_id' THEN
   BEGIN
     v_session_id := (j.move_data->>'kf_session_id')::uuid;
     v_received_at := (j.move_data->>'kf_server_received_at')::timestamptz;
     SELECT s.user_id,s.not_after INTO v_session_owner,v_session_expires
       FROM auth.sessions s WHERE s.id=v_session_id;
     IF v_session_owner IS NULL THEN
       p_verdict:='review';p_detail:='Session no longer exists; historical identity needs manual review';
     ELSIF v_session_owner IS DISTINCT FROM j.player_id THEN
       p_verdict:='flagged';p_detail:='Verified session belongs to another player';
     ELSIF v_session_expires IS NOT NULL AND v_session_expires<=v_received_at THEN
       p_verdict:='flagged';p_detail:='Session expired before move reached server';
     END IF;
   EXCEPTION WHEN invalid_text_representation OR datetime_field_overflow THEN
     p_verdict:='review';p_detail:='Unparseable session evidence; manual review';
   END;
 END IF;
 -- Verify player ownership of the original turn without delaying the
 -- interactive move. The game player IDs are server-owned and immutable.
 IF p_verdict='passed' THEN
   SELECT CASE split_part(j.before_fen,' ',2)
     WHEN 'w' THEN g.white_id
     WHEN 'b' THEN g.black_id
     ELSE NULL END
   INTO v_expected_player FROM public.kf_games g WHERE g.id=j.game_id;
   IF v_expected_player IS NOT NULL AND v_expected_player IS DISTINCT FROM j.player_id THEN
     p_verdict:='flagged';p_detail:='Verified player was not owner of the move turn';
   END IF;
 END IF;
 -- Historical bans have no reliable start timestamp in auth.users; flag
 -- uncertainty for admin review rather than convicting retroactively.
 IF p_verdict='passed' AND j.move_data ? 'kf_server_received_at' THEN
   v_received_at:=(j.move_data->>'kf_server_received_at')::timestamptz;
   SELECT u.id,u.deleted_at,u.banned_until
     INTO v_account_id,v_deleted_at,v_banned_until
   FROM auth.users u WHERE u.id=j.player_id;
   IF v_account_id IS NULL THEN
     p_verdict:='review';p_detail:='Player account no longer exists; review historical authorization';
   ELSIF v_deleted_at IS NOT NULL AND v_deleted_at<=v_received_at THEN
     p_verdict:='flagged';p_detail:='Player account was deleted before the move';
   ELSIF v_banned_until IS NOT NULL AND v_banned_until>v_received_at THEN
     p_verdict:='review';p_detail:='Player account appears banned; verify ban began before this move';
   END IF;
 END IF;
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
    AND p_detail IN ('Move illegal from authoritative previous FEN','Verified session belongs to another player','Session expired before move reached server','Verified player was not owner of the move turn','Player account was deleted before the move')
    AND j.before_fen IS NOT NULL
    AND j.after_fen IS NOT NULL
    AND j.player_id IS NOT NULL
    AND j.move_data ? 'from'
    AND j.move_data ? 'to' THEN
   SELECT * INTO v_forfeit_game
     FROM public.kf_games
     WHERE id=j.game_id
     FOR UPDATE;

   IF FOUND AND v_forfeit_game.status IN ('active','completed')
      AND j.player_id IN (v_forfeit_game.white_id,v_forfeit_game.black_id) THEN
     v_new_winner := CASE WHEN j.player_id=v_forfeit_game.white_id
                          THEN v_forfeit_game.black_id
                          ELSE v_forfeit_game.white_id END;
     v_new_loser:=j.player_id;
     IF v_new_winner IS NOT NULL AND v_new_winner<>j.player_id THEN
       IF v_forfeit_game.status='active' THEN
         -- The normal completion trigger adjusts stats and the tournament bracket.
         UPDATE public.kf_games
         SET status='completed',completed_at=clock_timestamp(),
             winner_id=v_new_winner,
             result=CASE WHEN v_new_winner=v_forfeit_game.white_id THEN '1-0' ELSE '0-1' END,
             updated_at=clock_timestamp()
         WHERE id=j.game_id AND status='active';
         UPDATE kf_audit.alerts SET detail=left(p_detail || ' | Automatic forfeit while game was active',500)
         WHERE job_id=j.id;
       ELSIF COALESCE(v_forfeit_game.is_tournament,false) THEN
         -- A finished tournament result may already have advanced multiple rounds:
         -- keep brackets and trophy counts consistent pending administrator review.
         UPDATE kf_audit.alerts
         SET detail=left(p_detail || ' | Finished tournament: manual bracket adjudication required',500)
         WHERE job_id=j.id;
       ELSIF v_forfeit_game.winner_id IS DISTINCT FROM v_new_winner THEN
         -- Correct a completed, non-tournament game and its leaderboard stats
         -- in the same transaction. No replay of the completion trigger.
         v_old_winner:=v_forfeit_game.winner_id;
         v_old_loser:=CASE WHEN v_old_winner=v_forfeit_game.white_id
                            THEN v_forfeit_game.black_id
                          WHEN v_old_winner=v_forfeit_game.black_id
                            THEN v_forfeit_game.white_id ELSE NULL END;
         IF COALESCE(v_forfeit_game.is_bloodblade,false) THEN
           IF v_old_winner IS NOT NULL THEN
             UPDATE public.kf_player_stats SET bt_wins=GREATEST(0,COALESCE(bt_wins,0)-1),updated_at=now()
             WHERE user_id=v_old_winner;
             IF v_old_loser IS NOT NULL THEN
               UPDATE public.kf_player_stats SET bt_losses=GREATEST(0,COALESCE(bt_losses,0)-1),updated_at=now()
               WHERE user_id=v_old_loser;
             END IF;
           END IF;
           INSERT INTO public.kf_player_stats(user_id,bt_wins) VALUES(v_new_winner,1)
           ON CONFLICT(user_id) DO UPDATE SET bt_wins=COALESCE(public.kf_player_stats.bt_wins,0)+1,updated_at=now();
           INSERT INTO public.kf_player_stats(user_id,bt_losses) VALUES(v_new_loser,1)
           ON CONFLICT(user_id) DO UPDATE SET bt_losses=COALESCE(public.kf_player_stats.bt_losses,0)+1,updated_at=now();
         ELSE
           IF v_old_winner IS NOT NULL THEN
             v_old_hcp:=CASE WHEN v_old_winner=v_forfeit_game.white_id THEN v_forfeit_game.white_handicap ELSE v_forfeit_game.black_handicap END;
             v_old_bonus:=CASE WHEN v_old_hcp IN ('n','b') THEN 2 WHEN v_old_hcp='r' THEN 3 WHEN v_old_hcp='q' THEN 5 ELSE 1 END;
             UPDATE public.kf_player_stats SET wins=GREATEST(0,COALESCE(wins,0)-v_old_bonus),updated_at=now()
             WHERE user_id=v_old_winner;
             IF v_old_hcp IN ('n','b','r','q') THEN
               UPDATE public.kf_player_stats SET humiliation_losses=COALESCE(humiliation_losses,0)-1,updated_at=now()
               WHERE user_id=v_old_winner;
               IF v_old_loser IS NOT NULL THEN
                 UPDATE public.kf_player_stats SET humiliation_losses=COALESCE(humiliation_losses,0)+1,updated_at=now()
                 WHERE user_id=v_old_loser;
               END IF;
             END IF;
           END IF;
           v_new_hcp:=CASE WHEN v_new_winner=v_forfeit_game.white_id THEN v_forfeit_game.white_handicap ELSE v_forfeit_game.black_handicap END;
           v_new_bonus:=CASE WHEN v_new_hcp IN ('n','b') THEN 2 WHEN v_new_hcp='r' THEN 3 WHEN v_new_hcp='q' THEN 5 ELSE 1 END;
           INSERT INTO public.kf_player_stats(user_id,wins) VALUES(v_new_winner,v_new_bonus)
           ON CONFLICT(user_id) DO UPDATE SET wins=COALESCE(public.kf_player_stats.wins,0)+v_new_bonus,updated_at=now();
           IF v_new_hcp IN ('n','b','r','q') THEN
             INSERT INTO public.kf_player_stats(user_id,humiliation_losses) VALUES(v_new_winner,1)
             ON CONFLICT(user_id) DO UPDATE SET humiliation_losses=COALESCE(public.kf_player_stats.humiliation_losses,0)+1,updated_at=now();
             INSERT INTO public.kf_player_stats(user_id,humiliation_losses) VALUES(v_new_loser,-1)
             ON CONFLICT(user_id) DO UPDATE SET humiliation_losses=COALESCE(public.kf_player_stats.humiliation_losses,0)-1,updated_at=now();
           END IF;
         END IF;
         UPDATE public.kf_games
         SET winner_id=v_new_winner,
             result=CASE WHEN v_new_winner=v_forfeit_game.white_id THEN '1-0' ELSE '0-1' END,
             updated_at=clock_timestamp()
         WHERE id=j.game_id AND status='completed';
         UPDATE kf_audit.alerts SET detail=left(p_detail || ' | Completed game result and stats corrected',500)
         WHERE job_id=j.id;
       ELSE
         UPDATE kf_audit.alerts SET detail=left(p_detail || ' | Already awarded to the innocent opponent',500)
         WHERE job_id=j.id;
       END IF;
     END IF;
   END IF;
 END IF;
 RETURN TRUE;
END;
$function$
;
