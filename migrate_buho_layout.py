#!/usr/bin/env python3
"""Read BuhoLaunchpad's Core Data SQLite store and export layout, without changing it."""
import json
import sqlite3
from pathlib import Path

source = Path.home() / "Library/Application Support/BuhoLaunchpad/Data.sqlite"
target = Path.home() / "Library/Application Support/OpenLaunchpad/layout.json"
if not source.exists():
    raise SystemExit(f"BuhoLaunchpad layout database not found: {source}")
if target.exists():
    raise SystemExit(f"OpenLaunchpad layout already exists; preserving edits: {target}")

db = sqlite3.connect(f"file:{source}?mode=ro", uri=True)
db.row_factory = sqlite3.Row
top_pages = db.execute(
    "SELECT Z_PK FROM ZLAUNCHPADPAGE WHERE ZDATA IS NOT NULL ORDER BY Z_FOK_DATA"
).fetchall()

def page_items(page_id):
    result = []
    for item in db.execute(
        "SELECT Z_PK,Z_ENT,ZBUNDLEID,ZNAME FROM ZLAUNCHPADITEM "
        "WHERE ZPAGE=? ORDER BY Z_FOK_PAGE", (page_id,)
    ):
        if item["Z_ENT"] == 7:
            child_pages = db.execute(
                "SELECT Z_PK FROM ZLAUNCHPADPAGE WHERE ZGROUP=? ORDER BY Z_PK",
                (item["Z_PK"],),
            ).fetchall()
            children = [child for p in child_pages for child in page_items(p["Z_PK"])]
            result.append({"kind": "group", "id": f"group-{item['Z_PK']}",
                           "name": item["ZNAME"] or "文件夹", "children": children})
        elif item["ZBUNDLEID"]:
            result.append({"kind": "app", "id": item["ZBUNDLEID"], "name": "", "children": []})
    return result

hidden = [row[0] for row in db.execute("SELECT ZBUNDLEID FROM ZHIDDENAPP WHERE ZBUNDLEID IS NOT NULL")]
known = [row[0] for row in db.execute("SELECT ZBUNDLEID FROM ZLAUNCHPADITEM WHERE ZBUNDLEID IS NOT NULL")]
layout = {"version": 1, "pages": [page_items(page["Z_PK"]) for page in top_pages],
          "hiddenIDs": hidden, "knownIDs": known}
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(json.dumps(layout, ensure_ascii=False, indent=2), encoding="utf-8")
print(f"Imported {len(layout['pages'])} pages and "
      f"{sum(len(p) for p in layout['pages'])} top-level items into {target}")
