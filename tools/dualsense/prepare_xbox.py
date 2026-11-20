# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 The Porthole authors. See LICENSE.
"""
Prepares the 3D Xbox controller for Porthole's Test controller page.

The model is "Xbox Controller" by umkhero (https://skfb.ly/6VtqJ), licensed under Creative Commons Attribution 4.0 (http://creativecommons.org/licenses/by/4.0/). See app/Models/Xbox-LICENSE.txt and
CREDITS.md. This script CHANGES it: it turns it to Porthole's axes (and tips it forward 18 degrees, because the model is drawn tilted), splits it into the parts that move, gives each a pivot and
converts it to USD with its texture as a file.

    blender -b -P tools/dualsense/prepare_xbox.py -- --glb <model.glb> --out <folder> [--check]

Parts: stick_l stick_r a b x y dpad (one piece that rocks) lb rb lt rt guide view menu, and static_<material> for what does not move.
"""
import math
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy
from mathutils import Vector
import padlib

ARGS, arg = padlib.args()
GLB = arg("--glb")
OUT = arg("--out", "/tmp/xbox")
os.makedirs(OUT, exist_ok=True)

# The model's top is -Y and its front +Z: (x, y, z) -> (x, z, -y); then tipped 18 degrees about X so the face of the pad is level.
c, s = math.cos(math.radians(18)), math.sin(math.radians(18))
TURN = [[1, 0, 0], [0, s, c], [0, -c, s]]
pieces = padlib.load(GLB, TURN)

STICKS = {"stick_l": (-39.8, 21.4), "stick_r": (20.4, -2.6)}
FACE = {"y": (40.6, 32.9), "x": (29.7, 22.2), "b": (51.3, 22.2), "a": (40.4, 11.7)}
DPAD = (-20.6, -3.4)
GUIDE = (0.0, 38.9)
MID = {"view": (-11.5, 22.3), "menu": (11.4, 22.3)}


def near(c, p, r):
    return abs(c.x - p[0]) < r and abs(c.y - p[1]) < r


def classify(o):
    ctr, size, lo, hi = padlib.centre_size(o)
    for name, p in STICKS.items():
        if near(ctr, p, 9.5) and ctr.z > 23.5:
            return name
    for name, p in FACE.items():
        if near(ctr, p, 6.0) and ctr.z > 15:
            return name
    if near(ctr, DPAD, 12.5) and ctr.z > 17 and size.x > 20 and size.y > 20:
        return "dpad"
    if near(ctr, GUIDE, 5.0) and ctr.z > 19:
        return "guide"
    for name, p in MID.items():
        if near(ctr, p, 4.5) and ctr.z > 19:
            return name
    if abs(abs(ctr.x) - 39.2) < 2 and abs(ctr.y - 46.4) < 2 and size.x > 30:
        return "rb" if ctr.x > 0 else "lb"
    if abs(abs(ctr.x) - 45.4) < 2 and abs(ctr.y - 45.9) < 2 and size.z > 20:
        return "rt" if ctr.x > 0 else "lt"
    return "static_" + padlib.mat_of(o)


def pivot_for(name, lo, hi):
    mid = Vector(((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, 0))
    if name.startswith("stick"):
        return Vector((mid.x, mid.y, lo.z))
    if name == "dpad":
        return Vector((mid.x, mid.y, (lo.z + hi.z) / 2))
    if name in ("lb", "rb"):
        return Vector((mid.x, lo.y + 2.0, hi.z - 2.0))
    if name in ("lt", "rt"):
        return Vector((mid.x, mid.y, hi.z - 2.0))
    return None


parts = padlib.join_groups(pieces, classify, pivot_for)
print("PARTS", {n: v["pieces"] for n, v in parts.items()})

if "--check" in ARGS:
    padlib.check_render(parts, OUT, {
        "top": ((0, -0.01, 520), (0, 0, 0), 70),
        "oblique": ((170, -230, 210), (0, 0, 0), 70),
        "front": ((0, 330, 40), (0, 0, 0), 70),
        "side": ((330, 0, 40), (0, 0, 0), 70),
    })
    sys.exit(0)

textures = padlib.export_textures(OUT, "xbox", opaque_over=(0.9, 0.9, 0.93))
roles = {"ls": "stick_l", "rs": "stick_r", "a": "a", "b": "b", "x": "x", "y": "y", "up": "dpad", "down": "dpad", "left": "dpad", "right": "dpad",
         "lb": "lb", "rb": "rb", "lt": "lt", "rt": "rt", "home": "guide", "view": "view", "menu": "menu"}
padlib.write_json(OUT, parts, textures, {"model": "xbox", "roles": roles, "decals": {}})
padlib.export_usd(OUT)
os.replace(os.path.join(OUT, "model.usdc"), os.path.join(OUT, "Xbox.usdc"))
os.replace(os.path.join(OUT, "model.json"), os.path.join(OUT, "Xbox.json"))
print("EXPORTED", os.listdir(OUT))
