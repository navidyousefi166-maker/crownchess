CREATE OR REPLACE FUNCTION public.kf_admin_move_audit_alerts(p_limit integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'kf_audit', 'pg_temp'
AS $function$
BEGIN
 IF auth.uid() IS DISTINCT FROM 'cc80cc38-f476-4edd-8efc-45e2722f3c4f'::uuid THEN
  RAISE EXCEPTION 'Owner access required';
 END IF;
 RETURN COALESCE((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.detected_at DESC)
 FROM (SELECT id,game_id,player_id,verdict,detail,move_data,detected_at
       FROM kf_audit.alerts ORDER BY id DESC LIMIT LEAST(GREATEST(p_limit,1),100)) a), '[]'::jsonb);
END;
$function$
;
