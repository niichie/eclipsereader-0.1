"""Pick one simulator per screen class for the screenshot tour.

Prints `KEY|udid|name` lines for: phone-small, phone-large, ipad, ipad-mini, duo
(only the classes this runner has). Newest iOS runtime wins.
"""
import json
import re
import sys

devices = json.load(open(sys.argv[1], encoding="utf-8"))["devices"]
options = []
for runtime, candidates in devices.items():
    match = re.search(r"\.iOS-(\d+)-(\d+)", runtime)
    if not match:
        continue
    version = tuple(map(int, match.groups()))
    for device in candidates:
        if device.get("isAvailable"):
            options.append((version, device["name"], device["udid"]))
options.sort(key=lambda item: item[0], reverse=True)
newest = options[0][0] if options else None
options = [o for o in options if o[0] == newest]

def first(*tests):
    for test in tests:
        for _, name, udid in options:
            if test(name):
                return udid, name
    return None

picks = {
    "phone-small": first(lambda n: "iPhone SE" in n, lambda n: re.search(r"iPhone \d+e\b", n),
                         lambda n: "mini" in n, lambda n: re.fullmatch(r"iPhone \d+", n)),
    "phone-large": first(lambda n: "Pro Max" in n, lambda n: "Plus" in n, lambda n: "Air" in n and "iPhone" in n),
    "ipad": first(lambda n: "iPad Pro 13" in n, lambda n: "iPad Pro" in n, lambda n: "iPad Air 13" in n, lambda n: "iPad Air" in n),
    "ipad-mini": first(lambda n: "iPad mini" in n),
    "duo": first(lambda n: "Duo" in n or "Fold" in n),
}
seen = set()
for key, choice in picks.items():
    if choice and choice[0] not in seen:
        seen.add(choice[0])
        print(f"{key}|{choice[0]}|{choice[1]}")
print(f"runtime iOS {newest}", file=sys.stderr)
