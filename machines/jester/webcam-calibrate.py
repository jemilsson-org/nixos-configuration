"""Colour-correction-matrix (CCM) calibration for jester's OV2740 webcam.

Fits the 3x3 matrix in machines/jester/ov2740-tuning.yaml's `Ccm:` block
from a photographed 24-patch ColorChecker Classic. Two subcommands:

  webcam-calibrate capture [--out DIR]
      Grabs 30 raw frames from the camera (stops/restarts wireplumber
      around the capture, since it holds the device exclusively), keeps
      the last one (so auto-gain has settled) as DIR/raw.bin, and writes
      a quick-look DIR/preview.png so you can check framing before fitting.

  webcam-calibrate fit RAW.bin [--corners ...] [--dark DARK.bin --flat FLAT.bin] [--write]
      Decodes the raw frame, locates the 24 patches (cv2.mcc auto-detect,
      or a manual --corners homography), fits the CCM, and prints it. With
      --write, replaces the matrix (and header comment) in ov2740-tuning.yaml
      in place, refusing to do so if the fit looks bad.

  webcam-calibrate render --out DIR [--scale 0.35]
      Renders chart.png/flat.png/dark.png (see cmd_render's docstring) to
      show fullscreen on the monitor facing the camera, for capture+fit.

Why fit needs --dark/--flat (2026-09-10 finding): the OV2740's auto-gain
sits at its minimum exposure whenever a screen fills the frame, so a chart
much brighter than ~35% linear clips; and the monitor panel has a strong
angular brightness falloff across the frame plus an additive floor (panel
black level and room glare reflected off the glossy surface), so raw
patch samples read nowhere near the true patch ratios (an early attempt
without correction had ~100% mean residual). The fix: photograph the
panel fully black (DARK) and at a uniform mid-grey rgb(100,100,100)
(FLAT) in the same session as the chart, blur both with a wide Gaussian
(sigma 6, matching the falloff's spatial scale) to suppress their own
photon noise, and correct the chart as
`(chart - blur(dark)) / (blur(flat) - blur(dark))` before sampling
patches -- this divides out the panel's per-pixel gain and subtracts its
floor, leaving a ratio image where a uniformly-lit patch reads uniformly
regardless of where it sits in the frame. Verified: mean residual dropped
from ~100% to 5.9% on real captures, with the neutral ramp landing within
1% of its reference.

Runtime pipeline this targets (src/ipa/simple, src/libcamera/
software_isp/debayer_cpu.cpp in libcamera 0.7.0's soft ISP): black level
subtracted, grey-world AWB gains applied, THEN this CCM, then gamma. So
the matrix here maps white-balanced linear sensor RGB to linear sRGB, and
two design choices follow directly from that:

* Each row of the fitted matrix sums to 1 (white-preserving). AWB has
  already put the illuminant's white point at grey by the time the CCM
  runs; a CCM row that doesn't sum to 1 further rescales neutrals, i.e.
  bakes a *second*, redundant white-point correction into the color
  matrix. The 2026-08-19 matrix in this file did exactly that (a
  "diagonal white-balance fix from a known-white reference" folded into
  the CCM after the main fit) -- flagged in advisor review as baking an
  AWB error into the CCM instead of fixing AWB itself. Constraining each
  row to sum to 1 makes that mistake structurally impossible: the fit can
  only rotate/mix hue and saturation, never re-white-balance.

* White-balance gains for the fit are taken from the four neutral patches
  (19-22: white, and the three greys) rather than a full-frame grey-world
  average. Full-frame grey-world assumes the *scene* averages to grey,
  which is false for a ColorChecker photograph (it's dominated by six
  saturated color patches per row) -- averaging the whole frame would
  pull the gains toward whatever hue happens to dominate the chart, not
  the true illuminant white point. The neutral patches are grey by
  construction, so their raw R/G/B ratio *is* the illuminant's gain,
  directly.
"""

import argparse
import datetime as dt
import glob
import os
import re
import subprocess
import sys
import textwrap

import cv2
import numpy as np

STRIDE_BYTES = 3904
STRIDE_PX = STRIDE_BYTES // 2  # 1952 u16 samples per row
WIDTH = 1932
HEIGHT = 1092
FULL_SCALE = 1023  # 10-bit max code value
DEFAULT_BLACK_LEVEL = 64  # nominal OV2740 10-bit black level

# Reference: post-Nov-2014 X-Rite ColorChecker Classic, sRGB (D65) 8-bit
# values, patch 1 (dark skin, top-left) .. patch 24 (black, bottom-right),
# row-major over the 6-column x 4-row grid. As tabulated e.g. on the
# ColorChecker Wikipedia page / colour-science's "ColorChecker24 - After
# November 2014" data set.
COLORCHECKER_SRGB8 = [
    (115, 82, 68), (194, 150, 130), (98, 122, 157), (87, 108, 67), (133, 128, 177), (103, 189, 170),
    (214, 126, 44), (80, 91, 166), (193, 90, 99), (94, 60, 108), (157, 188, 64), (224, 163, 46),
    (56, 61, 150), (70, 148, 73), (175, 54, 60), (231, 199, 31), (187, 86, 149), (8, 133, 161),
    (243, 243, 242), (200, 200, 200), (160, 160, 160), (122, 122, 121), (85, 85, 85), (52, 52, 52),
]
# Patches 19-22 (0-based 18-21): white 9.5, neutral 8, neutral 6.5, neutral 5.
NEUTRAL_PATCH_INDICES = [18, 19, 20, 21]

YAML_DEFAULT_PATH = os.path.join("machines", "jester", "ov2740-tuning.yaml")


def srgb_to_linear(c):
    c = np.asarray(c, dtype=np.float64)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = np.clip(np.asarray(c, dtype=np.float64), 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


REFERENCE_LINEAR = srgb_to_linear(np.array(COLORCHECKER_SRGB8, dtype=np.float64) / 255.0)


def read_raw(path):
    """Load a `cam --stream role=raw` SGRBG10 capture: 16-bit LE samples,
    stride STRIDE_PX per row, cropped to the WIDTH active columns."""
    data = np.fromfile(path, dtype="<u2")
    expected = STRIDE_PX * HEIGHT
    if data.size != expected:
        raise ValueError(
            f"{path}: expected {expected} u16 samples ({expected * 2} bytes "
            f"for {WIDTH}x{HEIGHT}-SGRBG10 at stride {STRIDE_BYTES}), got "
            f"{data.size} ({data.size * 2} bytes)"
        )
    return data.reshape(HEIGHT, STRIDE_PX)[:, :WIDTH]


def debayer_bin(raw, black_level):
    """2x2 SGRBG -> linear RGB bin, normalised to [0, 1].

    Black level is subtracted before binning: row0 is G R G R..., row1 is
    B G B G..., so a 2x2 block averages two G samples and takes one R and
    one B. Subtracting the black level after averaging would scale the
    offset by however many samples went into each channel (1x for R/B,
    2x-summed-then-halved for G) -- since it's already correct for G but
    wrong for any bin that isn't a plain average, subtract first so every
    channel sees the same one offset regardless of how it's later combined.
    """
    signal = np.clip(raw.astype(np.float64) - black_level, 0.0, None)
    g0 = signal[0::2, 0::2]  # row0 even col: G
    r = signal[0::2, 1::2]  # row0 odd col:  R
    b = signal[1::2, 0::2]  # row1 even col: B
    g1 = signal[1::2, 1::2]  # row1 odd col:  G
    g = (g0 + g1) / 2.0
    full_scale = FULL_SCALE - black_level
    rgb = np.stack([r, g, b], axis=-1) / full_scale
    return np.clip(rgb, 0.0, 1.0)


def dark_flat_correct(chart_linear, dark_linear, flat_linear, sigma=6.0):
    """Divide out the monitor's angular brightness falloff and additive
    floor (panel black level + room glare) using a DARK (screen off) and
    FLAT (uniform grey) capture of the same panel -- see the module
    docstring for why this is necessary. Both references are blurred with
    a wide Gaussian first, to average away their own shot noise without
    smearing across the chart's much smaller patch features; the result
    is a ratio image (0 = dark floor, 1 = the flat field), not linear RGB,
    so it is only ever used for sampling patches, never written out as an
    image."""
    def blur(im):
        return cv2.GaussianBlur(im.astype(np.float32), (0, 0), sigma).astype(np.float64)

    dark_b = blur(dark_linear)
    flat_b = blur(flat_linear)
    denom = flat_b - dark_b
    denom = np.where(np.abs(denom) < 1e-6, 1e-6, denom)
    return (chart_linear - dark_b) / denom


def crude_wb_srgb_preview(rgb_linear):
    """Grey-world WB + sRGB gamma, just so a human can check framing /
    feed the chart detector -- not colour-accurate, unlike fit()'s WB."""
    means = rgb_linear.reshape(-1, 3).mean(axis=0)
    means = np.where(means < 1e-6, 1.0, means)
    gains = means[1] / means
    wb = np.clip(rgb_linear * gains, 0.0, 1.0)
    u8 = np.round(linear_to_srgb(wb) * 255).astype(np.uint8)
    return cv2.cvtColor(u8, cv2.COLOR_RGB2BGR)


def _quad_from_unit_square(dst_corners):
    unit = np.array([[0, 0], [1, 0], [1, 1], [0, 1]], dtype=np.float32)
    return cv2.getPerspectiveTransform(unit, np.asarray(dst_corners, dtype=np.float32))


def sample_quad_mean(rgb_linear, quad, frac=0.4):
    """Mean linear RGB over the central `frac` (per axis) of the cell whose
    four corners (TL, TR, BR, BL) are `quad`, in rgb_linear's pixel space."""
    h = _quad_from_unit_square(quad)
    lo, hi = 0.5 - frac / 2, 0.5 + frac / 2
    n = 9
    us, vs = np.meshgrid(np.linspace(lo, hi, n), np.linspace(lo, hi, n))
    pts = np.stack([us.ravel(), vs.ravel(), np.ones(n * n)], axis=0)
    px = h @ pts
    px = (px[:2] / px[2]).T
    height, width = rgb_linear.shape[:2]
    samples = [
        rgb_linear[int(round(y)), int(round(x))]
        for x, y in px
        if 0 <= round(y) < height and 0 <= round(x) < width
    ]
    if not samples:
        raise ValueError("patch quad sampled no in-bounds pixels")
    return np.mean(samples, axis=0)


def grid_quads_from_corners(corners, cols=6, rows=4):
    """24 per-patch quads from the outer TL/TR/BR/BL corners of the whole
    patch grid (as given via --corners), patch order matching
    REFERENCE_LINEAR (row-major, patch 1 top-left)."""
    h = _quad_from_unit_square(corners)
    quads = []
    for i in range(rows):
        for j in range(cols):
            cell = np.array(
                [
                    [j / cols, i / rows],
                    [(j + 1) / cols, i / rows],
                    [(j + 1) / cols, (i + 1) / rows],
                    [j / cols, (i + 1) / rows],
                ],
                dtype=np.float32,
            )
            pts = np.concatenate([cell, np.ones((4, 1), dtype=np.float32)], axis=1).T
            px = h @ pts
            quads.append((px[:2] / px[2]).T)
    return quads


def detect_checker_auto(preview_bgr_u8):
    """24 per-patch quads via cv2.mcc, or None if no chart was found /
    the mcc module isn't built into this OpenCV."""
    if not hasattr(cv2, "mcc"):
        return None
    detector = cv2.mcc.CCheckerDetector_create()
    if not detector.process(preview_bgr_u8, cv2.mcc.MCC24, 1):
        return None
    checker = detector.getBestColorChecker()
    pts = np.asarray(checker.getColorCharts(), dtype=np.float32).reshape(24, 4, 2)
    return list(pts)


def fit_ccm(samples, saturated=None):
    """Core CCM fit from 24 raw (pre-WB) linear patch mean samples (patch
    order matching REFERENCE_LINEAR). Returns a dict: gains (R,G,B WB
    gains, G=1), k (fitted exposure scalar), M (3x3, rows sum to 1),
    usable/rejected (patch indices), resid (per-patch relative residual,
    meaningful only for usable patches). Raises ValueError if every
    neutral patch is unusable (can't establish white balance at all).

    `saturated`, if given, is a length-24 bool array overriding the
    default any(samples > 0.95) test -- needed by dark+flat mode, whose
    `samples` are (chart - dark) / (flat - dark) ratios rather than
    linear RGB, so the 0.95 test must instead run against the
    uncorrected chart samples.
    """
    if saturated is None:
        saturated = np.any(samples > 0.95, axis=1)
    rejected = [i for i in range(24) if saturated[i]]
    usable = [i for i in range(24) if not saturated[i]]

    neutral_usable = [i for i in NEUTRAL_PATCH_INDICES if i in usable]
    if not neutral_usable:
        raise ValueError("all neutral patches (19-22) are saturated/unusable")

    # WB from the neutral patches, not full-frame grey-world -- see the
    # module docstring for why.
    g_over_r = samples[neutral_usable, 1] / samples[neutral_usable, 0]
    g_over_b = samples[neutral_usable, 1] / samples[neutral_usable, 2]
    gains = np.array([np.mean(g_over_r), 1.0, np.mean(g_over_b)])
    wb = samples * gains

    # Exposure scalar k: the chart photo's overall brightness is arbitrary
    # (whatever the AGC/lighting happened to give), but a row-sum-1 matrix
    # is white-preserving and so *cannot* itself correct a brightness
    # mismatch -- it would show up as hue/saturation error instead. Fix it
    # up front from the same neutral patches (least squares through the
    # origin: the WB'd neutral samples should equal their linear-sRGB
    # reference once scaled by k).
    ref_neutral = REFERENCE_LINEAR[neutral_usable]
    wb_neutral = wb[neutral_usable]
    k = float(np.sum(wb_neutral * ref_neutral) / np.sum(wb_neutral * wb_neutral))
    scaled = wb * k

    # Constrained least squares, one output row (R, G or B) at a time: a
    # row m with sum(m) == 1 is m0 + x1*u1 + x2*u2 for any x1, x2, where
    # m0 = [1/3, 1/3, 1/3] and u1, u2 span the {sum == 0} nullspace. That
    # turns each row into a plain 2-unknown unconstrained least squares
    # problem (numerically simpler and more stable than eliminating a
    # column algebraically).
    m0 = np.array([1 / 3, 1 / 3, 1 / 3])
    u1 = np.array([1.0, -1.0, 0.0])
    u2 = np.array([1.0, 0.0, -1.0])
    design = np.stack([scaled[usable] @ u1, scaled[usable] @ u2], axis=1)
    matrix = np.empty((3, 3))
    for row in range(3):
        target = REFERENCE_LINEAR[usable, row] - scaled[usable] @ m0
        x, *_ = np.linalg.lstsq(design, target, rcond=None)
        matrix[row] = m0 + x[0] * u1 + x[1] * u2

    pred = scaled @ matrix.T
    resid = np.linalg.norm(pred - REFERENCE_LINEAR, axis=1) / np.linalg.norm(REFERENCE_LINEAR, axis=1)

    return {
        "gains": gains,
        "k": k,
        "M": matrix,
        "usable": usable,
        "rejected": rejected,
        "resid": resid,
    }


def write_yaml(yaml_path, matrix, mean_resid, n_usable):
    with open(yaml_path, encoding="utf-8") as f:
        text = f.read()

    lines = text.splitlines(keepends=True)
    start = next(i for i, line in enumerate(lines) if line.startswith("# OV2740 soft-ISP tuning"))
    end = next(i for i, line in enumerate(lines) if line.startswith("%YAML"))
    date = dt.date.today().isoformat()
    paragraph = (
        f"OV2740 soft-ISP tuning for jester. Same algorithm chain as "
        f"uncalibrated.yaml plus a Ccm block. Matrix fitted {date} by "
        f"webcam-calibrate.py fit from a ColorChecker chart shown on the "
        f"EHOMEWEI panel at 35% linear brightness, with dark+flat "
        f"panel-falloff correction ({n_usable} usable patches, "
        f"{mean_resid * 100:.1f}% mean residual), constrained least "
        f"squares with each row summing to 1 -- AWB upstream already "
        f"supplies the white point, so the CCM only rotates "
        f"hue/saturation. See webcam-calibrate.py's module docstring for "
        f"the method and rationale."
    )
    header = "".join(f"# {line}\n" for line in textwrap.wrap(paragraph, width=75))
    lines[start:end] = [header]
    text = "".join(lines)

    rows = [", ".join(f"{v:.4f}" for v in matrix[r]) for r in range(3)]
    new_block = (
        "ccm: [ " + rows[0] + ",\n"
        "                 " + rows[1] + ",\n"
        "                 " + rows[2] + " ]"
    )
    new_text, n = re.subn(r"ccm: \[.*?\]", new_block, text, count=1, flags=re.DOTALL)
    if n == 0:
        raise ValueError(f"no `ccm: [ ... ]` block found in {yaml_path}")

    with open(yaml_path, "w", encoding="utf-8") as f:
        f.write(new_text)


def cmd_capture(args):
    os.makedirs(args.out, exist_ok=True)
    subprocess.run(["systemctl", "--user", "stop", "wireplumber"], check=True)
    try:
        pattern = os.path.join(args.out, "raw#.bin")
        # cam's own log is noisy (harmless V4L2 rectangle errors) even on a
        # clean capture, so don't gate success on its exit code -- check
        # for actual output frames instead.
        subprocess.run(
            ["cam", "-c1", "--stream", "role=raw", "--capture=30", f"--file={pattern}"],
            check=False,
        )
        # cam expands "#" to "<camera>-<stream>-<seq>"; exclude a previous
        # run's raw.bin, whose name carries no sequence number.
        frames = sorted(
            (m.group(0), int(m.group(1)))
            for m in map(
                lambda p: re.search(r".*-(\d+)\.bin$", p),
                glob.glob(os.path.join(args.out, "raw*-*.bin")),
            )
            if m
        )
        frames = [f for f, _ in sorted(frames, key=lambda t: t[1])]
        if not frames:
            sys.exit("capture: no raw frames were written; see the `cam` output above")
        raw_path = os.path.join(args.out, "raw.bin")
        os.replace(frames[-1], raw_path)
        for stale in frames[:-1]:
            os.remove(stale)
    finally:
        subprocess.run(["systemctl", "--user", "start", "wireplumber"], check=True)

    raw = read_raw(raw_path)
    linear = debayer_bin(raw, DEFAULT_BLACK_LEVEL)
    preview_path = os.path.join(args.out, "preview.png")
    cv2.imwrite(preview_path, crude_wb_srgb_preview(linear))
    print(f"raw frame: {raw_path}")
    print(f"preview:   {preview_path}")


def cmd_fit(args):
    if bool(args.dark) != bool(args.flat):
        sys.exit("fit: --dark and --flat must be given together")

    raw = read_raw(args.raw)
    p05 = float(np.percentile(raw.astype(np.float64), 0.5))
    print(f"observed 0.5th percentile of raw code values: {p05:.1f} (using --black-level {args.black_level})")

    linear = debayer_bin(raw, args.black_level)
    preview = crude_wb_srgb_preview(linear)

    if args.corners:
        quads = grid_quads_from_corners(args.corners)
        print("patch grid source: --corners")
    else:
        quads = detect_checker_auto(preview)
        if quads is None:
            sys.exit(
                "fit: cv2.mcc auto-detect found no ColorChecker (or this "
                "OpenCV lacks the mcc module -- check with "
                "`python3 -c 'import cv2; print(hasattr(cv2, \"mcc\"))'`); "
                "pass --corners TL TR BR BL, in pixel coordinates of the "
                "binned image (see preview.png)"
            )
        print("patch grid source: cv2.mcc auto-detect")

    uncorrected_samples = np.array([sample_quad_mean(linear, q) for q in quads])
    saturated = None  # let fit_ccm derive it from `samples` itself, default mode

    if args.dark:
        print("correction mode: dark+flat (monitor falloff/floor correction)")
        dark_linear = debayer_bin(read_raw(args.dark), args.black_level)
        flat_linear = debayer_bin(read_raw(args.flat), args.black_level)
        corrected = dark_flat_correct(linear, dark_linear, flat_linear)
        samples = np.array([sample_quad_mean(corrected, q) for q in quads])
        # `samples` are (chart - dark) / (flat - dark) ratios, not linear
        # RGB, so they can legitimately exceed fit_ccm()'s 0.95 saturation
        # threshold even for an unsaturated patch; rescale to the same
        # [0, 0.9] headroom a real unsaturated linear capture would
        # occupy, and judge saturation from the uncorrected chart samples
        # instead (passed as `saturated` below).
        samples = samples * (0.9 / samples.max())
        saturated = np.any(uncorrected_samples > 0.95, axis=1)
    else:
        print("correction mode: none (raw patch samples)")
        samples = uncorrected_samples

    try:
        result = fit_ccm(samples, saturated=saturated)
    except ValueError as e:
        sys.exit(f"fit: {e}")

    if result["rejected"]:
        print(f"rejected (saturated) patches: {[i + 1 for i in result['rejected']]}")
    n_usable = len(result["usable"])
    print(f"usable patches: {n_usable}/24")

    gains = result["gains"]
    print(f"WB gains (R, G, B): {gains[0]:.4f}, {gains[1]:.4f}, {gains[2]:.4f}")
    print(f"exposure scalar k: {result['k']:.4f}")

    matrix = result["M"]
    print("matrix (row-major, R/G/B output rows, each summing to 1):")
    print("  ccm: [ " + ", ".join(f"{v:.4f}" for v in matrix.flatten()) + " ]")
    print(f"row sums: {[f'{s:.4f}' for s in matrix.sum(axis=1)]}")

    resid = result["resid"]
    print("per-patch relative residual:")
    for i in result["usable"]:
        print(f"  patch {i + 1:2d}: {resid[i] * 100:5.2f}%")
    mean_resid = float(np.mean(resid[result["usable"]]))
    max_resid = float(np.max(resid[result["usable"]]))
    print(f"mean residual: {mean_resid * 100:.2f}%   max residual: {max_resid * 100:.2f}%")

    if args.target == "display":
        print(
            "NOTE: --target display compares against the reflective "
            "ColorChecker's published sRGB reference while the chart was "
            "shown on an emissive screen -- narrowband display primaries "
            "differ from the chart's reflective spectra, so expect a "
            "slight hue bias. Prefer a physical chart under real light."
        )

    if args.write:
        if mean_resid > 0.15:
            sys.exit(f"fit: refusing --write, mean residual {mean_resid * 100:.1f}% > 15%")
        if n_usable < 16:
            sys.exit(f"fit: refusing --write, only {n_usable} usable patches (need >= 16)")
        write_yaml(args.yaml_path, matrix, mean_resid, n_usable)
        print(f"wrote {args.yaml_path}")


RENDER_W, RENDER_H = 2560, 1600
PATCH_PX, GAP_PX = 300, 80
FLAT_SRGB8 = (100, 100, 100)


def _srgb_linear_u8(rgb_u8, scale=1.0):
    """(r, g, b) 0-255 sRGB -> 0-255 sRGB u8 after scaling in linear
    light by `scale` (so `scale` is a true linear-brightness fraction,
    not a naive multiply on gamma-encoded values)."""
    linear = srgb_to_linear(np.array(rgb_u8, dtype=np.float64) / 255.0) * scale
    return tuple(int(round(v)) for v in linear_to_srgb(linear) * 255)


def cmd_render(args):
    """Write chart.png, flat.png and dark.png to --out, for display on the
    monitor facing the camera:

      1. `feh -F DIR/dark.png` then, once feh has it fullscreen,
         `hyprctl dispatch 'hl.dsp.window.fullscreen()'` (jester/Hyprland)
         -- run `webcam-calibrate capture` for the dark frame.
      2. Repeat with flat.png, then capture, for the flat frame.
      3. Repeat with chart.png, then capture, for the chart frame.
      4. `webcam-calibrate fit CHART.bin --dark DARK.bin --flat FLAT.bin --corners TL TR BR BL`

    chart.png draws the 24 ColorChecker patches at `--scale` (default
    0.35) of full linear brightness -- see the module docstring for why:
    the OV2740's auto-gain sits at minimum exposure with a screen filling
    the frame, so a full-brightness chart clips.
    """
    os.makedirs(args.out, exist_ok=True)

    grid_w = 6 * PATCH_PX + 5 * GAP_PX
    grid_h = 4 * PATCH_PX + 3 * GAP_PX
    x0, y0 = (RENDER_W - grid_w) // 2, (RENDER_H - grid_h) // 2
    chart = np.zeros((RENDER_H, RENDER_W, 3), dtype=np.uint8)
    for i in range(4):
        for j in range(6):
            r, g, b = _srgb_linear_u8(COLORCHECKER_SRGB8[i * 6 + j], scale=args.scale)
            px, py = x0 + j * (PATCH_PX + GAP_PX), y0 + i * (PATCH_PX + GAP_PX)
            chart[py:py + PATCH_PX, px:px + PATCH_PX] = (b, g, r)  # BGR for cv2
    chart_path = os.path.join(args.out, "chart.png")
    cv2.imwrite(chart_path, chart)

    flat = np.full((RENDER_H, RENDER_W, 3), FLAT_SRGB8[::-1], dtype=np.uint8)  # BGR
    flat_path = os.path.join(args.out, "flat.png")
    cv2.imwrite(flat_path, flat)

    dark = np.zeros((RENDER_H, RENDER_W, 3), dtype=np.uint8)
    dark_path = os.path.join(args.out, "dark.png")
    cv2.imwrite(dark_path, dark)

    print(f"chart: {chart_path}")
    print(f"flat:  {flat_path}")
    print(f"dark:  {dark_path}")


def _parse_corner(s):
    x, y = s.split(",")
    return (float(x), float(y))


def build_parser():
    p = argparse.ArgumentParser(prog="webcam-calibrate", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)

    pc = sub.add_parser("capture", help="capture 30 raw frames from the OV2740, keep the last")
    pc.add_argument("--out", default="webcam-calib", help="output directory (default: %(default)s)")
    pc.set_defaults(func=cmd_capture)

    pf = sub.add_parser("fit", help="fit a CCM from a raw capture")
    pf.add_argument("raw", help="path to a raw SGRBG10 .bin capture")
    pf.add_argument(
        "--corners",
        nargs=4,
        type=_parse_corner,
        metavar="X,Y",
        help="TL TR BR BL pixel corners of the patch grid in the binned "
        "image (see preview.png); skips cv2.mcc auto-detect",
    )
    pf.add_argument("--black-level", type=int, default=DEFAULT_BLACK_LEVEL, help="10-bit black level (default: %(default)s)")
    pf.add_argument("--write", action="store_true", help="replace the CCM in --yaml-path")
    pf.add_argument("--dark", help="raw capture of the panel fully black; requires --flat (see module docstring)")
    pf.add_argument("--flat", help="raw capture of the panel at uniform rgb(100,100,100); requires --dark")
    pf.add_argument("--target", choices=["physical", "display"], default="physical")
    pf.add_argument(
        "--yaml-path",
        default=YAML_DEFAULT_PATH,
        help="tuning yaml to update with --write, relative to cwd (default: %(default)s -- run from the repo root)",
    )
    pf.set_defaults(func=cmd_fit)

    pr = sub.add_parser("render", help="render chart/flat/dark PNGs to show on the monitor facing the camera")
    pr.add_argument("--out", required=True, help="output directory")
    pr.add_argument("--scale", type=float, default=0.35, help="chart linear brightness fraction (default: %(default)s)")
    pr.set_defaults(func=cmd_render)

    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
