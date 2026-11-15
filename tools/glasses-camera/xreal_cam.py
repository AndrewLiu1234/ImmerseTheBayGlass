#!/usr/bin/env python3
"""XREAL Air 2 Ultra glasses-camera frame decoder (Person 2 prototype for Person 1's tools/camera-vision).

WHY THE FRAMES LOOK LIKE STREAKS
The Ultra's UVC camera advertises "640x241 YUYV" (2 bytes/px = 308,480 bytes/frame). That is NOT a colour image:
  * bytes [0, 307200)       = ONE grayscale eye image, 640 x 480, 8 bit, cut into 128 chunks of 2400 bytes
                              (2400 = 3.75 image rows) and stored in a fixed scrambled order (CHUNK_MAP) that
                              starts at a varying offset;
  * bytes [307200, 308480)  = a 1280-byte footer: [0:8] sensor timestamp ns (LE), [18:20] stereo pair counter,
                              [59] eye (0 = left, 1 = right), [62:70] shared timestamp ns;
  * consecutive UVC frames alternate LEFT / RIGHT eye (pair them by counter + shared timestamp);
  * the sensors are mounted sideways: upright left = rotate 90 deg CCW, upright right = rotate 90 deg CW (480 x 640).
Treating the buffer as YUYV colour turns every other byte into chroma and every 1280 bytes into one display row,
so a viewer shows smeared horizontal bands; a JPEG of that colour image (WebCamTexture -> JPEG -> bridge) destroys
the bytes for good. Decode from the RAW bytes.

Sources (read, not guessed): vladoshub/xr-gate (MIT) capture_service_cpp/src/vendor/xreal_camera_decoder.cpp,
xreal_camera_metadata.cpp, configs/xreal_ultra.yaml (left ccw90, right ccw90+flip xy = cw90); the same CHUNK_MAP and
offset rule appear in DeskUnreal/xreal-vio-vr parts/xreal.py (GPL, not copied). Lens calibration (another unit,
serial ZBBM5DZFMP, same model): xr-gate calibration_dataset/final/xreal_air2ultra/.../camchain-camera-only.yaml.

Usage:
  xreal_cam.py --self-test              synthetic scramble -> decode -> ArUco round trip
  xreal_cam.py --bench                  decode speed
  xreal_cam.py --raw FILE [...]         decode raw 308,480-byte dumps -> PNGs + footer + orientation probe
  xreal_cam.py --ffmpeg DEVICE_INDEX    live: ffmpeg AVFoundation raw yuyv422 pipe -> decode -> ArUco (needs ffmpeg)
"""
import argparse
import os
import struct
import subprocess
import sys
import time

import numpy as np

EYE_W, EYE_H = 640, 480                    # native (sideways) eye image
IMAGE_BYTES = EYE_W * EYE_H                # 307,200
FRAME_BYTES = EYE_W * (EYE_H + 2)          # 308,480 = UVC "640x241 YUYV"
FOOTER_BYTES = FRAME_BYTES - IMAGE_BYTES   # 1,280
CHUNK, NCHUNK, SUMLEN = 2400, 128, 128
TIE_TOL = 2 * SUMLEN     # chunk heads within this of the darkest count as ties (sensor black level noise)
MAX_TIES = 16

CHUNK_MAP = np.array([
    119, 54, 21, 0, 108, 22, 51, 63, 93, 99, 67, 7, 32, 112, 52,
    43, 14, 35, 75, 116, 64, 71, 44, 89, 18, 88, 26, 61, 70, 56,
    90, 79, 87, 120, 81, 101, 121, 17, 72, 31, 53, 124, 127, 113, 111,
    36, 48, 19, 37, 83, 126, 74, 109, 5, 84, 41, 76, 30, 110, 29,
    12, 115, 28, 102, 105, 62, 103, 20, 3, 68, 49, 77, 117, 125, 106,
    60, 69, 98, 9, 16, 78, 47, 40, 2, 118, 34, 13, 50, 46, 80,
    85, 66, 42, 123, 122, 96, 11, 25, 97, 39, 6, 86, 1, 8, 82,
    92, 59, 104, 24, 15, 73, 65, 38, 58, 10, 23, 33, 55, 57, 107,
    100, 94, 27, 95, 45, 91, 4, 114], dtype=np.intp)
REVERSE_MAP = np.empty(NCHUNK, dtype=np.intp)
REVERSE_MAP[CHUNK_MAP] = np.arange(NCHUNK)
# ORDERS[o] = source chunk for each output chunk when the stream starts at offset o (precomputed: no per-frame roll)
ORDERS = np.stack([np.roll(CHUNK_MAP, -o) for o in range(NCHUNK)])

# Upright (480 wide x 640 tall) intrinsics from xr-gate's Air 2 Ultra calibration (another unit: treat as a start
# value). Equidistant = OpenCV fisheye model. fx fy cx cy, k1..k4.
CAL = {
    "left":  dict(K=(238.883, 238.440, 239.656, 321.161), D=(0.004136, 0.095095, -0.117665, 0.046229)),
    "right": dict(K=(238.013, 237.929, 238.596, 318.633), D=(0.011016, 0.066461, -0.076379, 0.025620)),
}


def decode_eye(raw, out=None):
    """raw: 308,480 bytes (bytes/bytearray/memoryview/uint8 array). Returns (native 480x640 uint8, meta dict) or None.
    One gather + one copy; ~0.1 ms. `out` (480x640 uint8) is reused if given."""
    buf = np.frombuffer(raw, dtype=np.uint8) if not isinstance(raw, np.ndarray) else raw.reshape(-1)
    if buf.size != FRAME_BYTES:
        return None
    blocks = buf[:IMAGE_BYTES].reshape(NCHUNK, CHUNK)
    # The stream's first chunk starts at the image corner, which the fisheye lens leaves black -> the darkest
    # chunk head marks it (the rule both reference decoders use).
    head_sums = blocks[:, :SUMLEN].sum(axis=1, dtype=np.uint32)
    if out is None:
        out = np.empty((EYE_H, EYE_W), dtype=np.uint8)
    cands = np.flatnonzero(head_sums <= head_sums.min() + TIE_TOL)
    if len(cands) == 1:
        offset = int(REVERSE_MAP[int(cands[0])])
    else:
        # Several chunk heads are black (fisheye border): keep the offset whose image is smoothest between rows.
        # A wrong offset shifts the picture by 3.75 rows per chunk, which tears every row apart.
        best = None
        for k in cands[:MAX_TIES]:
            o = int(REVERSE_MAP[int(k)])
            np.take(blocks, ORDERS[o], axis=0, out=out.reshape(NCHUNK, CHUNK))
            v = out[::2, ::4].astype(np.int16)
            score = int(np.abs(v[1:] - v[:-1]).sum())
            if best is None or score < best[0]:
                best = (score, o)
        offset = best[1]
    np.take(blocks, ORDERS[offset], axis=0, out=out.reshape(NCHUNK, CHUNK))
    f = buf[IMAGE_BYTES:].tobytes()
    meta = {
        "t0_ns": struct.unpack_from("<Q", f, 0)[0],
        "pair": struct.unpack_from("<H", f, 18)[0],
        "eye": "right" if f[59] else "left",
        "eye_byte": f[59],
        "t62_ns": struct.unpack_from("<Q", f, 62)[0],
        "offset": offset,
    }
    return out, meta


def upright(native, eye):
    """Sideways sensor -> upright 480 wide x 640 tall (xr-gate profile: left ccw90, right cw90)."""
    import cv2
    return cv2.rotate(native, cv2.ROTATE_90_COUNTERCLOCKWISE if eye == "left" else cv2.ROTATE_90_CLOCKWISE)


class StereoPairer:
    """Frames alternate eyes. push() returns (left, right, meta) once both eyes of one pair have arrived."""

    def __init__(self):
        self.pending = {}
        self.key = None
        self.dropped = 0

    def push(self, img, meta):
        key = (meta["pair"], meta["t62_ns"])
        if key != self.key:
            if self.pending:
                self.dropped += 1
            self.pending, self.key = {}, key
        self.pending[meta["eye"]] = img.copy()
        if len(self.pending) == 2:
            l, r = self.pending["left"], self.pending["right"]
            self.pending, self.key = {}, None
            return l, r, meta
        return None


# --- orientation probe: which of the 8 rotations/mirrors makes the marker readable (settles it on the device) ----
DIHEDRAL = {
    "none": lambda a: a, "cw90": lambda a: np.rot90(a, -1), "rot180": lambda a: np.rot90(a, 2),
    "ccw90": lambda a: np.rot90(a, 1), "flipH": lambda a: a[:, ::-1], "flipV": lambda a: a[::-1, :],
    "transpose": lambda a: a.T, "antitranspose": lambda a: np.rot90(a, 2).T,
}


def orientation_probe(native, aruco_detect, expect_id=None):
    hits = {}
    for name, fn in DIHEDRAL.items():
        ids = aruco_detect(np.ascontiguousarray(fn(native)))
        if ids:
            hits[name] = ids
    good = [n for n, ids in hits.items() if expect_id is None or expect_id in ids]
    return hits, good


def make_detector(dict_id=None):
    import cv2
    d = cv2.aruco.getPredefinedDictionary(cv2.aruco.DICT_4X4_50 if dict_id is None else dict_id)
    det = cv2.aruco.ArucoDetector(d, cv2.aruco.DetectorParameters())

    def detect(gray):
        _, ids, _ = det.detectMarkers(gray)
        return [] if ids is None else sorted(int(i) for i in ids.ravel())
    return detect


# --- test helpers ------------------------------------------------------------------------------------------------
def scramble(native, eye="left", offset=17, pair=5, t0=123456789, t62=987654321):
    """Inverse of decode_eye: build the raw UVC buffer the glasses would send for this native image."""
    src = np.ascontiguousarray(native, dtype=np.uint8).reshape(NCHUNK, CHUNK)
    raw = np.zeros(FRAME_BYTES, dtype=np.uint8)
    blocks = raw[:IMAGE_BYTES].reshape(NCHUNK, CHUNK)
    blocks[ORDERS[offset]] = src
    f = bytearray(FOOTER_BYTES)
    struct.pack_into("<Q", f, 0, t0)
    struct.pack_into("<H", f, 18, pair)
    f[59] = 1 if eye == "right" else 0
    struct.pack_into("<Q", f, 62, t62)
    raw[IMAGE_BYTES:] = np.frombuffer(bytes(f), dtype=np.uint8)
    return raw.tobytes()


def synthetic_upright(marker_id=7, side=150, seed=1):
    """Upright 480x640 scene: textured background, fisheye-style black corners, one ArUco marker."""
    import cv2
    rng = np.random.default_rng(seed)
    img = (rng.integers(60, 200, (640, 480))).astype(np.uint8)
    img = cv2.GaussianBlur(img, (0, 0), 3)
    y, x = np.mgrid[0:640, 0:480]
    img[(x - 240) ** 2 + (y - 320) ** 2 > 300 ** 2] = 0                          # black outside the fisheye circle
    d = cv2.aruco.getPredefinedDictionary(cv2.aruco.DICT_4X4_50)
    m = cv2.aruco.generateImageMarker(d, marker_id, side)
    pad = side // 5
    tile = np.full((side + 2 * pad, side + 2 * pad), 255, np.uint8)
    tile[pad:pad + side, pad:pad + side] = m
    y0, x0 = 260, 140
    img[y0:y0 + tile.shape[0], x0:x0 + tile.shape[1]] = tile
    return img


def to_native(up, eye):
    """Inverse of upright()."""
    import cv2
    return cv2.rotate(up, cv2.ROTATE_90_CLOCKWISE if eye == "left" else cv2.ROTATE_90_COUNTERCLOCKWISE)


# --- CLI -------------------------------------------------------------------------------------------------------------
def self_test():
    import cv2
    detect = make_detector()
    ok = True
    for eye in ("left", "right"):
        up = synthetic_upright(7)
        native = to_native(up, eye)
        for offset in (0, 1, 63, 127):
            raw = scramble(native, eye, offset)
            img, meta = decode_eye(raw)
            same = np.array_equal(img, native) and meta["eye"] == eye and meta["offset"] == offset
            ids_up = detect(upright(img, eye))
            ids_scr = detect(np.frombuffer(raw[:IMAGE_BYTES], np.uint8).reshape(EYE_H, EYE_W))
            print("self-test %-5s offset %3d: exact=%s ids(decoded upright)=%s ids(scrambled)=%s"
                  % (eye, offset, same, ids_up, ids_scr))
            ok &= same and ids_up == [7] and 7 not in ids_scr
    # the colour/JPEG path (what WebCamTexture -> JPEG does) cannot be undone
    native = to_native(synthetic_upright(7), "left")
    raw = scramble(native, "left", 40)
    yuyv = np.frombuffer(raw, np.uint8).reshape(241, 640, 2)
    bgr = cv2.cvtColor(yuyv, cv2.COLOR_YUV2BGR_YUYV)
    _, jpg = cv2.imencode(".jpg", bgr, [cv2.IMWRITE_JPEG_QUALITY, 90])
    back = cv2.cvtColor(cv2.imdecode(jpg, cv2.IMREAD_COLOR), cv2.COLOR_BGR2YUV_YUY2) if hasattr(cv2, "COLOR_BGR2YUV_YUY2") else None
    if back is not None and back.size == FRAME_BYTES:
        img, meta = decode_eye(back.tobytes())
        err = float(np.abs(img.astype(int) - native.astype(int)).mean())
        print("self-test colour+JPEG round trip (OpenCV's YUV maths, not AVFoundation's): mean byte error %.1f, "
              "eye byte %d (sent 0), offset %d (sent 40), ids %s"
              % (err, meta["eye_byte"], meta["offset"], detect(upright(img, "left"))))
    print("self-test:", "OK" if ok else "FAILED")
    return 0 if ok else 1


def bench(n=2000):
    native = to_native(synthetic_upright(7), "left")
    raw = scramble(native, "left", 77)
    out = np.empty((EYE_H, EYE_W), np.uint8)
    for _ in range(50):
        decode_eye(raw, out)
    t = time.perf_counter()
    for _ in range(n):
        decode_eye(raw, out)
    dec = (time.perf_counter() - t) / n * 1e3
    t = time.perf_counter()
    for _ in range(n // 4):
        upright(out, "left")
    rot = (time.perf_counter() - t) / (n // 4) * 1e3
    detect = make_detector()
    up = upright(out, "left")
    t = time.perf_counter()
    for _ in range(100):
        detect(up)
    aru = (time.perf_counter() - t) / 100 * 1e3
    print("bench: decode %.3f ms/frame, rotate %.3f ms, ArUco detect %.2f ms  (budget at 60 fps: 16.7 ms)"
          % (dec, rot, aru))
    return 0


def decode_files(paths, expect_id):
    import cv2
    detect = make_detector()
    for p in paths:
        with open(p, "rb") as fh:
            data = fh.read()
        for i in range(len(data) // FRAME_BYTES):
            r = decode_eye(data[i * FRAME_BYTES:(i + 1) * FRAME_BYTES])
            img, meta = r
            base = "%s.%03d.%s" % (os.path.splitext(p)[0], i, meta["eye"])
            cv2.imwrite(base + ".native.png", img)
            cv2.imwrite(base + ".upright.png", upright(img, meta["eye"]))
            hits, good = orientation_probe(img, detect, expect_id)
            print("%s: %s | marker hits by orientation %s | readable as %s" % (base, meta, hits or "none", good))
        if len(data) % FRAME_BYTES:
            print("%s: %d trailing bytes (not a multiple of %d -> row padding or a different mode?)"
                  % (p, len(data) % FRAME_BYTES, FRAME_BYTES))
    return 0


def live_ffmpeg(device, seconds, expect_id, dump):
    """Raw bytes via ffmpeg (AVFoundation passes yuyv422 through untouched; never let anything convert to RGB)."""
    detect = make_detector()
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "avfoundation", "-pixel_format", "yuyv422",
           "-video_size", "640x241", "-framerate", "60", "-i", "%s:none" % device,
           "-f", "rawvideo", "-pix_fmt", "yuyv422", "-"]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, bufsize=FRAME_BYTES * 4)
    pairer, out = StereoPairer(), np.empty((EYE_H, EYE_W), np.uint8)
    t_end = time.time() + seconds
    n = seen = pairs = 0
    eyes = {"left": 0, "right": 0}
    dumpf = open(dump, "wb") if dump else None
    try:
        while time.time() < t_end:
            raw = p.stdout.read(FRAME_BYTES)
            if len(raw) < FRAME_BYTES:
                print("live: stream ended after %d frames" % n)
                break
            if dumpf and n < 20:
                dumpf.write(raw)
            n += 1
            img, meta = decode_eye(raw, out)
            eyes[meta["eye"]] += 1
            if detect(upright(img, meta["eye"])):
                seen += 1
            if pairer.push(img, meta):
                pairs += 1
    finally:
        p.kill()
        if dumpf:
            dumpf.close()
    print("live: %d frames (%s), %d stereo pairs, %d unpaired, marker in %d frames"
          % (n, eyes, pairs, pairer.dropped, seen))
    return 0 if n else 2


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--bench", action="store_true")
    ap.add_argument("--raw", nargs="+")
    ap.add_argument("--ffmpeg", metavar="DEVICE_INDEX")
    ap.add_argument("--seconds", type=float, default=10)
    ap.add_argument("--marker-id", type=int, default=7)
    ap.add_argument("--dump", help="with --ffmpeg: save the first 20 raw frames here")
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    if a.bench:
        return bench()
    if a.raw:
        return decode_files(a.raw, a.marker_id)
    if a.ffmpeg is not None:
        return live_ffmpeg(a.ffmpeg, a.seconds, a.marker_id, a.dump)
    ap.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
