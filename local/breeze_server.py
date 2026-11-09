#!/usr/bin/env python3
"""HAUS Type 本機辨識常駐程式：載入一次 Breeze-ASR-25（MLX fp16），之後從 stdin 收請求、從 stdout 回結果。

由 HAUS Type 以子行程啟動，一行一個 JSON：
  啟動完成 → {"ready": true, "load_s": 0.22}
  請求 ← {"id": "...", "wav": "/path/to/16k.wav", "prompt": "詞彙提示（80 字內）"}
  回覆 → {"id": "...", "text": "...", "ms": 812}  或  {"id": "...", "error": "..."}

錄音只在這台 Mac 上處理，不送出網路。
"""

from __future__ import annotations

import argparse
import importlib
import json
import sys
import time


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True, help="mlx_whisper 格式的模型資料夾（config.json＋weights.safetensors）")
    args = ap.parse_args()

    try:
        import mlx.core as mx
        import mlx_whisper
        from mlx_whisper.load_models import load_model
    except Exception as e:  # 沒裝 mlx_whisper：回報後結束，HAUS Type 會退回雲端
        print(json.dumps({"ready": False, "error": f"缺少 mlx_whisper：{e}"}, ensure_ascii=False), flush=True)
        return

    t0 = time.perf_counter()
    try:
        model = load_model(args.model, dtype=mx.float16)
        mx.eval(model.parameters())
    except Exception as e:
        print(json.dumps({"ready": False, "error": f"模型載入失敗：{e}"}, ensure_ascii=False), flush=True)
        return
    # mlx_whisper.transcribe 會依路徑重新載入模型；先放進它的快取，之後每次都直接用
    tr = importlib.import_module("mlx_whisper.transcribe")
    tr.ModelHolder.model = model
    tr.ModelHolder.model_path = args.model
    print(json.dumps({"ready": True, "load_s": round(time.perf_counter() - t0, 2)}), flush=True)

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        rid = req.get("id", "")
        try:
            t = time.perf_counter()
            r = mlx_whisper.transcribe(
                req["wav"],
                path_or_hf_repo=args.model,
                language="zh",
                initial_prompt=req.get("prompt") or None,
                condition_on_previous_text=False,
                fp16=True,
            )
            out = {"id": rid, "text": r["text"].strip(), "ms": int((time.perf_counter() - t) * 1000)}
        except Exception as e:
            out = {"id": rid, "error": str(e)}
        print(json.dumps(out, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
