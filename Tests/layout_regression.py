from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / "Sources/main.swift").read_text()
model = source[source.index("struct LaunchNode:"):source.index("final class LaunchpadWindow:")]
checks = r'''
func node(_ id: String) -> LaunchNode {
    LaunchNode(kind: "app", id: id, name: id, children: [])
}
var layout = LaunchLayout(version: 1, pages: [
    [node("a"), node("b"), node("c"), node("d")],
    [node("e"), node("f"), node("g")]
], hiddenIDs: [], knownIDs: [])
normalizeLayout(&layout, capacity: 3)
assert(layout.pages.map { $0.map(\.id) } == [["a", "b", "c"], ["d", "e", "f"], ["g"]])
let stable = layout
normalizeLayout(&layout, capacity: 3)
assert(layout == stable)
layout.pages = [
    [node("a"), node("a"),
     LaunchNode(kind: "group", id: "folder", name: "Folder", children: [node("a"), node("b"), node("b")]),
     LaunchNode(kind: "group", id: "empty", name: "Empty", children: [])], []
]
normalizeLayout(&layout, capacity: 3)
assert(layout.pages.map { $0.map(\.id) } == [["a", "b"]])
layout.pages = []
normalizeLayout(&layout, capacity: 3)
assert(layout.pages.count == 1 && layout.pages[0].isEmpty)
print("PASS: overflow, ordering, deduplication, folder cleanup, empty layout, idempotence")
'''
with tempfile.TemporaryDirectory() as directory:
    test = Path(directory) / "main.swift"
    test.write_text("import Foundation\n" + model + checks)
    subprocess.run(["swift", str(test)], check=True)
