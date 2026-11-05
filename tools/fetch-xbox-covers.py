#!/usr/bin/env python3
"""Fetch original Xbox cover art for a directory of .iso discs.

Source: libretro-thumbnails/Microsoft_-_Xbox (Named_Boxarts), Redump naming.
Writes <disc-basename>.<ext> beside each .iso. Never overwrites an existing cover.

usage: fetch-xbox-covers.py /path/to/discs
"""

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

REPO = "libretro-thumbnails/Microsoft_-_Xbox"
TREE = f"https://api.github.com/repos/{REPO}/git/trees/master?recursive=1"
RAW = f"https://raw.githubusercontent.com/{REPO}/master/Named_Boxarts/"
CACHE = os.path.expanduser("~/.cache/xbox-boxart-index.json")
COVER_EXTS = (".png", ".jpg", ".jpeg")
REGION_RANK = {"usa": 0, "world": 1, "europe": 2}


def norm(title):
    """Fold a title to a comparable key: no parentheticals, no punctuation."""
    t = re.sub(r"\([^)]*\)", " ", title)
    t = re.sub(r"\[[^]]*\]", " ", t)
    t = t.lower().replace("&", " and ")
    return re.sub(r"[^a-z0-9]+", "", t)


def load_index():
    """One network request, cached. Returns {stem: filename} and {key: [filenames]}."""
    if os.path.exists(CACHE):
        names = json.load(open(CACHE))
    else:
        req = urllib.request.Request(TREE, headers={"User-Agent": "xbox-covers/1"})
        tree = json.load(urllib.request.urlopen(req, timeout=60))["tree"]
        names = [
            e["path"][len("Named_Boxarts/"):]
            for e in tree
            if e["type"] == "blob" and e["path"].startswith("Named_Boxarts/")
            and e["path"].lower().endswith(COVER_EXTS)
        ]
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)
        json.dump(names, open(CACHE, "w"))

    exact, fuzzy = {}, {}
    for n in names:
        stem, _ = os.path.splitext(n)
        exact[stem.lower()] = n
        fuzzy.setdefault(norm(stem), []).append(n)
    return exact, fuzzy


def rank(filename):
    """Prefer USA, then World, then Europe, then anything; shortest name wins ties."""
    regions = re.findall(r"\(([^)]*)\)", filename)
    first = regions[0].split(",")[0].strip().lower() if regions else ""
    return (REGION_RANK.get(first, 9), len(filename), filename)


def pick(stem, exact, fuzzy):
    hit = exact.get(stem.lower())
    if hit:
        return hit
    cands = fuzzy.get(norm(stem))
    return sorted(cands, key=rank)[0] if cands else None


def title_of(stem):
    """Drop a .xiso pseudo extension.

    Extracting a disc with xiso leaves "Cel Damage (USA).xiso.iso", so the
    stem still carries a .xiso that is not part of the title and defeats
    both the exact and the folded match.
    """
    return re.sub(r"\.xiso$", "", stem, flags=re.IGNORECASE)


def has_cover(directory, stem):
    lower = {f.lower() for f in os.listdir(directory)}
    return any(f"{stem.lower()}{e}" in lower for e in COVER_EXTS)


def main():
    if len(sys.argv) != 2 or not os.path.isdir(sys.argv[1]):
        sys.exit("usage: fetch-xbox-covers.py /path/to/discs")
    directory = sys.argv[1]

    discs = sorted(f for f in os.listdir(directory)
                   if f.lower().endswith((".iso", ".xiso")))
    if not discs:
        print("no .iso files found")
        return

    exact, fuzzy = load_index()

    for disc in discs:
        stem = os.path.splitext(disc)[0]
        if has_cover(directory, stem):
            print(f"skip   {stem}  (cover already present)")
            continue
        match = pick(title_of(stem), exact, fuzzy)
        if not match:
            print(f"miss   {stem}  (no cover found)")
            continue
        ext = os.path.splitext(match)[1].lower()
        dest = os.path.join(directory, stem + ext)
        url = RAW + urllib.parse.quote(match)
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "xbox-covers/1"})
            data = urllib.request.urlopen(req, timeout=60).read()
        except (urllib.error.URLError, urllib.error.HTTPError) as err:
            print(f"fail   {stem}  ({err})")
            continue
        tmp = dest + ".part"
        with open(tmp, "wb") as fh:
            fh.write(data)
        os.replace(tmp, dest)
        print(f"got    {stem}  <- {match}  ({len(data)} bytes)")


if __name__ == "__main__":
    main()
