#!/usr/bin/env python3
"""Extract Whitaker's Words DICTLINE.GEN + INFLECTS.LAT into SQLite.

Source: William Whitaker's WORDS (freely redistributable), via
https://github.com/mk270/whitakers-words

Dictionary-form (lemma) construction ports Support_Utils.Dictionary_Form
from the Ada sources in whitakers-words-src/.
"""
from __future__ import annotations

import json
import os
import sqlite3
import sys
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC = HERE / "whitakers-words-src"
DICTLINE = SRC / "DICTLINE.GEN"
INFLECTS = SRC / "INFLECTS.LAT"
UNIQUES = SRC / "UNIQUES.LAT"
DB_PATH = HERE / "whittakers.db"

CASES = {"NOM", "VOC", "GEN", "LOC", "DAT", "ABL", "ACC"}
NUMBERS = {"S", "P", "X"}
GENDERS = {"M", "F", "N", "C", "X"}
TENSES = {"PRES", "IMPF", "FUT", "PERF", "PLUP", "FUTP"}
VOICES = {"ACTIVE", "PASSIVE"}
MOODS = {"IND", "SUB", "IMP", "INF", "PPL", "SUPINE"}
COMPARISONS = {"POS", "COMP", "SUPER", "X"}
ZZZ = "zzz"


def trim(s: str) -> str:
    return s.strip()


def add_stem(stem: str, infl: str) -> str:
    st = trim(stem)
    if not st or st.lower().startswith(ZZZ):
        return ""
    return st + infl


def parse_dictline_row(line: str) -> dict | None:
    if not line or line.startswith("--"):
        return None
    # Pad so slices are stable (DICTLINE is fixed-width, 110+ chars).
    if len(line) < 110:
        line = line.ljust(110)
    stems = [trim(line[0:19]), trim(line[19:38]), trim(line[38:57]), trim(line[57:76])]
    pos = trim(line[76:83]).upper()
    morph = trim(line[83:97])
    # 97:100 unused "number" slot in some dumps
    codes = trim(line[100:110])
    meaning = trim(line[110:])
    if meaning.startswith("|"):
        meaning = meaning[1:].strip()
    if not pos:
        return None
    morph_toks = morph.split()
    codes_toks = codes.split()
    age = codes_toks[0] if len(codes_toks) > 0 else ""
    area = codes_toks[1] if len(codes_toks) > 1 else ""
    geo = codes_toks[2] if len(codes_toks) > 2 else ""
    freq = codes_toks[3] if len(codes_toks) > 3 else ""
    source = codes_toks[4] if len(codes_toks) > 4 else ""
    rec = {
        "stems": stems,
        "pos": pos,
        "morph": morph,
        "morph_toks": morph_toks,
        "meaning": meaning,
        "age": age,
        "area": area,
        "geo": geo,
        "freq": freq,
        "source": source,
        "which": 0,
        "var": 0,
        "gender": "X",
        "kind": "X",
        "comparison": "X",
        "prep_case": "",
    }
    if pos == "N" and len(morph_toks) >= 2:
        rec["which"] = int(morph_toks[0])
        rec["var"] = int(morph_toks[1])
        rec["gender"] = morph_toks[2] if len(morph_toks) > 2 else "X"
        rec["kind"] = morph_toks[3] if len(morph_toks) > 3 else "X"
    elif pos == "ADJ" and len(morph_toks) >= 2:
        rec["which"] = int(morph_toks[0])
        rec["var"] = int(morph_toks[1])
        rec["comparison"] = morph_toks[2] if len(morph_toks) > 2 else "POS"
    elif pos == "V" and len(morph_toks) >= 2:
        rec["which"] = int(morph_toks[0])
        rec["var"] = int(morph_toks[1])
        rec["kind"] = morph_toks[2] if len(morph_toks) > 2 else "X"
    elif pos == "ADV":
        rec["comparison"] = morph_toks[0] if morph_toks else "X"
    elif pos == "PREP":
        rec["prep_case"] = morph_toks[0] if morph_toks else ""
    elif pos in {"PRON", "PACK", "NUM"} and len(morph_toks) >= 2:
        rec["which"] = int(morph_toks[0]) if morph_toks[0].isdigit() else 0
        rec["var"] = int(morph_toks[1]) if morph_toks[1].isdigit() else 0
        if pos == "NUM" and len(morph_toks) > 2:
            rec["kind"] = morph_toks[2]
    return rec


def dictionary_form_parts(rec: dict) -> list[str]:
    """Port of Support_Utils.Dictionary_Form principal parts (Ox 1..4)."""
    stems = rec["stems"]
    pos = rec["pos"]
    which, var = rec["which"], rec["var"]
    gender = rec["gender"]
    kind = rec["kind"]
    co = rec["comparison"]
    ox = ["", "", "", ""]

    def s(i: int) -> str:
        return stems[i] if i < len(stems) else ""

    if pos == "PREP":
        return [s(0)]

    others_empty = not any(s(i) for i in (1, 2, 3))
    uniqueish = (
        (pos == "N" and which == 9)
        or (pos == "ADJ" and (which == 9 or co in {"COMP", "SUPER"}))
        or (pos == "V" and (which, var) in {(9, 8), (9, 9)})
    )
    if others_empty and not uniqueish:
        return [s(0)]

    if pos == "N":
        if which == 1:
            endings = {1: ("a", "ae"), 6: ("e", "es"), 7: ("es", "ae"), 8: ("as", "ae")}
            if var in endings:
                ox[0] = add_stem(s(0), endings[var][0])
                ox[1] = add_stem(s(1), endings[var][1])
        elif which == 2:
            if var == 1:
                ox[0], ox[1] = add_stem(s(0), "us"), add_stem(s(1), "i")
            elif var == 2:
                ox[0], ox[1] = add_stem(s(0), "um"), add_stem(s(1), "i")
            elif var == 3:
                ox[0], ox[1] = add_stem(s(0), ""), add_stem(s(1), "i")
            elif var == 4:
                ox[0] = add_stem(s(0), "um" if gender == "N" else "us")
                ox[1] = add_stem(s(1), "(i)")
            elif var == 5:
                ox[0], ox[1] = add_stem(s(0), "us"), add_stem(s(1), "")
            elif var == 6:
                ox[0], ox[1] = add_stem(s(0), "os"), add_stem(s(1), "i")
            elif var == 7:
                ox[0], ox[1] = add_stem(s(0), ""), add_stem(s(1), "yos/i")
            elif var == 8:
                ox[0], ox[1] = add_stem(s(0), "on"), add_stem(s(1), "i")
            elif var == 9:
                ox[0], ox[1] = add_stem(s(0), "us"), add_stem(s(1), "i")
        elif which == 3:
            ox[0] = add_stem(s(0), "")
            ox[1] = add_stem(s(1), "os/is" if var in (7, 9) else "is")
        elif which == 4:
            if var == 1:
                ox[0], ox[1] = add_stem(s(0), "us"), add_stem(s(1), "us")
            elif var == 2:
                ox[0], ox[1] = add_stem(s(0), "u"), add_stem(s(1), "us")
            elif var == 3:
                ox[0], ox[1] = add_stem(s(0), "us"), add_stem(s(1), "u")
            elif var == 4:
                ox[0], ox[1] = add_stem(s(0), ""), add_stem(s(1), "u")
        elif which == 5:
            ox[0], ox[1] = add_stem(s(0), "es"), add_stem(s(1), "ei")
        elif which == 9:
            if var == 8:
                ox[0], ox[1] = add_stem(s(0), "."), "abb."
            elif var == 9:
                ox[0], ox[1] = add_stem(s(0), ""), "undeclined"
    elif pos == "PRON":
        if which == 3:
            ox[0] = add_stem(s(0), "ic")
            ox[1] = add_stem(s(0), "aec")
            ox[2] = add_stem(s(0), "oc" if var == 1 else "uc")
        elif which == 4:
            if var == 1:
                ox[0], ox[1], ox[2] = add_stem(s(0), "s"), add_stem(s(1), "a"), add_stem(s(0), "d")
            elif var == 2:
                ox[0] = add_stem(s(0), "dem")
                ox[1] = add_stem(s(1), "adem")
                ox[2] = add_stem(s(0), "dem")
        elif which == 6:
            ox[0], ox[1] = add_stem(s(0), "e"), add_stem(s(0), "a")
            ox[2] = add_stem(s(0), "ud" if var == 1 else "um")
        elif which == 9:
            if var == 8:
                ox[0], ox[1] = add_stem(s(0), "."), "abb."
            elif var == 9:
                ox[0], ox[1] = add_stem(s(0), ""), "undeclined"
    elif pos == "ADJ":
        if co == "COMP":
            ox[0] = add_stem(s(0), "or")
            ox[1] = add_stem(s(0), "or")
            ox[2] = add_stem(s(0), "us")
        elif co == "SUPER":
            ox[0] = add_stem(s(0), "mus")
            ox[1] = add_stem(s(0), "ma")
            ox[2] = add_stem(s(0), "mum")
        elif co == "POS":
            if which == 1:
                if var == 1:
                    ox[0], ox[1], ox[2] = add_stem(s(0), "us"), add_stem(s(1), "a"), add_stem(s(1), "um")
                elif var == 2:
                    ox[0], ox[1], ox[2] = add_stem(s(0), ""), add_stem(s(1), "a"), add_stem(s(1), "um")
                elif var == 3:
                    ox[0], ox[1], ox[2] = add_stem(s(0), "us"), add_stem(s(1), "a"), add_stem(s(1), "um (gen -ius)")
                elif var == 4:
                    ox[0], ox[1], ox[2] = add_stem(s(0), ""), add_stem(s(1), "a"), add_stem(s(1), "um")
                elif var == 5:
                    ox[0], ox[1], ox[2] = add_stem(s(0), "us"), add_stem(s(1), "a"), add_stem(s(1), "ud")
            elif which == 3:
                if var == 1:
                    ox[0], ox[1], ox[2] = add_stem(s(0), ""), "(gen.)", add_stem(s(1), "is")
                elif var == 2:
                    ox[0], ox[1], ox[2] = add_stem(s(0), "is"), add_stem(s(1), "is"), add_stem(s(1), "e")
                elif var == 3:
                    ox[0], ox[1], ox[2] = add_stem(s(0), ""), add_stem(s(1), "is"), add_stem(s(1), "e")
            elif which == 9:
                ox[0], ox[1] = add_stem(s(0), "" if var == 9 else "."), ("undeclined" if var == 9 else "abb.")
        elif co == "X":
            if which == 1:
                ending0 = "us" if var == 1 else ""
                ox[0] = add_stem(s(0), ending0)
                ox[1] = add_stem(s(1), "a -um")
                ox[2] = add_stem(s(2), "or -or -us")
                ox[3] = add_stem(s(3), "mus -a -um")
            elif which == 3:
                if var == 1:
                    ox[0], ox[1] = add_stem(s(0), ""), add_stem(s(1), "is (gen.)")
                elif var == 2:
                    ox[0], ox[1] = add_stem(s(0), "is"), add_stem(s(1), "e")
                elif var == 3:
                    ox[0], ox[1] = add_stem(s(0), ""), add_stem(s(1), "is -e")
                ox[2] = add_stem(s(2), "or -or -us")
                ox[3] = add_stem(s(3), "mus -a -um")
    elif pos == "ADV" and co == "X":
        ox[0], ox[1], ox[2] = add_stem(s(0), ""), add_stem(s(1), ""), add_stem(s(2), "")
    elif pos == "V":
        if kind == "DEP":
            ox[2] = "DEP"
            ox[3] = add_stem(s(3), "us sum")
            if which == 1:
                ox[0], ox[1] = add_stem(s(0), "or"), add_stem(s(1), "ari")
            elif which == 2:
                ox[0], ox[1] = add_stem(s(0), "eor"), add_stem(s(1), "eri")
            elif which == 3:
                ox[0] = add_stem(s(0), "or")
                ox[1] = add_stem(s(1), "iri" if var == 4 else "i")
        elif kind == "PERFDEF":
            ox[0] = add_stem(s(2), "i")
            ox[1] = add_stem(s(2), "isse")
            ox[2] = add_stem(s(3), "us")
        else:
            if kind == "IMPERS":
                if which == 1:
                    ox[0] = add_stem(s(0), "at")
                elif which == 2:
                    ox[0] = add_stem(s(0), "et")
                elif which == 3:
                    st = s(0)
                    if var == 2 or (st and st[-1] == "i"):
                        ox[0] = add_stem(st, "t")
                    else:
                        ox[0] = add_stem(st, "it")
                elif which == 5 and var == 1:
                    ox[0] = add_stem(s(0), "est")
                elif which == 7 and var in (1, 2):
                    ox[0] = add_stem(s(0), "t")
            else:
                if which == 2:
                    ox[0] = add_stem(s(0), "eo")
                elif which == 5:
                    ox[0] = add_stem(s(0), "um")
                elif which == 7 and var == 2:
                    ox[0] = add_stem(s(0), "am")
                else:
                    ox[0] = add_stem(s(0), "o")
            if which == 1:
                ox[1] = add_stem(s(1), "are")
            elif which == 2:
                ox[1] = add_stem(s(1), "ere")
            elif which == 3:
                if var == 2:
                    ox[1] = add_stem(s(1), "re")
                elif var == 3:
                    ox[1] = add_stem(s(1), "ieri" if s(1) == "f" else "eri")
                elif var == 4:
                    ox[1] = add_stem(s(1), "ire")
                else:
                    ox[1] = add_stem(s(1), "ere")
            elif which == 5:
                ox[1] = add_stem(s(1), "esse") if var == 1 else add_stem(s(0), "e")
            elif which == 9:
                if var == 8:
                    ox[0], ox[1] = add_stem(s(0), "."), "abb."
                elif var == 9:
                    ox[0], ox[1] = add_stem(s(0), ""), "undeclined"
            if kind == "IMPERS":
                ox[2] = add_stem(s(2), "it")
                ox[3] = add_stem(s(3), "us est")
            elif kind == "SEMIDEP":
                ox[3] = add_stem(s(3), "us sum")
                ox[2] = add_stem(s(2), "i")
            elif which == 5 and var == 1:
                ox[2] = add_stem(s(2), "i")
                ox[3] = add_stem(s(3), "urus")
            elif which == 8:
                ox[2], ox[3] = "additional", "forms"
            elif which == 9:
                pass
            else:
                ox[2] = add_stem(s(2), "i")
                ox[3] = add_stem(s(3), "us")
    else:
        ox[0] = add_stem(s(0), "")

    return [p for p in ox if p and not p.lower().startswith(ZZZ)]


def lemma_of(rec: dict) -> str:
    parts = dictionary_form_parts(rec)
    if parts:
        # First token of first principal part, lowercased, no trailing punct.
        head = parts[0].split()[0].rstrip(".,;:")
        return head.lower()
    st = rec["stems"][0].lower()
    return st


def parse_inflects(path: Path) -> list[dict]:
    rules: list[dict] = []
    text = path.read_text(encoding="latin-1")
    for raw in text.splitlines():
        line = raw.split("--", 1)[0].strip()
        if not line:
            continue
        toks = line.split()
        pos = toks[0].upper()
        try:
            if pos == "N" and len(toks) >= 8:
                # N which var CASE NUM GENDER stem len [ending] age freq
                which, var = int(toks[1]), int(toks[2])
                case, num, gender = toks[3], toks[4], toks[5]
                stem_key, elen = int(toks[6]), int(toks[7])
                rest = toks[8:]
                ending = rest[0] if elen > 0 else ""
                if ending and ending in {"X", "A", "B", "C", "D", "E", "F", "I"} and elen == 0:
                    ending = ""
                # if elen>0, ending is next token; age/freq follow
                if elen == 0:
                    age = rest[0] if rest else "X"
                else:
                    age = rest[1] if len(rest) > 1 else "X"
                rules.append({
                    "pos": "N", "which": which, "var": var,
                    "tag": f"{case} {num} {gender}",
                    "stem": stem_key, "ending": ending if elen > 0 else "",
                    "kind": "",
                })
            elif pos == "ADJ" and len(toks) >= 9:
                which, var = int(toks[1]), int(toks[2])
                case, num, gender, co = toks[3], toks[4], toks[5], toks[6]
                stem_key, elen = int(toks[7]), int(toks[8])
                ending = toks[9] if elen > 0 and len(toks) > 9 else ""
                rules.append({
                    "pos": "ADJ", "which": which, "var": var,
                    "tag": f"{case} {num} {gender} {co}",
                    "stem": stem_key, "ending": ending if elen > 0 else "",
                    "kind": co,
                })
            elif pos == "V" and len(toks) >= 10:
                which, var = int(toks[1]), int(toks[2])
                tense, voice, mood = toks[3], toks[4], toks[5]
                person, num = toks[6], toks[7]
                stem_key, elen = int(toks[8]), int(toks[9])
                ending = toks[10] if elen > 0 and len(toks) > 10 else ""
                rules.append({
                    "pos": "V", "which": which, "var": var,
                    "tag": f"{tense} {voice} {mood} {person} {num}",
                    "stem": stem_key, "ending": ending if elen > 0 else "",
                    "kind": "",
                })
            elif pos == "PRON" and len(toks) >= 8:
                which, var = int(toks[1]), int(toks[2])
                case, num, gender = toks[3], toks[4], toks[5]
                stem_key, elen = int(toks[6]), int(toks[7])
                ending = toks[8] if elen > 0 and len(toks) > 8 else ""
                rules.append({
                    "pos": "PRON", "which": which, "var": var,
                    "tag": f"{case} {num} {gender}",
                    "stem": stem_key, "ending": ending if elen > 0 else "",
                    "kind": "",
                })
            elif pos == "ADV" and len(toks) >= 4:
                # ADV POS 1 0   or ADV X 1 0
                co = toks[1]
                stem_key = int(toks[2])
                elen = int(toks[3])
                ending = toks[4] if elen > 0 and len(toks) > 4 else ""
                rules.append({
                    "pos": "ADV", "which": 0, "var": 0,
                    "tag": co, "stem": stem_key,
                    "ending": ending if elen > 0 else "",
                    "kind": co,
                })
        except (ValueError, IndexError):
            continue
    return rules


def index_rules(rules: list[dict]) -> dict:
    idx = defaultdict(list)
    for r in rules:
        idx[(r["pos"], r["which"], r["var"])].append(r)
        if r["var"] != 0:
            idx[(r["pos"], r["which"], 0)].append(r)
        if r["which"] != 0:
            idx[(r["pos"], 0, r["var"])].append(r)
            idx[(r["pos"], 0, 0)].append(r)
    return idx


def gender_ok(rule_g: str, noun_g: str) -> bool:
    if rule_g in {"X", "C"} or noun_g in {"X", "C"}:
        return True
    return rule_g == noun_g


def inflect_entry(rec: dict, rule_idx: dict) -> list[tuple[str, str]]:
    pos = rec["pos"]
    which, var = rec["which"], rec["var"]
    stems = rec["stems"]
    seen = set()
    out: list[tuple[str, str]] = []
    candidates = []
    for key in ((pos, which, var), (pos, which, 0), (pos, 0, var), (pos, 0, 0)):
        candidates.extend(rule_idx.get(key, []))
    # de-dupe rule objects
    uniq = []
    ids = set()
    for r in candidates:
        i = id(r)
        if i not in ids:
            ids.add(i)
            uniq.append(r)
    kind = rec["kind"]
    for r in uniq:
        if r["var"] not in (0, var):
            continue
        if r["which"] not in (0, which):
            continue
        if pos == "N" and not gender_ok(r["tag"].split()[-1] if r["tag"] else "X", rec["gender"]):
            continue
        if pos == "ADJ" and rec["comparison"] not in {"X", ""}:
            # rule kind is comparison
            if r["kind"] not in {"X", rec["comparison"]}:
                continue
        if pos == "V" and kind == "DEP":
            # deponents inflect with passive forms
            if "ACTIVE" in r["tag"] and "PPL" not in r["tag"]:
                continue
        sk = r["stem"]
        if sk < 1 or sk > 4:
            continue
        stem = stems[sk - 1]
        if not stem or stem.lower().startswith(ZZZ):
            continue
        form = stem + r["ending"]
        tag = r["tag"]
        key = (form, tag)
        if key in seen:
            continue
        seen.add(key)
        out.append((form, tag))
    return out


def load_uniques(path: Path) -> list[dict]:
    if not path.exists():
        return []
    lines = path.read_text(encoding="latin-1").splitlines()
    out = []
    i = 0
    while i + 2 < len(lines):
        form = trim(lines[i])
        morph = trim(lines[i + 1])
        meaning = trim(lines[i + 2])
        i += 3
        if not form or form.startswith("--"):
            continue
        pos = morph.split()[0] if morph else "X"
        out.append({
            "lemma": form.lower(),
            "pos": pos,
            "meaning": meaning,
            "stems": [form, "", "", ""],
            "forms": [(form, morph)],
            "principal": [form],
        })
    return out


SKIP_PRINCIPAL = {
    "additional", "forms", "abb.", "undeclined", "dep", "blank",
    "perfdef", "-", "zzz",
}


def rec_score(rec: dict) -> int:
    """Prefer the real paradigm (complete stems, not Whitaker's extra/undeclined)."""
    n = sum(1 for s in rec["stems"] if s and not s.lower().startswith(ZZZ))
    penalty = 20 if rec.get("which") in (8, 9) else 0
    return n * 10 - penalty


def finalize_lemma(recs: list[dict], extra_forms: list[tuple[str, str]],
                   rule_idx: dict) -> dict:
    meanings: list[str] = []
    pos_set: set[str] = set()
    principal: list[str] = []
    for rec in recs:
        pos_set.add(rec["pos"])
        m = rec.get("meaning") or ""
        if m and m not in meanings:
            meanings.append(m)
        for p in dictionary_form_parts(rec):
            if not p or p.lower() in SKIP_PRINCIPAL:
                continue
            if p not in principal:
                principal.append(p)
    primary = max(recs, key=rec_score) if recs else None
    inflections: list[tuple[str, str]] = []
    tags: set[str] = set()
    if primary is not None:
        for f, t in inflect_entry(primary, rule_idx):
            inflections.append((f, t))
            tags.add(t)
        for rec in recs:
            if rec is primary or rec.get("which") in (8, 9):
                continue
            for f, t in inflect_entry(rec, rule_idx):
                if t in tags:
                    continue
                inflections.append((f, t))
                tags.add(t)
    for f, t in extra_forms:
        if t in tags:
            continue
        inflections.append((f, t))
        tags.add(t)
    stems = list(primary["stems"]) if primary else ["", "", "", ""]
    return {
        "meanings": meanings,
        "principal": principal,
        "inflections": inflections,
        "stems": stems,
        "pos_set": pos_set,
        "primary": primary,
    }


def main() -> int:
    if not DICTLINE.exists():
        print(f"error: missing {DICTLINE}", file=sys.stderr)
        return 1
    print("parsing INFLECTS.LAT …", flush=True)
    rules = parse_inflects(INFLECTS)
    rule_idx = index_rules(rules)
    print(f"  {len(rules)} inflection rules", flush=True)

    print("parsing DICTLINE.GEN …", flush=True)
    raw: dict[str, list[dict]] = defaultdict(list)
    n_raw = 0
    with DICTLINE.open("r", encoding="latin-1") as fh:
        for line in fh:
            rec = parse_dictline_row(line.rstrip("\n"))
            if rec is None:
                continue
            n_raw += 1
            lemma = lemma_of(rec)
            if not lemma:
                continue
            raw[lemma].append(rec)
    print(f"  {n_raw} DICTLINE rows -> {len(raw)} lemmas", flush=True)

    print("parsing UNIQUES.LAT …", flush=True)
    unique_forms: dict[str, list[tuple[str, str]]] = defaultdict(list)
    unique_recs: dict[str, list[dict]] = defaultdict(list)
    for u in load_uniques(UNIQUES):
        unique_forms[u["lemma"]].extend(u["forms"])
        unique_recs[u["lemma"]].append({
            "stems": u["stems"],
            "pos": u["pos"],
            "meaning": u["meaning"],
            "which": 9,
            "var": 9,
            "gender": "X",
            "kind": "X",
            "comparison": "X",
            "prep_case": "",
        })

    bucket: dict[str, dict] = {}
    lemmas = set(raw) | set(unique_recs)
    for lemma in lemmas:
        recs = raw.get(lemma, []) + unique_recs.get(lemma, [])
        bucket[lemma] = finalize_lemma(recs, unique_forms.get(lemma, []), rule_idx)
    print(f"  {len(bucket)} lemmas after uniques", flush=True)

    if os.path.exists(DB_PATH):
        os.remove(DB_PATH)
    conn = sqlite3.connect(DB_PATH)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=OFF")
    conn.execute(
        """
        CREATE TABLE entries (
            lemma TEXT PRIMARY KEY,
            definition TEXT,
            forms TEXT,
            pos TEXT
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE form_index (
            form TEXT NOT NULL,
            lemma TEXT NOT NULL,
            tag TEXT,
            PRIMARY KEY (form, lemma, tag)
        )
        """
    )
    conn.execute("CREATE INDEX idx_form_index_form ON form_index(form)")

    rows = []
    form_rows = []
    for lemma, e in bucket.items():
        forms_obj = {
            "principal_parts": e["principal"],
            "stems": e["stems"],
            "table": [{"form": f, "tag": t} for f, t in e["inflections"]],
        }
        # Keep a compact noun/verb snapshot for the Emacs popup.
        snapshot = {}
        for f, t in e["inflections"]:
            snapshot.setdefault(t, f)
        forms_obj["by_tag"] = snapshot
        pos = "/".join(sorted(e["pos_set"]))
        definition = " | ".join(e["meanings"])
        rows.append((lemma, definition, json.dumps(forms_obj, ensure_ascii=False), pos))
        seen_ft = set()
        for f, t in e["inflections"]:
            key = (f.lower(), lemma, t)
            if key in seen_ft:
                continue
            seen_ft.add(key)
            form_rows.append((f.lower(), lemma, t))
        # Also index the lemma itself and principal parts.
        form_rows.append((lemma, lemma, "LEMMA"))
        for p in e["principal"]:
            tok = p.split()[0].rstrip(".,;:").lower()
            if tok:
                form_rows.append((tok, lemma, "PRINCIPAL"))

    print(f"writing {len(rows)} entries …", flush=True)
    conn.executemany(
        "INSERT INTO entries(lemma, definition, forms, pos) VALUES (?, ?, ?, ?)",
        rows,
    )
    print(f"writing {len(form_rows)} form_index rows …", flush=True)
    conn.executemany(
        "INSERT OR IGNORE INTO form_index(form, lemma, tag) VALUES (?, ?, ?)",
        form_rows,
    )
    conn.commit()
    n = conn.execute("SELECT COUNT(*) FROM entries").fetchone()[0]
    amo = conn.execute("SELECT lemma, pos, definition, forms FROM entries WHERE lemma='amo'").fetchone()
    conn.close()
    print(f"wrote {DB_PATH} with {n} entries", flush=True)
    if amo:
        forms = json.loads(amo[3])
        print(f"sample amo: pos={amo[1]}")
        print(f"  definition={amo[2][:120]}")
        print(f"  principal={forms.get('principal_parts')}")
        print(f"  n_inflections={len(forms.get('table') or [])}")
    else:
        print("WARNING: lemma amo not found", flush=True)
        return 2
    if n < 10000:
        print(f"ERROR: only {n} entries, need >= 10000", flush=True)
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
