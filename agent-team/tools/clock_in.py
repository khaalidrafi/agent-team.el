#!/usr/bin/env python3
"""TIME LAW automated clock-in (Owner order 2026-10-26 10:42 #hq).

CANONICAL COPY: khaalidrafi/agent-team.el agent-team/tools/clock_in.py
(no-duplication law 2026-10-26: common files live in ONE repo — team CIs
fetch this file at a pinned commit sha, they never vendor a copy).

The BEGINNING of a task is the EXACT time its prompt is sent to the
member.  In team CI the send moment is the dispatch step right before the
harness container runs: the HOST (never the member) flips the item the
WORK ORDER will assign to ONGOING and stamps the send instant into the
item's :LOGBOOK: as an OPEN Org clock.  Web/cloud models are the only
manual exception (they never run through this path).

Usage: clock_in.py BOARD MARKER

  BOARD   the board org file (e.g. agent-team/TODOS.org)
  MARKER  a substring of the target headline (the dispatched item)

Behaviour:
  - target = the first headline whose keyword is open
    (TODO|ONGOING|PENDING|WAIT|PROGRESS) and whose line contains MARKER;
    REVIEW/DONE/CANCELLED/DEFERRED are never touched
  - a non-ONGOING keyword is flipped to ONGOING (in place, rest of the
    headline preserved)
  - the item's :LOGBOOK: gains an OPEN clock at the current UTC instant;
    if the drawer exists the clock is added as its first entry
    (newest first, Org convention); if not, the drawer is created right
    after the headline, after any planning lines and :PROPERTIES: drawer
  - idempotent: an item that already carries an OPEN clock is left
    untouched

Exit codes: 0 clocked-or-already, 3 no matching item, 4 usage/IO error.
"""

import re
import sys
from datetime import datetime, timezone

WEEKDAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
OPEN_KEYWORDS = ("TODO", "ONGOING", "PENDING", "WAIT", "PROGRESS")
HEADLINE = re.compile(r"^(\*+)\s+([A-Z][A-Z-]*)((?:\s.*)?)$")
LOGBOOK = re.compile(r"^\s*:LOGBOOK:\s*$")
PROPERTIES = re.compile(r"^\s*:PROPERTIES:\s*$")
DRAWER_END = re.compile(r"^\s*:END:\s*$")
PLANNING = re.compile(r"^\s*(?:SCHEDULED|DEADLINE|CLOSED):")
OPEN_CLOCK = re.compile(r"^\s*CLOCK:\s*\[[^]]+\]\s*$")


def org_timestamp():
    """Current UTC instant as an Org inactive timestamp, English weekday."""
    now = datetime.now(timezone.utc)
    return (f"[{now:%Y-%m-%d} {WEEKDAYS[now.weekday()]} {now:%H:%M} UTC]")


def clock_in(lines, marker, stamp):
    """Pure transform. Returns (status, headline): clocked|already|None."""
    target = None
    for i, line in enumerate(lines):
        m = HEADLINE.match(line)
        if not m or m.group(2) not in OPEN_KEYWORDS:
            continue
        if marker in line:
            target = i
            break
    if target is None:
        return None, None

    m = HEADLINE.match(lines[target])
    stars, keyword, rest = m.group(1), m.group(2), m.group(3)
    level = len(stars)
    if keyword != "ONGOING":
        lines[target] = f"{stars} ONGOING{rest}"

    # find the section end, then the :LOGBOOK: drawer inside it
    end = target + 1
    while end < len(lines) and not HEADLINE.match(lines[end]):
        end += 1
    logbook = None
    open_clock = False
    for j in range(target + 1, end):
        if logbook is None and LOGBOOK.match(lines[j]):
            logbook = j
        elif logbook is not None and not open_clock and OPEN_CLOCK.match(lines[j]):
            open_clock = True
    if open_clock:
        return "already", lines[target]

    indent = " " * (level + 1)
    clock_line = f"{indent}CLOCK: {stamp}"
    if logbook is not None:
        lines.insert(logbook + 1, clock_line)
    else:
        at = target + 1
        while at < end and PLANNING.match(lines[at]):
            at += 1
        if at < end and PROPERTIES.match(lines[at]):
            at += 1
            while at < end and not DRAWER_END.match(lines[at]):
                at += 1
            at += 1
        lines[at:at] = [f"{indent}:LOGBOOK:", clock_line, f"{indent}:END:"]
    return "clocked", lines[target]


def main():
    if len(sys.argv) != 3:
        print("usage: clock_in.py BOARD MARKER", file=sys.stderr)
        sys.exit(4)
    board, marker = sys.argv[1], sys.argv[2]
    try:
        with open(board, encoding="utf-8") as fh:
            lines = fh.read().split("\n")
    except OSError as exc:
        print(f"clock-in: cannot read {board}: {exc}", file=sys.stderr)
        sys.exit(4)
    status, headline = clock_in(lines, marker, org_timestamp())
    if status is None:
        print(f"clock-in: no open item matches {marker!r}")
        sys.exit(3)
    if status == "already":
        print(f"clock-in: already clocked — {headline}")
        return
    try:
        with open(board, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines))
    except OSError as exc:
        print(f"clock-in: cannot write {board}: {exc}", file=sys.stderr)
        sys.exit(4)
    print(f"clock-in: {status} at {org_timestamp()} — {headline}")


if __name__ == "__main__":
    main()
