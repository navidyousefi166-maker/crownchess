#!/usr/bin/env python3
"""Post-game, review-only chess engine indicators for Kingsfall."""
import io
import json
import os
import urllib.parse
import urllib.request

import chess
import chess.engine
import chess.pgn

BASE = "https://cyqactlxetfjyjvklpox.supabase.co/functions/v1/kf-engine-analysis-queue"
AUDIENCE = "kingsfall-anticheat-v1"
OPENING_PLIES = 8
MAX_PLIES = 160
TIME_PER_POSITION = 0.09
TIME_FOR_PLAYED_MOVE = 0.05


def get_oidc_token():
    url = os.environ["ACTIONS_ID_TOKEN_REQUEST_URL"]
    separator = "&" if "?" in url else "?"
    url = url + separator + urllib.parse.urlencode({"audience": AUDIENCE})
    req = urllib.request.Request(url, headers={
        "Authorization": "bearer " + os.environ["ACTIONS_ID_TOKEN_REQUEST_TOKEN"]
    })
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.load(resp)["value"]


def endpoint(token, payload):
    request = urllib.request.Request(
        BASE,
        data=json.dumps(payload, separators=(",", ":")).encode(),
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=45) as response:
        return json.load(response)


def evaluate_position(engine, board, played):
    options = chess.engine.Limit(time=TIME_PER_POSITION, depth=12)
    candidates = engine.analyse(board, options, multipv=min(3, board.legal_moves.count()))
    if isinstance(candidates, dict):
        candidates = [candidates]
    if not candidates:
        raise ValueError("Engine returned no candidates")
    best = candidates[0]["score"].pov(board.turn).score(mate_score=1000)
    top_moves = [c["pv"][0] for c in candidates if c.get("pv")]
    if played in top_moves:
        index = top_moves.index(played)
        actual = candidates[index]["score"].pov(board.turn).score(mate_score=1000)
    else:
        actual_info = engine.analyse(
            board,
            chess.engine.Limit(time=TIME_FOR_PLAYED_MOVE, depth=10),
            root_moves=[played],
        )
        actual = actual_info["score"].pov(board.turn).score(mate_score=1000)
    return played == top_moves[0], played in top_moves, max(0, best - actual)


def analyze_game(engine, item):
    game_id = str(item.get("game_id", ""))
    pgn = item.get("pgn")
    color = item.get("color")
    if not pgn or color not in ("w", "b"):
        return {"game_id": game_id, "status": "no_replay"}
    parsed = chess.pgn.read_game(io.StringIO(pgn))
    if parsed is None or parsed.errors:
        return {"game_id": game_id, "status": "invalid_pgn"}
    board = parsed.board()
    target = chess.WHITE if color == "w" else chess.BLACK
    metrics = {"total": 0, "top1": 0, "top3": 0, "losses": [], "blunders": 0}
    count = 0
    for move in parsed.mainline_moves():
        count += 1
        if count > MAX_PLIES:
            break
        if move not in board.legal_moves:
            return {"game_id": game_id, "status": "invalid_move"}
        if count > OPENING_PLIES and board.turn == target and board.legal_moves.count() > 1 and not board.is_game_over():
            first, third, cp_loss = evaluate_position(engine, board, move)
            metrics["total"] += 1
            metrics["top1"] += int(first)
            metrics["top3"] += int(third)
            metrics["losses"].append(cp_loss)
            metrics["blunders"] += int(cp_loss >= 200)
        board.push(move)
    if metrics["total"] == 0:
        return {"game_id": game_id, "status": "insufficient_moves", "plies": count}
    n = metrics["total"]
    return {
        "game_id": game_id,
        "status": "analyzed",
        "plies": count,
        "evaluated_moves": n,
        "top1_pct": round(100 * metrics["top1"] / n, 1),
        "top3_pct": round(100 * metrics["top3"] / n, 1),
        "average_centipawn_loss": round(sum(metrics["losses"]) / n, 1),
        "large_errors": metrics["blunders"],
    }


def analyze(engine, job):
    snapshots = job.get("game_snapshots")
    if not isinstance(snapshots, list) or len(snapshots) != 3:
        raise ValueError("Three game snapshots are required")
    results = [analyze_game(engine, x) for x in snapshots]
    valid = [r for r in results if r["status"] == "analyzed"]
    total = sum(r["evaluated_moves"] for r in valid)
    aggregate = None
    if total:
        aggregate = {
            "evaluated_moves": total,
            "weighted_top1_pct": round(sum(r["top1_pct"] * r["evaluated_moves"] for r in valid) / total, 1),
            "weighted_top3_pct": round(sum(r["top3_pct"] * r["evaluated_moves"] for r in valid) / total, 1),
            "weighted_average_centipawn_loss": round(sum(r["average_centipawn_loss"] * r["evaluated_moves"] for r in valid) / total, 1),
        }
    return {
        "engine": "Stockfish (Ubuntu package)",
        "opening_plies_skipped": OPENING_PLIES,
        "depth_cap": 12,
        "games": results,
        "aggregate": aggregate,
        "interpretation": "Review-only indicators; accuracy and engine agreement never establish cheating on their own.",
    }


def main():
    token = get_oidc_token()
    with chess.engine.SimpleEngine.popen_uci("/usr/games/stockfish") as engine:
        engine.configure({"Threads": 1, "Hash": 32})
        for _ in range(3):
            job = endpoint(token, {"operation": "claim"}).get("job")
            if not job:
                print("No more anti-cheat cases to analyze.")
                break
            job_id = job["id"]
            try:
                report = analyze(engine, job)
                result = endpoint(token, {"operation": "finish", "id": job_id, "report": report})
                print("Case", job_id, "saved:", result.get("saved"))
            except Exception as exc:
                print("Case", job_id, "failed:", type(exc).__name__)
                endpoint(token, {"operation": "finish", "id": job_id, "error": str(exc)[:300]})


if __name__ == "__main__":
    main()
