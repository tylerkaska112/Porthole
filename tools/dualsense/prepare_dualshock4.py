# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 The Porthole authors. See LICENSE.
"""
Prepares the 3D DualShock 4 (the PS4 pad) for Porthole's Test controller page.

The model is "DualShock 4 PlayStation Controller" by shaielwolf (https://skfb.ly/oPRAI), licensed under Creative Commons Attribution 4.0 (http://creativecommons.org/licenses/by/4.0/). See
app/Models/DualShock4-LICENSE.txt and CREDITS.md. This script CHANGES it: it turns it to Porthole's axes, splits it into the parts that move, gives each a pivot and converts it to USD with its textures
as files.

    blender -b -P tools/dualsense/prepare_dualshock4.py -- --glb <model.glb> --out <folder> [--check]

Parts (named as the DualSense's are, so the app treats the two alike): stick_l stick_r cross circle square triangle dpad_up dpad_down dpad_left dpad_right ps create options l1 r1 l2 r2 touchpad,
and static_<material> for what does not move.
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy
from mathutils import Vector
import padlib

ARGS, arg = padlib.args()
GLB = arg("--glb")
OUT = arg("--out", "/tmp/ds4")
os.makedirs(OUT, exist_ok=True)

# The model's top is -Y and its front +Z; its left-right is already right: (x, y, z) -> (x, z, -y).
pieces = padlib.load(GLB, [[1, 0, 0], [0, 0, 1], [0, -1, 0]])

STICK_X = 25.5
FACE = {"triangle": (50.2, 31.8), "square": (38.7, 20.3), "circle": (61.7, 20.3), "cross": (50.2, 8.8)}
DPAD = {"dpad_up": (-50.2, 27.7), "dpad_left": (-57.6, 20.3), "dpad_down": (-50.2, 12.8), "dpad_right": (-42.8, 20.3)}


def near(c, x, y, r):
    return abs(c.x - x) < r and abs(c.y - y) < r


def classify(o):
    c, s, lo, hi = padlib.centre_size(o)
    m = padlib.mat_of(o)
    if m == "MAT_3" and abs(c.x) < 3:
        return "touchpad"
    if m == "MAT_4":
        for sx, name in ((-STICK_X, "stick_l"), (STICK_X, "stick_r")):
            if abs(c.x - sx) < 2.5 and abs(c.y + 1.9) < 2.5 and c.z > 30.0:
                return name
    if m == "MAT_5":
        for name, (x, y) in FACE.items():
            if near(c, x, y, 5.0) and c.z > 23.5:
                return name
        for name, (x, y) in DPAD.items():
            if near(c, x, y, 5.5) and 22.0 < c.z < 26.0:
                return name
        if abs(c.x) < 5 and 15 < c.z < 20:
            return "ps"
        if abs(abs(c.x) - 32.6) < 2.5 and c.y > 33:
            return "options" if c.x > 0 else "create"
    if m == "MAT_6" and 44 < abs(c.x) < 54:
        if c.y > 44 and c.z > 1.0:
            return "r1" if c.x > 0 else "l1"
        if c.y > 38 and c.z <= 1.0:
            return "r2" if c.x > 0 else "l2"
    return "static_" + m


def pivot_for(name, lo, hi):
    mid = Vector(((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, 0))
    if name.startswith("stick"):
        return Vector((mid.x, mid.y, lo.z))
    if name in ("l1", "r1"):
        return Vector((mid.x, lo.y + 2.0, hi.z - 2.0))
    if name in ("l2", "r2"):
        return Vector((mid.x, (lo.y + hi.y) / 2, hi.z - 1.0))
    return None


parts = padlib.join_groups(pieces, classify, pivot_for)
print("PARTS", {n: v["pieces"] for n, v in parts.items()})

if "--check" in ARGS:
    padlib.check_render(parts, OUT, {
        "top": ((0, -0.01, 520), (0, 0, 0), 70),
        "oblique": ((170, -230, 210), (0, 0, 0), 70),
        "front": ((0, 330, 40), (0, 0, 0), 70),
    })
    sys.exit(0)

for name in ("cross", "circle", "square", "triangle", "dpad_up", "dpad_down", "dpad_left", "dpad_right"):
    if name in parts:
        info = padlib.cap_info(name, set(bpy.data.objects[name].data.materials[i].name for i in range(len(bpy.data.objects[name].data.materials))))
        if info:
            parts[name]["cap"] = info

textures = padlib.export_textures(OUT, "ds4")
padlib.write_json(OUT, parts, textures, {"model": "dualshock4"})
padlib.export_usd(OUT)
os.replace(os.path.join(OUT, "model.usdc"), os.path.join(OUT, "DualShock4.usdc"))
os.replace(os.path.join(OUT, "model.json"), os.path.join(OUT, "DualShock4.json"))
print("EXPORTED", os.listdir(OUT))
