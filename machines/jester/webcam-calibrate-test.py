"""Hermetic self-test for webcam-calibrate.py's fit_ccm() math.

Synthesises a raw SGRBG10 frame holding a rendered ColorChecker under a
known CCM, known WB gains, a known exposure scalar and black level, with
seeded (reproducible) shot-noise and a mild blur -- a noiseless bit-exact
round-trip would pass even with a sign/transpose/row-column bug in
fit_ccm(), since inverting and re-applying the same matrix is tautological
without some perturbation in between (advisor review flagged this before
the noise/blur were added). Decodes it with the real read_raw()/
debayer_bin()/grid_quads_from_corners()/sample_quad_mean() pipeline, runs
fit_ccm(), and asserts the recovered matrix matches the known one within
2% elementwise.

Run via `python3 webcam-calibrate-test.py` in an env with numpy + opencv4
(wired as the `webcam-calibrate-test` nix flake check) -- per this repo's
Nix policy, never with a bare local python3.
"""

import importlib.util
import os
import tempfile

import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
_SPEC = importlib.util.spec_from_file_location("webcam_calibrate", os.path.join(_HERE, "webcam-calibrate.py"))
wc = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(wc)

RNG = np.random.default_rng(20260819)  # fixed seed: deterministic/hermetic

KNOWN_BLACK_LEVEL = 64
KNOWN_GAINS = np.array([1.3, 1.0, 1.15])  # illuminant WB gains (R, G, B)
KNOWN_K = 1.2  # chart brighter than the reference by this exposure scalar

# Deliberately not diagonal or identity, so a sign/transpose/row-column
# mistake in fit_ccm() would miss by more than 2%. Rows sum to 1.
KNOWN_M = np.array(
    [
        [1.55, -0.40, -0.15],
        [-0.20, 1.35, -0.15],
        [-0.05, -0.55, 1.60],
    ]
)
assert np.allclose(KNOWN_M.sum(axis=1), 1.0)

PATCH_COLS, PATCH_ROWS = 6, 4
BINNED_W, BINNED_H = wc.WIDTH // 2, wc.HEIGHT // 2
MARGIN_FRAC = 0.08


def synth_corners():
    x0, x1 = BINNED_W * MARGIN_FRAC, BINNED_W * (1 - MARGIN_FRAC)
    y0, y1 = BINNED_H * MARGIN_FRAC, BINNED_H * (1 - MARGIN_FRAC)
    return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]


def render_raw_bin(path):
    """Write a synthetic raw SGRBG10 capture (matching read_raw()'s
    expected shape) to `path`, and return the --corners four points for
    the patch grid it drew."""
    ref = wc.REFERENCE_LINEAR  # (24, 3) linear sRGB, patch order = grid order
    m_inv = np.linalg.inv(KNOWN_M)
    native = (ref @ m_inv.T) / KNOWN_K / KNOWN_GAINS  # invert the runtime pipeline
    if native.min() < 0 or native.max() > 1:
        raise AssertionError("test fixture out of [0, 1] gamut; adjust KNOWN_* constants")

    corners = synth_corners()
    (x0, y0), (x1, _), (_, y1), _ = corners
    binned = np.zeros((BINNED_H, BINNED_W, 3))
    for i in range(PATCH_ROWS):
        for j in range(PATCH_COLS):
            idx = i * PATCH_COLS + j
            cx0, cx1 = int(round(x0 + (x1 - x0) * j / PATCH_COLS)), int(round(x0 + (x1 - x0) * (j + 1) / PATCH_COLS))
            cy0, cy1 = int(round(y0 + (y1 - y0) * i / PATCH_ROWS)), int(round(y0 + (y1 - y0) * (i + 1) / PATCH_ROWS))
            binned[cy0:cy1, cx0:cx1] = native[idx]

    # Mild blur: a real demosaic mixes neighbouring pixels, so a perfectly
    # flat synthetic patch would be an easier case than reality.
    kernel = np.array([1.0, 2.0, 1.0]) / 4.0
    for axis in (0, 1):
        binned = np.apply_along_axis(lambda m: np.convolve(m, kernel, mode="same"), axis, binned)
    binned = np.clip(binned, 0.0, 1.0)

    full_scale = wc.FULL_SCALE - KNOWN_BLACK_LEVEL
    raw = np.zeros((BINNED_H * 2, BINNED_W * 2), dtype=np.float64)
    r, g, b = binned[..., 0], binned[..., 1], binned[..., 2]
    raw[0::2, 0::2] = g  # SGRBG row0: G R
    raw[0::2, 1::2] = r
    raw[1::2, 0::2] = b  # row1: B G
    raw[1::2, 1::2] = g
    raw = raw * full_scale + KNOWN_BLACK_LEVEL

    noise = RNG.normal(0.0, np.sqrt(np.clip(raw, 1.0, None)) * 0.15, raw.shape)
    raw = np.clip(np.round(raw + noise), 0, wc.FULL_SCALE).astype("<u2")

    padded = np.zeros((wc.HEIGHT, wc.STRIDE_PX), dtype="<u2")
    padded[:, : wc.WIDTH] = raw
    padded.tofile(path)
    return corners


def main():
    with tempfile.TemporaryDirectory() as td:
        raw_path = os.path.join(td, "raw.bin")
        corners = render_raw_bin(raw_path)

        raw = wc.read_raw(raw_path)
        linear = wc.debayer_bin(raw, KNOWN_BLACK_LEVEL)
        quads = wc.grid_quads_from_corners(corners)
        samples = np.array([wc.sample_quad_mean(linear, q) for q in quads])
        result = wc.fit_ccm(samples)

    print("recovered gains:", result["gains"], " k:", result["k"])
    print("recovered M:\n", result["M"])
    print("known M:\n", KNOWN_M)
    print(f"mean/max residual: {np.mean(result['resid']) * 100:.2f}% / {np.max(result['resid']) * 100:.2f}%")

    assert not result["rejected"], f"unexpected saturated patches: {result['rejected']}"
    assert len(result["usable"]) == 24

    # Absolute, not relative, difference: matrix entries live on a natural
    # O(1) scale (rows sum to 1), and several of KNOWN_M's are close to
    # zero (e.g. -0.05) where a relative measure blows up a millirad-scale
    # miss into a huge percentage despite the fit being accurate.
    max_err = np.abs(result["M"] - KNOWN_M).max()
    print(f"max elementwise absolute error vs. known M: {max_err * 100:.2f}pp")
    assert max_err < 0.02, f"recovered CCM differs from the known one by {max_err * 100:.2f}pp (> 2)"

    print("webcam-calibrate-test: PASS")


if __name__ == "__main__":
    main()
