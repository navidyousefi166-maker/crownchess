BEGIN;
CREATE TABLE IF NOT EXISTS kf_audit.tournament_sanctions (
 job_id bigint PRIMARY KEY REFERENCES kf_audit.move_jobs(id),
 game_id uuid NOT NULL,
 player_id uuid NOT NULL,
 tournament_id uuid NOT NULL,
 source_match_id uuid NOT NULL,
 target_match_id uuid,
 status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','applied','review')),
 reason text,
 note text,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 resolved_at timestamptz,
 UNIQUE(game_id,player_id)
);
ALTER TABLE kf_audit.tournament_sanctions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE kf_audit.tournament_sanctions FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.kf_guard_tournament_match_winner()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_game_found boolean := false;
        v_auto_allowed boolean := false;
        BEGIN
            IF NEW.winner_id IS NULL
                   OR NEW.winner_id IS NOT DISTINCT FROM OLD.winner_id THEN
                           RETURN NEW;
                               END IF;

                                   IF NEW.winner_id IS DISTINCT FROM NEW.player1_id
                                          AND NEW.winner_id IS DISTINCT FROM NEW.player2_id THEN
                                                  RAISE EXCEPTION 'Invalid tournament winner';
                                                      END IF;

                                                          -- Preserve legitimate BYE winners.
                                                              IF NEW.player1_id IS NULL OR NEW.player2_id IS NULL THEN
                                                                      IF NEW.player1_id IS NOT NULL
                                                                                 AND NEW.player2_id IS NULL
                                                                                            AND NEW.winner_id = NEW.player1_id THEN
                                                                                                        RETURN NEW;
                                                                                                                ELSIF NEW.player2_id IS NOT NULL
                                                                                                                           AND NEW.player1_id IS NULL
                                                                                                                                      AND NEW.winner_id = NEW.player2_id THEN
                                                                                                                                                  RETURN NEW;
                                                                                                                                                          ELSE
                                                                                                                                                                      RAISE EXCEPTION 'Invalid BYE winner';
                                                                                                                                                                              END IF;
                                                                                                                                                                                  END IF;

                                                                                                                                                                                      -- First, validate against a real completed game.
                                                                                                                                                                                          SELECT EXISTS (
                                                                                                                                                                                                  SELECT 1
                                                                                                                                                                                                          FROM public.kf_games g
                                                                                                                                                                                                                  WHERE g.status = 'completed'
                                                                                                                                                                                                                            AND g.winner_id = NEW.winner_id
                                                                                                                                                                                                                                      AND (
                                                                                                                                                                                                                                                    (
                                                                                                                                                                                                                                                                      COALESCE(NEW.game_id, OLD.game_id) IS NOT NULL
                                                                                                                                                                                                                                                                                        AND g.id = COALESCE(NEW.game_id, OLD.game_id)
                                                                                                                                                                                                                                                                                                      )
                                                                                                                                                                                                                                                                                                                    OR
                                                                                                                                                                                                                                                                                                                                  (
                                                                                                                                                                                                                                                                                                                                                    COALESCE(NEW.game_id, OLD.game_id) IS NULL
                                                                                                                                                                                                                                                                                                                                                                      AND g.tournament_match_id = OLD.id
                                                                                                                                                                                                                                                                                                                                                                                    )
                                                                                                                                                                                                                                                                                                                                                                                              )
                                                                                                                                                                                                                                                                                                                                                                                                  )
                                                                                                                                                                                                                                                                                                                                                                                                      INTO v_game_found;

                                                                                                                                                                                                                                                                                                                                                                                                          IF v_game_found THEN
                                                                                                                                                                                                                                                                                                                                                                                                                  RETURN NEW;
                                                                                                                                                                                                                                                                                                                                                                                                                      END IF;

                                                                                                                                                                                                                                                                                                                                                                                                                          -- Confirmed sanctioned next-match result (normal guard stays active elsewhere).
 IF COALESCE(current_setting('kf.tournament_sanction_job',true),'') ~ '^[0-9]+$'
    AND EXISTS (
      SELECT 1 FROM kf_audit.tournament_sanctions s
      JOIN kf_audit.move_jobs j ON j.id=s.job_id
      JOIN public.kf_tournament_matches src ON src.id=s.source_match_id
      WHERE s.job_id=current_setting('kf.tournament_sanction_job',true)::bigint
        AND s.status='pending' AND j.status='flagged'
        AND s.tournament_id=NEW.tournament_id
        AND src.tournament_id=NEW.tournament_id
        AND src.round+1=NEW.round
        AND src.winner_id=s.player_id AND src.status='completed'
        AND OLD.status IN ('pending','active')
        AND OLD.id=NEW.id
        AND s.player_id IN (OLD.player1_id,OLD.player2_id)
        AND NEW.winner_id=CASE WHEN OLD.player1_id=s.player_id
                                THEN OLD.player2_id ELSE OLD.player1_id END
        AND OLD.winner_id IS NULL
    ) THEN
   RETURN NEW;
 END IF;

 -- Special permission only for scheduled automatic resolution
                                                                                                                                                                                                                                                                                                                                                                                                                              -- of a pending match that has no associated game.
                                                                                                                                                                                                                                                                                                                                                                                                                                  v_auto_allowed :=
                                                                                                                                                                                                                                                                                                                                                                                                                                          COALESCE(
                                                                                                                                                                                                                                                                                                                                                                                                                                                      current_setting(
                                                                                                                                                                                                                                                                                                                                                                                                                                                                      'kf.allow_uncreated_tournament_winner',
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      true
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  ),
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              ''
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      ) = 'on'
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              AND OLD.status = 'pending'
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      AND OLD.game_id IS NULL
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              AND NEW.game_id IS NULL
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      AND EXISTS (
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  SELECT 1
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              FROM public.kf_tournaments t
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          WHERE t.id = OLD.tournament_id
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        AND t.status = 'active'
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      AND t.scheduled_at <= now() - interval '1 minute'
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              )
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      AND NOT EXISTS (
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  SELECT 1
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              FROM public.kf_games g
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          WHERE g.tournament_match_id = OLD.id
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  );

                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      IF v_auto_allowed THEN
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              RETURN NEW;
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  END IF;

                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      RAISE EXCEPTION
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              'Winner does not match the completed tournament game';

                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              END;
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              $function$;
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
         -- A confirmed infraction after a tournament game is finished:
         -- preserve the finished result and queue a NEXT-match forfeit.
         -- Only a player who actually advanced from this match may be sanctioned.
         INSERT INTO kf_audit.tournament_sanctions
           (job_id,game_id,player_id,tournament_id,source_match_id,status,reason)
         SELECT j.id,j.game_id,j.player_id,tm.tournament_id,tm.id,
                'pending',left(p_detail,500)
         FROM public.kf_tournament_matches tm
         WHERE (tm.id=v_forfeit_game.tournament_match_id OR tm.game_id=j.game_id)
           AND tm.status='completed' AND tm.winner_id=j.player_id
         ON CONFLICT (game_id,player_id) DO NOTHING;
         UPDATE kf_audit.alerts
         SET detail=left(p_detail || ' | Finished tournament: next-match sanction queued when applicable; otherwise admin review',500)
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
$function$;
CREATE OR REPLACE FUNCTION public.kf_process_tournament_sanctions()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pg_catalog','public','kf_audit','pg_temp'
AS $proc$
DECLARE
 s kf_audit.tournament_sanctions%ROWTYPE;
 src public.kf_tournament_matches%ROWTYPE;
 target public.kf_tournament_matches%ROWTYPE;
 g public.kf_games%ROWTYPE;
 nextgame public.kf_games%ROWTYPE;
 t public.kf_tournaments%ROWTYPE;
 opponent uuid;
 explanation text;
BEGIN
 FOR s IN SELECT * FROM kf_audit.tournament_sanctions
          WHERE status='pending' ORDER BY created_at
          FOR UPDATE SKIP LOCKED LOOP
   target:=NULL;
   nextgame:=NULL;
   SELECT * INTO g FROM public.kf_games WHERE id=s.game_id;
   SELECT * INTO src FROM public.kf_tournament_matches
    WHERE id=s.source_match_id;
   SELECT * INTO t FROM public.kf_tournaments
    WHERE id=s.tournament_id;
   explanation:=NULL;
   IF NOT FOUND OR t.status<>'active' THEN
     explanation:='Tournament has finished or is unavailable; admin review required';
   ELSIF g.id IS NULL OR g.status<>'completed' OR NOT COALESCE(g.is_tournament,false)
      OR src.id IS NULL OR src.status<>'completed'
      OR src.winner_id IS DISTINCT FROM s.player_id
      OR src.tournament_id IS DISTINCT FROM s.tournament_id THEN
     explanation:='Source match cannot be safely connected to the confirmed cheating winner';
   END IF;
   IF explanation IS NULL THEN
     SELECT * INTO target FROM public.kf_tournament_matches
      WHERE tournament_id=s.tournament_id
        AND round=src.round+1
        AND (player1_id=s.player_id OR player2_id=s.player_id)
      ORDER BY match_index LIMIT 1 FOR UPDATE;
     IF NOT FOUND THEN
       -- The preceding round may still be running; retry on the next cron.
       CONTINUE;
     END IF;
     IF target.status='completed' OR target.winner_id IS NOT NULL THEN
       explanation:='Next match already finished; manual adjudication required';
     ELSE
       opponent:=CASE WHEN target.player1_id=s.player_id
                       THEN target.player2_id ELSE target.player1_id END;
       IF opponent IS NULL OR opponent=s.player_id THEN
         -- Do not forfeit a BYE or an as-yet-unassigned opponent.
         CONTINUE;
       END IF;
       SELECT * INTO nextgame FROM public.kf_games
        WHERE id=target.game_id OR tournament_match_id=target.id
        ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
       IF FOUND THEN
         IF nextgame.status<>'active' THEN
           explanation:='Next game already finished or is not active; admin review required';
         ELSIF NOT COALESCE(nextgame.is_tournament,false)
            OR NOT (nextgame.white_id = ANY(ARRAY[s.player_id,opponent]))
            OR NOT (nextgame.black_id = ANY(ARRAY[s.player_id,opponent]))
            OR nextgame.white_id=nextgame.black_id THEN
           explanation:='Next-game participants do not match sanctioned pairing; admin review';
         ELSE
           UPDATE public.kf_games
           SET status='completed',
               result=CASE WHEN opponent=white_id THEN '1-0' ELSE '0-1' END,
               winner_id=opponent,completed_at=clock_timestamp(),updated_at=clock_timestamp()
           WHERE id=nextgame.id AND status='active';
           IF NOT FOUND THEN
             explanation:='Next game finished concurrently; admin review';
           END IF;
         END IF;
       ELSE
         -- No actual game exists: advance via the standard bracket function
         -- without inventing a fake chess game or touching player crowns.
         PERFORM set_config('kf.tournament_sanction_job',s.job_id::text,true);
         PERFORM public.kf_advance_tournament_auto(target.id,opponent);
         PERFORM set_config('kf.tournament_sanction_job','',true);
         IF NOT EXISTS (SELECT 1 FROM public.kf_tournament_matches
                        WHERE id=target.id AND status='completed'
                          AND winner_id=opponent) THEN
           explanation:='Could not safely finalize unplayed next match; admin review';
         END IF;
       END IF;
       IF explanation IS NULL THEN
         UPDATE kf_audit.tournament_sanctions
           SET status='applied',target_match_id=target.id,resolved_at=clock_timestamp(),
               note='Confirmed illegal move: automatic loss in next tournament match'
           WHERE job_id=s.job_id;
         UPDATE kf_audit.alerts
           SET detail=left(reason_label.detail || ' | Automatic forfeit in next tournament match',500)
           FROM (SELECT COALESCE(s.reason,'Confirmed cheat') AS detail) reason_label
           WHERE job_id=s.job_id;
       END IF;
     END IF;
   END IF;
   IF explanation IS NOT NULL THEN
     UPDATE kf_audit.tournament_sanctions
       SET status='review',target_match_id=CASE WHEN target.id IS NULL THEN NULL ELSE target.id END,
           note=explanation,resolved_at=clock_timestamp()
       WHERE job_id=s.job_id;
     UPDATE kf_audit.alerts SET detail=left(COALESCE(s.reason,'Confirmed cheat') || ' | ' || explanation,500)
       WHERE job_id=s.job_id;
   END IF;
 END LOOP;
END
$proc$;
REVOKE ALL ON FUNCTION public.kf_process_tournament_sanctions() FROM PUBLIC,anon,authenticated;
COMMIT;
SELECT cron.schedule('kf-tournament-cheat-sanctions-10s','10 seconds','SELECT public.kf_process_tournament_sanctions();');