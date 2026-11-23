"""Select a compatible simulator for each requested screen class."""
import json
import re
import sys

devices = json.load(open(sys.argv[1], encoding="utf-8"))["devices"]
options = []
for runtime, candidates in devices.items():
    match = re.search(r"\.iOS-(\d+)-(\d+)", runtime)
    if not match or tuple(map(int, match.groups())) < (27, 1):
        continue
    for device in candidates:
        if device.get("isAvailable"):
            options.append((tuple(map(int, match.groups())), device["name"], device["udid"]))
options.sort(reverse=True)
for category, predicate in [
    ("DUO", lambda name: "iPhone Duo" in name),
    ("PHONE", lambda name: "iPhone" in name and "Duo" not in name),
    ("IPAD", lambda name: "iPad" in name),
]:
    choice = next((item for item in options if predicate(item[1])), None)
    if not choice:
        raise SystemExit(f"Missing iOS 27.1+ {category} simulator")
    print(f"{category}_UDID={choice[2]}")

