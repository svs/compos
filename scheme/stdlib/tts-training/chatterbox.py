"""chatterbox.py -- one take with Chatterbox, for tts-training.

usage: chatterbox.py VOICE OUT TEXT EXAGGERATION CFG
"""
import sys

import torch
import torchaudio as ta
from chatterbox.tts import ChatterboxTTS

voice, out, text, exaggeration, cfg = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4]), float(sys.argv[5])
device = "mps" if torch.backends.mps.is_available() else "cpu"
try:
    model = ChatterboxTTS.from_pretrained(device=device)
except Exception:
    device = "cpu"
    model = ChatterboxTTS.from_pretrained(device=device)
wav = model.generate(text, audio_prompt_path=voice, exaggeration=exaggeration, cfg_weight=cfg)
ta.save(out, wav, model.sr)
print("OK", device)
