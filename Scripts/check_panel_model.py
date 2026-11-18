"""Runs the app's Core ML panel model on a test page and checks it agrees with the original network.
Used by CI so a broken model can never reach a release."""
import sys, numpy as np, coremltools as ct
data = np.load(sys.argv[2])
model = ct.models.MLModel(sys.argv[1])
out = model.predict({"image": data["x"].astype(np.float32)})["scores"]
out = np.asarray(out).reshape(1, 224, 224, 3)
agree = (out.argmax(-1) == data["cls"]).mean()
print(f"Panel model agreement with the original network: {agree:.4f}")
if agree < 0.97:
    print("::error::The panel model gives different answers from the original network.")
    sys.exit(1)
