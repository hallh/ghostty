#!/usr/bin/env python3
import xml.etree.ElementTree as ET
from tabulate import tabulate
import sys

filename = sys.argv[1] if len(sys.argv) > 1 else "cobertura.xml"

tree = ET.parse(filename)
root = tree.getroot()

rows = []
for cls in root.findall(".//class"):
    filename = cls.attrib["filename"]
    coverage = 100.0 * float(cls.attrib.get("line-rate", 0))

    # Find all lines and collect uncovered ones, grouping consecutive lines as start-end
    uncovered = []
    for line in cls.findall(".//line"):
        number = int(line.attrib["number"])
        hits = int(line.attrib["hits"])
        if hits == 0:
            uncovered.append(number)
    # Group consecutive uncovered lines
    groups = []
    if coverage == 0.0:
        uncovered_str = "*"
    else:
        if uncovered:
            uncovered.sort()
            start = prev = uncovered[0]
            for n in uncovered[1:]:
                if n == prev + 1:
                    prev = n
                else:
                    if start == prev:
                        groups.append(str(start))
                    else:
                        groups.append(f"{start}-{prev}")
                    start = prev = n
            # Add the last group
            if start == prev:
                groups.append(str(start))
            else:
                groups.append(f"{start}-{prev}")
        uncovered_str = ",".join(groups) if groups else ""

    rows.append([
        "src/" + filename,
        f"{coverage:.1f}%",
        uncovered_str
    ])

print(tabulate(rows, headers=["File", "Coverage", "Uncovered Lines"], tablefmt="plain"))

