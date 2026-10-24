#!/usr/bin/env python3
"""Native Safari/WebKit visual check for HTML subtitle default attributes.

This is an isolated browser-compatibility fixture reproducing Moonfin's two
HTML <track> elements and explicit TextTrack.mode = 'showing'. It is not a
Flutter integration test.
"""
import base64
import io
import json
import subprocess
import tempfile
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread

import imageio_ffmpeg
from PIL import Image
from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait

ARTIFACTS = Path("safari-screenshots")
ARTIFACTS.mkdir(exist_ok=True)

HTML = """<!doctype html>
<html><head><meta charset="utf-8"><style>
  body { margin: 0; background: #111; }
  video { display: block; width: 640px; height: 360px; background: black; }
  video::cue { color: white; font-size: 36px; background-color: transparent; }
</style></head><body>
<video id="v" width="640" height="360" muted playsinline preload="auto"
  src="data:video/mp4;base64,__VIDEO__">
  <track id="primary" kind="subtitles" srclang="en" label="Primary"
    src="/primary.vtt" __PRIMARY_DEFAULT__>
  <track id="secondary" kind="subtitles" srclang="ja" label="Secondary"
    src="/secondary.vtt" __SECONDARY_DEFAULT__>
</video>
</body></html>
"""

PRIMARY = """WEBVTT

00:00:01.000 --> 00:00:07.500 line:85% position:50% align:center size:90%
PRIMARY ENGLISH SUBTITLE
"""

SECONDARY = """WEBVTT

00:00:01.000 --> 00:00:07.500 line:15% position:50% align:center size:90%
SECONDARY JAPANESE SUBTITLE
"""

CASES = {
    # name: primary-default, secondary-default, primary-mode, secondary-mode
    "none": (False, False, "disabled", "disabled"),
    "primary_only": (True, False, "showing", "disabled"),
    "both_default": (True, True, "showing", "showing"),
    "one_default": (True, False, "showing", "showing"),
}

def bright_pixels(img, top):
    width, height = img.size
    x0, x1 = int(width * .08), int(width * .92)
    y0, y1 = (int(height * .04), int(height * .43)) if top else (
        int(height * .58), int(height * .96)
    )
    rgb = img.convert("RGB")
    return sum(
        1 for y in range(y0, y1) for x in range(x0, x1)
        if min(rgb.getpixel((x, y))) > 155
    )

with tempfile.TemporaryDirectory() as temp:
    work = Path(temp)
    video_file = work / "black.mp4"
    subprocess.run(
        [
            imageio_ffmpeg.get_ffmpeg_exe(), "-y", "-loglevel", "error",
            "-f", "lavfi", "-i", "color=c=black:s=640x360:r=2",
            "-t", "9", "-an", "-c:v", "libx264", "-preset", "ultrafast",
            "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(video_file),
        ],
        check=True,
        capture_output=True,
    )
    video = base64.b64encode(video_file.read_bytes()).decode("ascii")
    (work / "primary.vtt").write_text(PRIMARY)
    (work / "secondary.vtt").write_text(SECONDARY)
    for name, (pd, sd, _, _) in CASES.items():
        html = (HTML.replace("__VIDEO__", video)
                 .replace("__PRIMARY_DEFAULT__", "default" if pd else "")
                 .replace("__SECONDARY_DEFAULT__", "default" if sd else ""))
        (work / f"{name}.html").write_text(html)

    class SilentHandler(SimpleHTTPRequestHandler):
        def log_message(self, format, *args):
            pass

    server = ThreadingHTTPServer(
        ("127.0.0.1", 0), partial(SilentHandler, directory=str(work))
    )
    Thread(target=server.serve_forever, daemon=True).start()

    results = {}
    driver = webdriver.Safari()
    try:
        driver.set_window_size(850, 620)
        for name, (pd, sd, primary_mode, secondary_mode) in CASES.items():
            driver.get(f"http://127.0.0.1:{server.server_port}/{name}.html")
            WebDriverWait(driver, 20).until(
                lambda d: d.execute_script(
                    "return document.getElementById('v').readyState >= 1"
                )
            )
            driver.execute_script(
                """const v = document.getElementById('v');
                   document.getElementById('primary').track.mode = arguments[0];
                   document.getElementById('secondary').track.mode = arguments[1];
                   v.currentTime = 3;
                   v.play().catch(() => {});
                """,
                primary_mode, secondary_mode,
            )

            def details(d):
                return d.execute_script(
                    """const v = document.getElementById('v');
                       const p = document.getElementById('primary');
                       const s = document.getElementById('secondary');
                       return {
                         time: v.currentTime, readyState: v.readyState,
                         primaryMode: p.track.mode,
                         secondaryMode: s.track.mode,
                         primaryCues: p.track.cues?.length ?? -1,
                         secondaryCues: s.track.cues?.length ?? -1,
                         primaryActive: p.track.activeCues?.length ?? -1,
                         secondaryActive: s.track.activeCues?.length ?? -1,
                         primaryDefault: p.hasAttribute('default'),
                         secondaryDefault: s.hasAttribute('default')
                       };
                    """
                )

            state = WebDriverWait(driver, 20).until(
                lambda d: (lambda s: s if (
                    s["readyState"] >= 2
                    and s["primaryCues"] == 1
                    and s["secondaryCues"] == 1
                    and s["time"] >= 1.0
                    and (primary_mode != "showing" or s["primaryActive"] == 1)
                    and (secondary_mode != "showing" or s["secondaryActive"] == 1)
                ) else False)(details(d))
            )
            png = driver.find_element(By.ID, "v").screenshot_as_png
            img = Image.open(io.BytesIO(png))
            img.save(ARTIFACTS / f"{name}.png")
            state["topBrightPixels"] = bright_pixels(img, top=True)
            state["bottomBrightPixels"] = bright_pixels(img, top=False)
            results[name] = state
            print(name, json.dumps(state), flush=True)
    finally:
        driver.quit()
        server.shutdown()

    print("SUMMARY", json.dumps(results, indent=2), flush=True)
    if results["primary_only"]["bottomBrightPixels"] < 50:
        raise AssertionError(
            "Screenshot did not capture a visible primary subtitle; "
            "visual assessment is inconclusive on this runner"
        )
    for name in ("both_default", "one_default"):
        if results[name]["topBrightPixels"] < 50:
            raise AssertionError(f"Safari did not visibly paint secondary subtitle: {name}")
        if results[name]["bottomBrightPixels"] < 50:
            raise AssertionError(f"Safari did not visibly paint primary subtitle: {name}")
    print("PASS: Safari painted two captions with both default flags and with one.")
