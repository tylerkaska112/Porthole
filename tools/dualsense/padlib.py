# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 The Porthole authors. See LICENSE.
"""
Shared steps for turning a glTF controller model into the parts Porthole's Test controller page moves. Used by prepare_dualshock4.py and prepare_xbox.py (the DualSense has its own script from before this
module existed). Run inside Blender. The models are other people's work under Creative Commons Attribution 4.0: see app/Models/*-LICENSE.txt and CREDITS.md. These scripts CHANGE them (orient, split, pivot,
convert), which the licence asks to be said.

Axes of the result: millimetres, X to the right, Y toward the front (away from the player), Z up, centred on the middle of the pad.
"""
import bpy
import json
import math
import os
import sys
from mathutils import Matrix, Vector


def bounds(objs):
    mn = Vector((1e9,) * 3)
    mx = Vector((-1e9,) * 3)
    for o in objs:
        for v in o.bound_box:
            w = o.matrix_world @ Vector(v)
            mn = Vector((min(mn[i], w[i]) for i in range(3)))
            mx = Vector((max(mx[i], w[i]) for i in range(3)))
    return mn, mx


def centre_size(o):
    lo, hi = bounds([o])
    return (lo + hi) / 2, hi - lo, lo, hi


def mat_of(o):
    return o.data.materials[0].name if o.data.materials else "-"


def load(glb, turn, width_mm=160.0):
    """Imports the model, bakes every transform, turns it by `turn` (a 3x3 given as rows, mapping the model's axes to X right, Y front, Z up), scales its width to `width_mm`, centres it, and splits it
    into loose pieces. Returns the pieces."""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=glb)
    meshes = [o for o in bpy.data.objects if o.type == 'MESH']
    for o in meshes:
        o.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    bpy.ops.object.parent_clear(type='CLEAR_KEEP_TRANSFORM')
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    for o in bpy.data.objects:
        if o.type != 'MESH':
            bpy.data.objects.remove(o)
    mn, mx = bounds(meshes)
    t = Matrix(((turn[0][0], turn[0][1], turn[0][2], 0), (turn[1][0], turn[1][1], turn[1][2], 0), (turn[2][0], turn[2][1], turn[2][2], 0), (0, 0, 0, 1)))
    # The width is measured along the model's own left-right axis, which `turn` sends to X.
    k = width_mm / max((t @ Vector((mx.x - mn.x, 0, 0))).length, 1e-9)
    mid = (mn + mx) / 2
    fix = t @ Matrix.Scale(k, 4) @ Matrix.Translation(-mid)
    for o in meshes:
        o.data.transform(fix)
        o.matrix_world = Matrix.Identity(4)
    for o in list(meshes):
        bpy.ops.object.select_all(action='DESELECT')
        o.select_set(True)
        bpy.context.view_layer.objects.active = o
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.mesh.select_all(action='SELECT')
        bpy.ops.mesh.separate(type='LOOSE')
        bpy.ops.object.mode_set(mode='OBJECT')
    return [o for o in bpy.data.objects if o.type == 'MESH']


def join_groups(pieces, classify, pivot_for):
    """Joins the pieces `classify` gives the same name into one object each. `pivot_for(name, lo, hi)` gives a part's pivot (None = the middle of its base; static parts keep the origin).
    Returns {name: {materials, pivot, pieces}} and leaves the objects named."""
    groups = {}
    for o in pieces:
        groups.setdefault(classify(o), []).append(o)
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
        if name.startswith("static"):
            pivot = Vector((0, 0, 0))
        else:
            pivot = pivot_for(name, lo, hi) or Vector(((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, lo.z))
        obj.data.transform(Matrix.Translation(-pivot))
        obj.location = pivot
        for p in obj.data.polygons:
            p.use_smooth = True
        parts[name] = {"materials": [m.name for m in obj.data.materials], "pivot": [round(pivot.x, 3), round(pivot.y, 3), round(pivot.z, 3)], "pieces": len(objs)}
    return parts


def cap_info(name, material_names):
    """Where the top of a button's cap is (in the part's own axes), found by looking straight down at the middle of the faces that use `material_names`."""
    obj = bpy.data.objects[name]
    me = obj.data
    cap = [me.vertices[vi].co for p in me.polygons if me.materials[p.material_index].name in material_names for vi in p.vertices]
    if not cap:
        return None
    lo = Vector((min(v.x for v in cap), min(v.y for v in cap), min(v.z for v in cap)))
    hi = Vector((max(v.x for v in cap), max(v.y for v in cap), max(v.z for v in cap)))
    cx, cy = (lo.x + hi.x) / 2, (lo.y + hi.y) / 2
    hit, loc, nrm, _i = obj.ray_cast(Vector((cx, cy, hi.z + 5)), Vector((0, 0, -1)))
    return {"x": round(cx, 3), "y": round(cy, 3), "z": round(loc.z if hit else hi.z, 3), "normal": [round(c, 4) for c in (nrm if hit else Vector((0, 0, 1)))],
            "radius": round(min(hi.x - lo.x, hi.y - lo.y) / 2, 3)}


def export_textures(out, prefix, opaque_over=None):
    """Writes every texture of every material as a file (`<prefix>_<material>_<kind>.<ext>`) and returns {material: {base, orm, normal, emission}}. `opaque_over` = an (r, g, b) the base colour is
    laid over before it is written fully opaque (some models draw a part see-through, which looks like a hole); None leaves the alpha as it is."""
    import numpy as np
    tex = {}
    for m in bpy.data.materials:
        nt = m.node_tree
        entry = {}
        for n in nt.nodes:
            if n.type != 'TEX_IMAGE' or not n.image:
                continue
            kind = None
            for out_socket in n.outputs:
                for l in out_socket.links:
                    if l.to_socket.name == 'Base Color':
                        kind = "base"
                    elif l.to_socket.name == 'Emission Color':
                        kind = "emission"
                    elif l.to_node.type == 'NORMAL_MAP':
                        kind = "normal"
                    elif l.to_node.type == 'SEPARATE_COLOR':
                        kind = kind or "orm"
            if not kind or kind in entry:
                continue
            if kind == "base" and opaque_over is not None:
                px = np.empty(len(n.image.pixels), dtype=np.float32)
                n.image.pixels.foreach_get(px)
                px = px.reshape(-1, 4)
                alpha = px[:, 3:4]
                px[:, :3] = np.array(opaque_over, dtype=np.float32) * (1 - alpha) + px[:, :3] * alpha
                px[:, 3] = 1.0
                n.image.pixels.foreach_set(px.reshape(-1))
            ext = "jpg" if n.image.file_format == 'JPEG' else "png"
            fname = f"{prefix}_{m.name}_{kind}.{ext}"
            n.image.filepath_raw = os.path.join(out, fname)
            n.image.file_format = 'JPEG' if ext == "jpg" else 'PNG'
            n.image.save()
            entry[kind] = fname
        tex[m.name] = entry
    return tex


def check_render(parts, out, views, lens=70, size=(1000, 760)):
    """A picture with each part in its own colour (the rest grey), to check which piece is which. `views` = {name: (camera location, aim)}."""
    import colorsys
    names = sorted(parts)
    scene = bpy.context.scene
    for i, n in enumerate(names):
        mm = bpy.data.materials.new("chk_" + n)
        mm.use_nodes = True
        r, g, b = colorsys.hsv_to_rgb(i / len(names), 0.75, 1.0)
        bsdf = mm.node_tree.nodes["Principled BSDF"]
        bsdf.inputs["Base Color"].default_value = (r, g, b, 1)
        bsdf.inputs["Emission Color"].default_value = (r, g, b, 1)
        bsdf.inputs["Emission Strength"].default_value = 0.6
        if n.startswith("static"):
            bsdf.inputs["Base Color"].default_value = (0.35, 0.35, 0.38, 1)
            bsdf.inputs["Emission Strength"].default_value = 0.0
        o = bpy.data.objects[n]
        o.data.materials.clear()
        o.data.materials.append(mm)
    scene.render.engine = 'BLENDER_EEVEE'
    scene.render.resolution_x, scene.render.resolution_y = size
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
    cam.data.clip_end = 5000
    scene.camera = cam
    for vname, (loc, aim, lens_) in views.items():
        cam.data.lens = lens_
        cam.location = loc
        cam.rotation_euler = (Vector(aim) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()
        scene.render.filepath = os.path.join(out, f"check_{vname}.png")
        bpy.ops.render.render(write_still=True)


def export_usd(out):
    scene = bpy.context.scene
    scene.unit_settings.system = 'METRIC'
    scene.unit_settings.scale_length = 0.001
    scene.world = None
    for o in bpy.data.objects:
        o.select_set(o.type == 'MESH')
    bpy.ops.wm.usd_export(filepath=os.path.join(out, "model.usdc"), selected_objects_only=True, export_materials=True, generate_preview_surface=True, export_normals=True,
                          export_uvmaps=True, export_textures_mode='KEEP', convert_scene_units='MILLIMETERS', root_prim_path="/Pad", export_animation=False)


def write_json(out, parts, textures, extra=None):
    d = {"parts": parts, "materials": textures}
    d.update(extra or {})
    with open(os.path.join(out, "model.json"), "w") as f:
        json.dump(d, f, indent=1)


def args():
    a = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    def get(name, default=None):
        return a[a.index(name) + 1] if name in a and a.index(name) + 1 < len(a) else default
    return a, get
