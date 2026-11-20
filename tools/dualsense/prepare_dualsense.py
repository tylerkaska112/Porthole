# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 The Porthole authors. See LICENSE.
"""
Prepares the 3D DualSense for Porthole's Test controller page from a glTF model, so the app can move its parts.

The model is "Playstation 5 Dualsense" by AHarmlessPotato (https://skfb.ly/opKOx), licensed under Creative Commons Attribution 4.0 (http://creativecommons.org/licenses/by/4.0/). It is not part of
this repository's own work: see app/Models/DualSense-LICENSE.txt and CREDITS.md. This script CHANGES it, as the licence asks to be said: it turns the model to Porthole's axes, splits it into
the parts that move (sticks, buttons, d-pad keys, bumpers, triggers, touchpad), gives each part a pivot, and writes it as USD with its textures as separate files.

Run with Blender in the background:

    blender -b -P tools/dualsense/prepare_dualsense.py -- --glb <model.glb> --out <folder> [--check]

Axes of the result: millimetres, X to the right, Y toward the touchpad (away from the player), Z up. Every moving part is an object of its own named as below, with its origin where it turns or sinks:
    stick_l stick_r cross circle square triangle dpad_up dpad_down dpad_left dpad_right ps create options mute l1 r1 l2 r2 touchpad lightbar
and what does not move is joined into static_1011 / static_1001 / static_1002 (one per material).
Besides DualSense.usdc the folder gets DualSense.json (each part's materials in order, its pivot) and the textures as ds_<material>_<kind>.png/jpg.
"""
import bpy
import json
import math
import os
import sys
from mathutils import Matrix, Vector

ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []


def arg(name, default=None):
    return ARGS[ARGS.index(name) + 1] if name in ARGS and ARGS.index(name) + 1 < len(ARGS) else default


GLB = arg("--glb")
OUT = arg("--out", "/tmp/dualsense")
os.makedirs(OUT, exist_ok=True)

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
bpy.ops.import_scene.gltf(filepath=GLB)

# ----------------------------------------------------------------------------------------------------------------------------------------------------------------------
# Bake every transform, then turn the model: its top is +Y, its touchpad +Z and its left-right is mirrored, so (x, y, z) -> (-x, z, y) (a proper rotation), centred, in millimetres.
# ----------------------------------------------------------------------------------------------------------------------------------------------------------------------
meshes = [o for o in bpy.data.objects if o.type == 'MESH']
for o in meshes:
    o.select_set(True)
bpy.context.view_layer.objects.active = meshes[0]
bpy.ops.object.parent_clear(type='CLEAR_KEEP_TRANSFORM')
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
for o in bpy.data.objects:
    if o.type != 'MESH':
        bpy.data.objects.remove(o)


def bounds(objs):
    mn = Vector((1e9,) * 3)
    mx = Vector((-1e9,) * 3)
    for o in objs:
        for v in o.bound_box:
            w = o.matrix_world @ Vector(v)
            mn = Vector((min(mn[i], w[i]) for i in range(3)))
            mx = Vector((max(mx[i], w[i]) for i in range(3)))
    return mn, mx


mn, mx = bounds(meshes)
k = 160.0 / (mx.x - mn.x)
mid = (mn + mx) / 2
turn = Matrix(((-1, 0, 0, 0), (0, 0, 1, 0), (0, 1, 0, 0), (0, 0, 0, 1)))
fix = turn @ Matrix.Scale(k, 4) @ Matrix.Translation(-mid)
for o in meshes:
    o.data.transform(fix)
    o.matrix_world = Matrix.Identity(4)

# ----------------------------------------------------------------------------------------------------------------------------------------------------------------------
# Split into loose pieces
# ----------------------------------------------------------------------------------------------------------------------------------------------------------------------
for o in list(meshes):
    bpy.ops.object.select_all(action='DESELECT')
    o.select_set(True)
    bpy.context.view_layer.objects.active = o
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.mesh.separate(type='LOOSE')
    bpy.ops.object.mode_set(mode='OBJECT')
pieces = [o for o in bpy.data.objects if o.type == 'MESH']


def centre_size(o):
    lo, hi = bounds([o])
    return (lo + hi) / 2, hi - lo, lo, hi


def mat_of(o):
    return o.data.materials[0].name if o.data.materials else "-"


# ----------------------------------------------------------------------------------------------------------------------------------------------------------------------
# Which piece is which. Positions are in the pad's own axes (millimetres) and came from looking at the model; each rule picks the pieces that sit at a spot.
# ----------------------------------------------------------------------------------------------------------------------------------------------------------------------
STICK_X = 25.4
FACE = {"triangle": (49.8, 33.9), "square": (38.1, 22.1), "cross": (49.8, 10.3), "circle": (61.6, 22.1)}
DPAD = {"dpad_up": (-49.6, 30.1), "dpad_right": (-41.9, 21.9), "dpad_down": (-50.1, 14.1), "dpad_left": (-57.8, 22.4)}


def near(c, x, y, r):
    return abs(c.x - x) < r and abs(c.y - y) < r


def classify(o):
    c, s, lo, hi = centre_size(o)
    m = mat_of(o)
    # Sticks: the cap, its ring and its stem (the part of each stick that rises above the plate).
    for sx, name in ((-STICK_X, "stick_l"), (STICK_X, "stick_r")):
        if abs(c.x - sx) < 2.5 and abs(c.y) < 2.5 and c.z > 26.5:
            return name
        # The base of the stick: the cup and boot that turn with it, between the plate and the cap.
        if abs(c.x - sx) < 2.5 and abs(c.y) < 2.5 and 21.5 < c.z <= 26.5:
            return name + "_base"
    for name, (x, y) in FACE.items():
        if near(c, x, y, 7.0) and 20.0 < c.z < 27.5:
            return name
    for name, (x, y) in DPAD.items():
        if near(c, x, y, 6.5) and 19.0 < c.z < 27.5:
            return name
    if m == "1011" and abs(c.x) < 3 and 30 < c.y < 38 and 17 < c.z < 22 and 60 < s.x < 68:
        return "touchpad"
    if m == "1001" and abs(c.x) < 3 and 38 < c.y < 44 and 16 < c.z < 21 and s.x > 60:
        return "lightbar"
    if abs(c.x) < 7 and 17 < c.z < 22 and -4 < c.y < 6:
        return "ps"
    if abs(c.x) < 6 and abs(c.y + 8.2) < 3 and 15 < c.z < 19.5:
        return "mute"
    if abs(c.y - 39.5) < 3.5 and abs(c.z - 23.5) < 3.5 and 35 < abs(c.x) < 40:
        return "options" if c.x > 0 else "create"
    # The bumpers sit on the front edge at the top; the triggers hang below them.
    if 44 < abs(c.x) < 55 and 43 < c.y < 49 and 6 < c.z < 15 and m == "1001":
        return "r1" if c.x > 0 else "l1"
    if 44 < abs(c.x) < 55 and 39 < c.y < 46 and -14 < c.z < -4 and m == "1001":
        return "r2" if c.x > 0 else "l2"
    return "static_" + m


groups = {}
for o in pieces:
    groups.setdefault(classify(o), []).append(o)

# ----------------------------------------------------------------------------------------------------------------------------------------------------------------------
# Join each group into one object and set its pivot
# ----------------------------------------------------------------------------------------------------------------------------------------------------------------------
PIVOT = {
    # name: how to find the pivot from the group's bounds (lo, hi)
    "stick_l": lambda lo, hi: Vector(((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, 24.0)),
    "stick_r": lambda lo, hi: Vector(((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, 24.0)),
    "stick_l_base": lambda lo, hi: Vector(((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, 24.0)),
    "stick_r_base": lambda lo, hi: Vector(((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, 24.0)),
    "l1": lambda lo, hi: Vector(((lo.x + hi.x) / 2, lo.y + 2.0, hi.z - 2.0)),
    "r1": lambda lo, hi: Vector(((lo.x + hi.x) / 2, lo.y + 2.0, hi.z - 2.0)),
    "l2": lambda lo, hi: Vector(((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, hi.z - 1.0)),
    "r2": lambda lo, hi: Vector(((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, hi.z - 1.0)),
}
parts = {}
for name, objs in groups.items():
    bpy.ops.object.select_all(action='DESELECT')
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    if len(objs) > 1:
        bpy.ops.object.join()
    obj = bpy.context.view_layer.objects.active
    obj.name = name
    obj.data.name = name
    lo, hi = bounds([obj])
    pivot = PIVOT[name](lo, hi) if name in PIVOT else Vector(((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, lo.z if not name.startswith("static") else 0.0))
    if name.startswith("static"):
        pivot = Vector((0, 0, 0))
    obj.data.transform(Matrix.Translation(-pivot))
    obj.location = pivot
    entry = {"materials": [m.name for m in obj.data.materials], "pivot": [round(pivot.x, 3), round(pivot.y, 3), round(pivot.z, 3)], "pieces": len(objs)}
    if name in ("cross", "circle", "square", "triangle", "dpad_up", "dpad_down", "dpad_left", "dpad_right"):
        # Where the top of the button's cap is (in the part's own axes), so the app can print its symbol there: the model keeps the symbols inside the clear cap, out of sight once the cap is solid.
        me_ = obj.data
        cap = [me_.vertices[vi].co for p_ in me_.polygons if me_.materials[p_.material_index].name == "1001" for vi in p_.vertices]
        lo_ = Vector((min(v.x for v in cap), min(v.y for v in cap), min(v.z for v in cap)))
        hi_ = Vector((max(v.x for v in cap), max(v.y for v in cap), max(v.z for v in cap)))
        cx, cy = (lo_.x + hi_.x) / 2, (lo_.y + hi_.y) / 2
        # The cap's top is dished and the button leans, so find its surface by looking straight down at the middle of it.
        hit, loc, nrm, _i = obj.ray_cast(Vector((cx, cy, hi_.z + 5)), Vector((0, 0, -1)))
        entry["cap"] = {"x": round(cx, 3), "y": round(cy, 3), "z": round(loc.z if hit else hi_.z, 3), "normal": [round(c, 4) for c in (nrm if hit else Vector((0, 0, 1)))],
                        "radius": round(min(hi_.x - lo_.x, hi_.y - lo_.y) / 2, 3)}
    parts[name] = entry
    for p in obj.data.polygons:
        p.use_smooth = True

print("PARTS", {n: v["pieces"] for n, v in parts.items()})

# ----------------------------------------------------------------------------------------------------------------------------------------------------------------------
# Textures (the model's own, as files) and the material list
# ----------------------------------------------------------------------------------------------------------------------------------------------------------------------
tex = {}
for m in bpy.data.materials:
    nt = m.node_tree
    entry = {}
    for n in nt.nodes:
        if n.type != 'TEX_IMAGE' or not n.image:
            continue
        kind = None
        for out in n.outputs:
            for l in out.links:
                if l.to_socket.name == 'Base Color':
                    kind = "base"
                elif l.to_socket.name == 'Emission Color':
                    kind = "emission"
                elif l.to_node.type == 'NORMAL_MAP':
                    kind = "normal"
                elif l.to_node.type == 'SEPARATE_COLOR':
                    kind = "orm"
        if kind:
            if kind == "base":
                # The model draws the faces of the buttons see-through (they are clear plastic on the real pad) and leaves only the printed symbols solid. Drawn that way the buttons look like holes,
                # so the texture is laid over light plastic and written fully opaque: the faces become plastic and the symbols stay on them.
                import numpy as np
                px = np.empty(len(n.image.pixels), dtype=np.float32)
                n.image.pixels.foreach_get(px)
                px = px.reshape(-1, 4)
                alpha = px[:, 3:4]
                plastic = np.array([0.90, 0.90, 0.93], dtype=np.float32)
                px[:, :3] = plastic * (1 - alpha) + px[:, :3] * alpha
                px[:, 3] = 1.0
                n.image.pixels.foreach_set(px.reshape(-1))
            ext = "jpg" if n.image.file_format == 'JPEG' else "png"
            fname = f"ds_{m.name}_{kind}.{ext}"
            n.image.filepath_raw = os.path.join(OUT, fname)
            n.image.file_format = 'JPEG' if ext == "jpg" else 'PNG'
            n.image.save()
            entry[kind] = fname
    b = nt.nodes.get("Principled BSDF")
    entry["alpha"] = m.blend_method if hasattr(m, "blend_method") else "OPAQUE"
    tex[m.name] = entry
with open(os.path.join(OUT, "DualSense.json"), "w") as f:
    json.dump({"parts": parts, "materials": tex}, f, indent=1)

# ----------------------------------------------------------------------------------------------------------------------------------------------------------------------
# A picture of what each part is, for checking the rules above
# ----------------------------------------------------------------------------------------------------------------------------------------------------------------------
if "--check" in ARGS:
    palette = {}
    names = sorted(parts)
    for i, n in enumerate(names):
        mm = bpy.data.materials.new("chk_" + n)
        mm.use_nodes = True
        h = i / len(names)
        import colorsys
        r, g, b = colorsys.hsv_to_rgb(h, 0.75, 1.0)
        bsdf = mm.node_tree.nodes["Principled BSDF"]
        bsdf.inputs["Base Color"].default_value = (r, g, b, 1)
        bsdf.inputs["Emission Color"].default_value = (r, g, b, 1)
        bsdf.inputs["Emission Strength"].default_value = 0.6
        palette[n] = (mm, (r, g, b))
        o = bpy.data.objects[n]
        o.data.materials.clear()
        o.data.materials.append(mm)
        if n.startswith("static"):
            mm.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.35, 0.35, 0.38, 1)
            mm.node_tree.nodes["Principled BSDF"].inputs["Emission Strength"].default_value = 0.0
    scene.render.engine = 'BLENDER_EEVEE'
    scene.render.resolution_x, scene.render.resolution_y = 1000, 760
    world = bpy.data.worlds.new("w")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.2, 0.22, 0.27, 1)
    scene.world = world
    for nme, loc, e in (("a", (1, -1, 2), 3.0), ("b", (-1, 1, 1), 1.5)):
        ld = bpy.data.lights.new(nme, 'SUN')
        ld.energy = e
        lo_ = bpy.data.objects.new(nme, ld)
        scene.collection.objects.link(lo_)
        lo_.rotation_euler = (Vector((0, 0, 0)) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    scene.collection.objects.link(cam)
    cam.data.lens = 70
    cam.data.clip_end = 5000
    scene.camera = cam
    for vname, loc in (("top", (0, -0.01, 520)), ("oblique", (170, -230, 210)), ("front", (0, 330, 40)), ("stick", (55, -45, 60))):
        cam.location = loc
        aim = Vector((25.4, 0, 22)) if vname == "stick" else Vector((0, 0, 0))
        cam.data.lens = 120 if vname == "stick" else 70
        cam.rotation_euler = (aim - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()
        scene.render.filepath = os.path.join(OUT, f"check_{vname}.png")
        bpy.ops.render.render(write_still=True)
    print("LEGEND", {n: tuple(round(c, 2) for c in palette[n][1]) for n in names})
    sys.exit(0)

# ----------------------------------------------------------------------------------------------------------------------------------------------------------------------
# Export the geometry
# ----------------------------------------------------------------------------------------------------------------------------------------------------------------------
scene.unit_settings.system = 'METRIC'
scene.unit_settings.scale_length = 0.001
scene.world = None
for o in bpy.data.objects:
    o.select_set(o.type == 'MESH')
bpy.ops.wm.usd_export(filepath=os.path.join(OUT, "DualSense.usdc"), selected_objects_only=True, export_materials=True, generate_preview_surface=True, export_normals=True,
                      export_uvmaps=True, export_textures_mode='KEEP', convert_scene_units='MILLIMETERS', root_prim_path="/DualSense", export_animation=False)
print("EXPORTED", os.listdir(OUT))
