-- Kingsfall function ACL snapshot before hardening, 2026-11-12
-- Only original EXECUTE grants are restored; function bodies are unchanged.
BEGIN;
-- Original ACL: {=X/postgres,postgres=X/postgres,authenticated=X/postgres}
REVOKE ALL ON FUNCTION public.kf_apply_humiliation(p_game_id uuid, p_square text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.kf_apply_humiliation(p_game_id uuid, p_square text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.kf_apply_humiliation(p_game_id uuid, p_square text) TO authenticated;
-- Original ACL: NULL (default PUBLIC EXECUTE)
REVOKE ALL ON FUNCTION public.kf_auto_handle_absent_players() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.kf_auto_handle_absent_players() TO PUBLIC;
-- Original ACL: NULL (default PUBLIC EXECUTE)
REVOKE ALL ON FUNCTION public.kf_auto_start_tournament() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.kf_auto_start_tournament() TO PUBLIC;
-- Original ACL: NULL (default PUBLIC EXECUTE)
REVOKE ALL ON FUNCTION public.kf_block_tournament_draw_offers() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.kf_block_tournament_draw_offers() TO PUBLIC;
-- Original ACL: NULL (default PUBLIC EXECUTE)
REVOKE ALL ON FUNCTION public.kf_cancel_quick_play() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.kf_cancel_quick_play() TO PUBLIC;
-- Original ACL: NULL (default PUBLIC EXECUTE)
REVOKE ALL ON FUNCTION public.kf_cancel_tournament_registration() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.kf_cancel_tournament_registration() TO PUBLIC;
-- Original ACL: NULL (default PUBLIC EXECUTE)
REVOKE ALL ON FUNCTION public.kf_ensure_match_game(p_match_id uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.kf_ensure_match_game(p_match_id uuid) TO PUBLIC;
-- Original ACL: NULL (default PUBLIC EXECUTE)
REVOKE ALL ON FUNCTION public.kf_get_my_history(p_limit integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.kf_get_my_history(p_limit integer) TO PUBLIC;
-- Original ACL: NULL (default PUBLIC EXECUTE)
REVOKE ALL ON FUNCTION public.kf_get_next_tournament() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.kf_get_next_tournament() TO PUBLIC;
-- Original ACL: NULL (default PUBLIC EXECUTE)
REVOKE ALL ON FUNCTION public.kf_guard_tournament_match_winner() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.kf_guard_tournament_match_winner() TO PUBLIC;
-- Original ACL: NULL (default PUBLIC EXECUTE)
REVOKE ALL ON FUNCTION public.kf_handle_game_completion() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.kf_handle_game_completion() TO PUBLIC;
-- Original ACL: NULL (default PUBLIC EXECUTE)
REVOKE ALL ON FUNCTION public.kf_handle_new_user() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.kf_handle_new_user() TO PUBLIC;
-- Original ACL: NULL (default PUBLIC EXECUTE)
REVOKE ALL ON FUNCTION public.kf_join_bloodblade() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.kf_join_bloodblade() TO PUBLIC;
-- Original ACL: NULL (default PUBLIC EXECUTE)
REVOKE ALL ON FUNCTION public.kf_join_quick_play(p_is_roulette boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.kf_join_quick_play(p_is_roulette boolean) TO PUBLIC;
-- Original ACL: NULL (default PUBLIC EXECUTE)
REVOKE ALL ON FUNCTION public.kf_offer_draw(p_game_id uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.kf_offer_draw(p_game_id uuid) TO PUBLIC;
-- Original ACL: {=X/postgres,postgres=X/postgres,authenticated=X/postgres}
REVOKE ALL ON FUNCTION public.kf_player_joined_game(p_game_id uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.kf_player_joined_game(p_game_id uuid) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.kf_player_joined_game(p_game_id uuid) TO authenticated;
-- Original ACL: NULL (default PUBLIC EXECUTE)
REVOKE ALL ON FUNCTION public.kf_process_first_move_deadlines() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.kf_process_first_move_deadlines() TO PUBLIC;
-- Original ACL: NULL (default PUBLIC EXECUTE)
REVOKE ALL ON FUNCTION public.kf_register_tournament() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.kf_register_tournament() TO PUBLIC;
-- Original ACL: NULL (default PUBLIC EXECUTE)
REVOKE ALL ON FUNCTION public.kf_report_match_result(p_match_id uuid, p_winner_id uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.kf_report_match_result(p_match_id uuid, p_winner_id uuid) TO PUBLIC;
-- Original ACL: NULL (default PUBLIC EXECUTE)
REVOKE ALL ON FUNCTION public.kf_resolve_absent_game(p_game_id uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.kf_resolve_absent_game(p_game_id uuid) TO PUBLIC;
-- Original ACL: NULL (default PUBLIC EXECUTE)
REVOKE ALL ON FUNCTION public.kf_tournament_resolve_draw() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.kf_tournament_resolve_draw() TO PUBLIC;
COMMIT;
