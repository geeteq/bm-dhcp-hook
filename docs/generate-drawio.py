#!/usr/bin/env python3
"""
generate-drawio.py — Build a draw.io diagram from a Markdown process-tree.

Source format (process-tree.md):
    # Diagram Title
    ## Phase Name
    - Top-level step
        - Sub-step (indent with spaces, consistent unit auto-detected)
            - Sub-sub-step
    ## Next Phase
    - Step ...

Usage:
    python3 generate-drawio.py [input.md] [output.drawio]

Defaults:
    input : src/process-tree.md
    output: output/<stem>.drawio
"""

import itertools
import os
import re
import sys
from xml.etree.ElementTree import Element, SubElement, tostring
from xml.dom import minidom

# ── Colour palette (cycles if more phases than entries) ──────────────────────
PALETTE = [
    {"fill": "#dae8fc", "border": "#6c8ebf"},  # blue
    {"fill": "#d5e8d4", "border": "#82b366"},  # green
    {"fill": "#fff2cc", "border": "#d6b656"},  # yellow
    {"fill": "#f8cecc", "border": "#b85450"},  # red
    {"fill": "#e1d5e7", "border": "#9673a6"},  # purple
]

# Fill colour per nesting level (level 0 = white, deeper = progressively grey)
LEVEL_FILLS = ["#ffffff", "#f5f5f5", "#ebebeb", "#e0e0e0"]

# ── Layout constants ─────────────────────────────────────────────────────────
PAGE_W       = 1500
TITLE_Y      = 20
TITLE_W      = 600
TITLE_H      = 70
TITLE_X      = (PAGE_W - TITLE_W) // 2
CONTAINER_W  = 750
CONTAINER_X  = (PAGE_W - CONTAINER_W) // 2
SWIMLANE_H   = 40    # header band height
STEP_PAD_L   = 40    # left padding for level-0 steps inside a phase
STEP_PAD_R   = 40    # right padding
INNER_PAD    = 10    # padding inside collapsible sub-containers
STEP_PAD_TOP = 12    # gap between header band and first step
STEP_PAD_BOT = 24    # gap below last step
STEP_H       = 50
STEP_GAP     = 21
PHASE_GAP    = 100
PHASE1_Y     = 100


# ── Markdown parser ───────────────────────────────────────────────────────────
def parse_md(text: str) -> dict:
    """Parse markdown into {title, phases:[{name, steps:[{text, children:[...]}]}]}."""
    title = "Process Tree"
    phases = []
    current_phase = None
    node_stack = []  # list of (level, node)

    # Auto-detect indent unit (smallest non-zero leading-space count on a list line)
    indent_unit = None
    for raw in text.splitlines():
        s = raw.lstrip()
        if s.startswith("- "):
            leading = len(raw) - len(s)
            if leading > 0 and (indent_unit is None or leading < indent_unit):
                indent_unit = leading
    if indent_unit is None:
        indent_unit = 4

    for raw in text.splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith("<!--"):
            continue

        if stripped.startswith("## "):
            if current_phase:
                phases.append(current_phase)
            current_phase = {"name": stripped[3:].strip(), "steps": []}
            node_stack = []
        elif re.match(r"^#\s", stripped):
            title = stripped[2:].strip()
        elif raw.lstrip().startswith("- ") and current_phase is not None:
            leading    = len(raw) - len(raw.lstrip())
            level      = leading // indent_unit
            item_text  = raw.lstrip()[2:].strip()
            if not item_text:
                continue

            node = {"text": item_text, "children": []}

            # Pop until we find the parent (something at a strictly lower level)
            while node_stack and node_stack[-1][0] >= level:
                node_stack.pop()

            if level == 0:
                current_phase["steps"].append(node)
            elif node_stack:
                node_stack[-1][1]["children"].append(node)
            elif current_phase["steps"]:
                # Orphaned indent — attach to last root step
                current_phase["steps"][-1]["children"].append(node)
            else:
                # No root steps yet — treat as root
                current_phase["steps"].append(node)

            node_stack.append((level, node))

    if current_phase:
        phases.append(current_phase)

    return {"title": title, "phases": phases}


# ── draw.io XML builder ───────────────────────────────────────────────────────
EDGE_S = (
    "edgeStyle=orthogonalEdgeStyle;rounded=0;"
    "orthogonalLoop=1;jettySize=auto;"
)
INTER_S = (
    EDGE_S
    + "exitX=0.5;exitY=1;exitDx=0;exitDy=0;"
    + "entryX=0.5;entryY=0;entryDx=0;entryDy=0;"
)


def _cell(root_el, *, cid, value="", style="", parent="1",
          vertex=None, edge=None, source=None, target=None,
          x=None, y=None, w=None, h=None, relative=False):
    attrs = {"id": cid, "value": value, "style": style, "parent": parent}
    if vertex is not None:
        attrs["vertex"] = str(vertex)
    if edge is not None:
        attrs["edge"] = str(edge)
    if source:
        attrs["source"] = source
    if target:
        attrs["target"] = target
    cell = SubElement(root_el, "mxCell", attrib=attrs)
    geo = {"as": "geometry"}
    if relative:
        geo["relative"] = "1"
    else:
        geo.update({"x": str(x), "y": str(y), "width": str(w), "height": str(h)})
    SubElement(cell, "mxGeometry", attrib=geo)
    return cell


def _steps_height(steps: list) -> int:
    """Recursively compute the total height of a step list."""
    if not steps:
        return 0
    total = 0
    for i, step in enumerate(steps):
        if i > 0:
            total += STEP_GAP
        if step.get("children"):
            total += SWIMLANE_H + STEP_PAD_TOP + _steps_height(step["children"]) + STEP_PAD_BOT
        else:
            total += STEP_H
    return total


def _render_steps(root_el, parent_id, steps, pi, col, start_y, avail_w, cid_gen, level=0):
    """
    Render steps as children of parent_id (positions relative to parent).
    Steps with children become collapsible swimlane containers.
    Returns list of cell IDs for the items rendered at this level.
    """
    sids = []
    y    = start_y
    x    = STEP_PAD_L if level == 0 else INNER_PAD
    w    = avail_w - x - (STEP_PAD_R if level == 0 else INNER_PAD)
    fill = LEVEL_FILLS[min(level, len(LEVEL_FILLS) - 1)]
    font = "fontStyle=0;fontSize=14;" if level == 0 else "fontStyle=2;fontSize=12;"

    for step in steps:
        sid = next(cid_gen)

        if step.get("children"):
            inner_h = _steps_height(step["children"])
            node_h  = SWIMLANE_H + STEP_PAD_TOP + inner_h + STEP_PAD_BOT

            _cell(root_el, cid=sid, value=step["text"], parent=parent_id,
                  style=(
                      f"swimlane;startSize={SWIMLANE_H};collapsible=1;"
                      f"fillColor={fill};strokeColor={col['border']};"
                      f"swimlaneLine=1;rounded=1;arcSize=4;{font}"
                  ),
                  vertex=1, x=x, y=y, w=w, h=node_h)

            child_sids = _render_steps(
                root_el, sid, step["children"], pi, col,
                SWIMLANE_H + STEP_PAD_TOP, w, cid_gen, level + 1,
            )

            # Edges between children
            for ci in range(1, len(child_sids)):
                _cell(root_el, cid=f"e_{child_sids[ci-1]}_{child_sids[ci]}",
                      value="", style=EDGE_S, edge=1,
                      source=child_sids[ci - 1], target=child_sids[ci],
                      parent=sid, relative=True)
        else:
            node_h = STEP_H
            _cell(root_el, cid=sid, value=step["text"], parent=parent_id,
                  style=(
                      f"rounded=1;whiteSpace=wrap;html=1;"
                      f"fillColor={fill};strokeColor={col['border']};"
                      f"arcSize=10;{font}"
                  ),
                  vertex=1, x=x, y=y, w=w, h=STEP_H)

        sids.append(sid)
        y += node_h + STEP_GAP

    return sids


def build_xml(data: dict) -> str:
    title  = data["title"]
    phases = data["phases"]

    mxfile  = Element("mxfile", attrib={"host": "generate-drawio.py", "version": "21.0.0"})
    diagram = SubElement(mxfile, "diagram", name=title, id="process-tree")
    model   = SubElement(diagram, "mxGraphModel", attrib={
        "dx": "1200", "dy": "800", "grid": "1", "gridSize": "10",
        "guides": "1", "tooltips": "1", "connect": "1", "arrows": "1",
        "fold": "1", "page": "1", "pageScale": "1",
        "pageWidth": str(PAGE_W), "pageHeight": "2200", "math": "0", "shadow": "0",
    })
    root = SubElement(model, "root")
    SubElement(root, "mxCell", id="0")
    SubElement(root, "mxCell", id="1", parent="0")

    # Title
    _cell(root, cid="title", value=title, parent="1",
          style=(
              "text;html=1;strokeColor=none;fillColor=none;"
              "align=center;verticalAlign=middle;whiteSpace=wrap;"
              "fontSize=22;fontStyle=1;"
          ),
          vertex=1, x=TITLE_X, y=TITLE_Y, w=TITLE_W, h=TITLE_H)

    current_y  = PHASE1_Y
    prev_ph_id = None

    for pi, phase in enumerate(phases):
        col   = PALETTE[pi % len(PALETTE)]
        ph_id = f"ph{pi}"

        if not phase["steps"]:
            continue

        inner_h = _steps_height(phase["steps"])
        ph_h    = SWIMLANE_H + STEP_PAD_TOP + inner_h + STEP_PAD_BOT

        # Phase swimlane container
        _cell(root, cid=ph_id, value=phase["name"], parent="1",
              style=(
                  f"swimlane;fontStyle=1;fontSize=16;"
                  f"fillColor={col['fill']};strokeColor={col['border']};"
                  f"swimlaneLine=1;startSize={SWIMLANE_H};rounded=1;arcSize=4;"
              ),
              vertex=1, x=CONTAINER_X, y=current_y, w=CONTAINER_W, h=ph_h)

        cid_gen = (f"ph{pi}_s{i}" for i in itertools.count())
        sids    = _render_steps(root, ph_id, phase["steps"], pi, col,
                                SWIMLANE_H + STEP_PAD_TOP, CONTAINER_W, cid_gen)

        # Intra-phase edges between root-level steps
        for fi in range(1, len(sids)):
            _cell(root, cid=f"e_ph{pi}_{fi-1}_{fi}", value="",
                  style=EDGE_S, edge=1,
                  source=sids[fi - 1], target=sids[fi],
                  parent=ph_id, relative=True)

        # Inter-phase edge (previous phase heading → this phase heading)
        if prev_ph_id:
            _cell(root, cid=f"e_inter_{pi}", value="",
                  style=INTER_S, edge=1,
                  source=prev_ph_id, target=ph_id,
                  parent="1", relative=True)

        prev_ph_id = ph_id
        current_y += ph_h + PHASE_GAP

    raw = tostring(mxfile, encoding="unicode")
    return minidom.parseString(raw).toprettyxml(indent="  ")


def main():
    args     = sys.argv[1:]
    in_file  = args[0] if args else "src/process-tree.md"
    if len(args) > 1:
        out_file = args[1]
    else:
        stem     = os.path.splitext(os.path.basename(in_file))[0]
        out_file = os.path.join("output", stem + ".drawio")

    with open(in_file) as fh:
        data = parse_md(fh.read())

    xml = build_xml(data)

    with open(out_file, "w") as fh:
        fh.write(xml)

    print(f"Written → {out_file}")


if __name__ == "__main__":
    main()
