"""Optional offline quality check: python test/evaluate-correction.py [cached-model-id]."""
import importlib.util
import json
from pathlib import Path
import sys
import time

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('asr', root / 'scripts/local-asr-server.py')
asr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(asr)
model = sys.argv[1] if len(sys.argv) > 1 else asr.DEFAULT_TEXT_MODEL
engine = asr.LocalTextModel()
failed = 0
for case in json.loads((root / 'test/correction-quality.json').read_text()):
    start = time.monotonic()
    try:
        result = engine.correct(model, case['input'], lambda: False)
        passed = all(text in result for text in case['contains']) and not any(text in result for text in case['excludes'])
    except Exception as error:
        passed, result = False, str(error)
    failed += not passed
    print(f"{'PASS' if passed else 'FAIL'} {time.monotonic() - start:.2f}s: {result}", flush=True)
raise SystemExit(bool(failed))
