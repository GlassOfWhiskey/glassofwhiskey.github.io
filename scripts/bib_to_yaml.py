#!/usr/bin/env python3
"""Convert publications.bib to Hugo-compatible YAML data file.

Delegates the heavy lifting (LaTeX → Unicode, author parsing, field mapping)
to pandoc's CSL JSON output.  Two fields need a separate regex pass on the
raw .bib text because CSL has no equivalent:
  - `author+an`  (biblatex highlight annotation)
  - `addendum`   (stripped from clean BibTeX download)

Usage:
    uv run python scripts/bib_to_yaml.py publications.bib site/data/publications.yaml
"""

import json
import re
import subprocess
import sys
import yaml
from pathlib import Path

# Canonical type ordering within a year (journals first, then proceedings, etc.)
KEYWORD_ORDER = {
    "journal": 0,
    "conference": 1,
    "book": 2,
    "poster": 3,
    "thesis": 4,
}

# IEEE-style month abbreviations (May has no period — already ≤3 chars)
MONTH_ABBR = {
    1: "Jan.", 2: "Feb.", 3: "Mar.", 4: "Apr.", 5: "May",
    6: "Jun.", 7: "Jul.", 8: "Aug.", 9: "Sep.", 10: "Oct.",
    11: "Nov.", 12: "Dec.",
}


# ── raw BibTeX extraction ─────────────────────────────────────────────────────


def _entry_boundaries(bib_text: str) -> list[tuple[str, int, int]]:
    """Return [(key, start, end), ...] byte boundaries for every BibTeX entry."""
    headers = [
        (m.group(1).strip(), m.start())
        for m in re.finditer(r"@\w+\{\s*([^,\s]+)\s*,", bib_text)
    ]
    return [
        (key, start, headers[i + 1][1] if i + 1 < len(headers) else len(bib_text))
        for i, (key, start) in enumerate(headers)
    ]


def extract_highlight_map(bib_text: str) -> dict[str, int]:
    """Return {entry_key: 1-based_highlight_index} from all author+an fields."""
    highlight_map: dict[str, int] = {}
    for key, start, end in _entry_boundaries(bib_text):
        entry_text = bib_text[start:end]
        m = re.search(
            r'author\+an\s*=\s*[{"]\s*(\d+)\s*=\s*highlight', entry_text, re.IGNORECASE
        )
        if m:
            highlight_map[key] = int(m.group(1))
    return highlight_map


def _extract_bib_field(entry_text: str, field: str) -> str:
    """Extract the raw text value of a BibTeX field using brace-depth tracking.

    Strips exactly one level of outer braces/quotes so that inner protection
    braces (e.g. {IEEE}) are preserved for the caller to remove later.
    """
    m = re.search(rf"\b{re.escape(field)}\s*=\s*", entry_text, re.IGNORECASE)
    if not m:
        return ""
    pos = m.end()
    while pos < len(entry_text) and entry_text[pos] in " \t\n\r":
        pos += 1
    if pos >= len(entry_text):
        return ""
    if entry_text[pos] == "{":
        depth = 0
        start = pos + 1
        for i in range(pos, len(entry_text)):
            if entry_text[i] == "{":
                depth += 1
            elif entry_text[i] == "}":
                depth -= 1
                if depth == 0:
                    return entry_text[start:i]
    elif entry_text[pos] == '"':
        end = entry_text.index('"', pos + 1)
        return entry_text[pos + 1 : end]
    return ""


def _latex_venue_to_text(raw: str) -> str:
    """Minimal LaTeX → plain text conversion for journal/booktitle values.

    Handles the constructs that actually appear in venue fields:
    escaped special chars, \\textsuperscript / \\textsubscript, and
    inner protection braces like {IEEE}.  Author-name macros are left to
    pandoc (they only appear in author/editor fields).
    """
    # Strip macro wrappers, keep content
    for cmd in ("textsuperscript", "textsubscript", "emph", "textbf", "textit", "textsc"):
        raw = re.sub(rf"\\{cmd}\{{([^{{}}]*)\}}", r"\1", raw)
    # Special characters
    raw = (
        raw.replace(r"\&", "&")
        .replace(r"\%", "%")
        .replace(r"\$", "$")
        .replace(r"\#", "#")
        .replace(r"\_", "_")
    )
    # Remove remaining braces (inner case-protection like {ACM}, {IEEE})
    raw = raw.replace("{", "").replace("}", "")
    # Collapse whitespace (multiline values may have extra newlines/spaces)
    raw = re.sub(r"\s+", " ", raw)
    return raw.strip()


def extract_venue_map(bib_text: str) -> dict[str, str]:
    """Return {entry_key: venue_string} with the original BibTeX capitalisation.

    Pandoc normalises ``container-title`` to sentence-case in CSL JSON.
    We bypass that by reading ``journal`` / ``booktitle`` directly from the
    raw .bib text and doing only a minimal LaTeX → text cleanup.
    """
    venue_map: dict[str, str] = {}
    for key, start, end in _entry_boundaries(bib_text):
        entry_text = bib_text[start:end]
        for field in ("journal", "booktitle", "school"):
            raw = _extract_bib_field(entry_text, field)
            if raw:
                venue_map[key] = _latex_venue_to_text(raw)
                break
    return venue_map



def extract_clean_bibtex(bib_text: str) -> dict[str, str]:
    """Return {entry_key: clean_bibtex_string} for every entry.

    Strips biblatex-specific fields (author+an, addendum, abstract,
    keywords, url) that are not valid in standard BibTeX and would
    confuse most reference managers.
    """
    clean_map: dict[str, str] = {}
    for key, start, end in _entry_boundaries(bib_text):
        raw = bib_text[start:end].rstrip()
        cleaned = re.sub(r"\n[ \t]*author\+an\s*=[^\n]*", "", raw)
        cleaned = re.sub(r"\n[ \t]*addendum\s*=[^\n]*", "", cleaned)
        cleaned = re.sub(r"\n[ \t]*abstract\s*=[^\n]*", "", cleaned)
        cleaned = re.sub(r"\n[ \t]*keywords\s*=[^\n]*", "", cleaned)
        cleaned = re.sub(r"\n[ \t]*url\s*=[^\n]*", "", cleaned)
        clean_map[key] = cleaned + "\n"
    return clean_map


# ── author formatting ─────────────────────────────────────────────────────────


def name_initials(given: str) -> str:
    """'Iacopo Marco' → 'I. M.'  |  'J.-P.' stays 'J.-P.'"""
    parts = given.strip().split()
    result = []
    for p in parts:
        if re.fullmatch(r"[A-Z]\.(-[A-Z]\.)?", p):
            result.append(p)  # already an initial
        elif p:
            result.append(p[0].upper() + ".")
    return " ".join(result)


def build_authors(csl_authors: list[dict], highlight_idx: int | None) -> list[dict]:
    """Convert CSL author list to our structured format, marking the highlighted author."""
    result = []
    for i, a in enumerate(csl_authors):
        family = a.get("family", "")
        given = a.get("given", "")
        result.append(
            {
                "given": given,
                "family": family,
                "initials": name_initials(given) if given else "",
                "highlight": bool(
                    highlight_idx is not None and (i + 1) == highlight_idx
                ),
            }
        )
    return result


# ── venue extraction from CSL ─────────────────────────────────────────────────


def get_venue(entry: dict) -> str:
    """Return the most appropriate venue string for a CSL entry."""
    csl_type = entry.get("type", "")
    if csl_type == "article-journal":
        return entry.get("container-title", "")
    if csl_type == "paper-conference":
        return entry.get("container-title", "") or entry.get("event-title", "")
    if csl_type in ("chapter", "book"):
        return entry.get("container-title", "") or entry.get("collection-title", "")
    if csl_type == "thesis":
        return entry.get("publisher", "")
    # fallback
    return entry.get("container-title", "") or entry.get("publisher", "")


# ── main conversion ───────────────────────────────────────────────────────────


def bib_to_csl(bib_path: Path) -> list[dict]:
    """Run pandoc to convert .bib → CSL JSON."""
    result = subprocess.run(
        ["pandoc", str(bib_path), "-t", "csljson"],
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(result.stdout)


def process_entries(
    csl_entries: list[dict],
    highlight_map: dict[str, int],
    clean_bib_map: dict[str, str],
    venue_map: dict[str, str],
) -> list[dict]:
    """Build our output entry list from CSL data + highlight annotations + raw BibTeX."""
    entries = []
    for e in csl_entries:
        key = e.get("id", "")
        highlight = highlight_map.get(key)
        csl_authors = e.get("author", [])
        year_parts = e.get("issued", {}).get("date-parts", [[""]])
        year = str(year_parts[0][0]) if year_parts and year_parts[0] else ""
        month_num = year_parts[0][1] if year_parts and len(year_parts[0]) > 1 else None
        month = MONTH_ABBR.get(int(month_num), "") if month_num else ""

        # keyword: CSL carries the raw BibTeX keywords value
        keyword = e.get("keyword", "").strip().rstrip(",").strip()

        # Prefer raw-BibTeX venue (original casing) over pandoc's sentence-cased CSL value
        venue = venue_map.get(key) or get_venue(e)

        csl_type = e.get("type", "")
        entry: dict = {
            "key": key,
            "type": csl_type,
            "year": year,
            "authors": build_authors(csl_authors, highlight),
            "title": e.get("title", "").strip(),
            "venue": venue,
            "keyword": keyword,
        }
        if month:
            entry["month"] = month
        for src, dst in (
            ("DOI", "doi"),
            ("volume", "volume"),
            ("page", "pages"),
            ("note", "note"),
            ("ISBN", "isbn"),
            ("number", "number"),
            ("URL", "url"),
        ):
            val = e.get(src, "")
            if val and str(val).strip():
                entry[dst] = str(val).strip()

        abstract = e.get("abstract", "")
        if abstract and abstract.strip():
            entry["abstract"] = abstract.strip()

        # publisher_place for all types (including thesis — it's the city/country)
        pp = e.get("publisher-place", "").strip()
        if pp:
            entry["publisher_place"] = pp

        # publisher only for non-thesis (for thesis the institution is already the venue)
        if csl_type != "thesis":
            pub = e.get("publisher", "").strip()
            if pub:
                entry["publisher"] = pub

        # thesis type label derived from CSL genre field
        if csl_type == "thesis":
            genre = e.get("genre", "").lower()
            if "phd" in genre or "doctoral" in genre:
                entry["thesis_type"] = "Ph.D. dissertation"
            elif "master" in genre:
                entry["thesis_type"] = "M.S. thesis"
            else:
                entry["thesis_type"] = "Thesis"

        # editor: format as "I. Smith, Ed." / "I. Smith and J. Doe, Eds."
        editors = e.get("editor", [])
        if editors:
            ed_strs = [
                f"{name_initials(ed.get('given', ''))} {ed.get('family', '')}".strip()
                for ed in editors
            ]
            if len(ed_strs) == 1:
                entry["editor"] = ed_strs[0] + ", Ed."
            elif len(ed_strs) == 2:
                entry["editor"] = ed_strs[0] + " and " + ed_strs[1] + ", Eds."
            else:
                entry["editor"] = (
                    ", ".join(ed_strs[:-1]) + ", and " + ed_strs[-1] + ", Eds."
                )

        bib = clean_bib_map.get(key, "")
        if bib:
            entry["bibtex"] = bib

        entries.append(entry)
    return entries


def group_by_year(entries: list[dict]) -> list[dict]:
    """Group entries by year (descending). Within each year sort by type then original order."""
    buckets: dict[str, list] = {}
    for i, entry in enumerate(entries):
        year = entry.get("year", "")
        if year not in buckets:
            buckets[year] = []
        # Stash original index so stable sort within type preserves BibTeX order
        buckets[year].append((i, entry))

    sorted_years = sorted(buckets.keys(), reverse=True)
    result = []
    for year in sorted_years:
        year_entries = sorted(
            buckets[year],
            key=lambda t: (KEYWORD_ORDER.get(t[1].get("keyword", ""), 99), t[0]),
        )
        result.append({"year": year, "entries": [e for _, e in year_entries]})
    return result


def main() -> None:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <input.bib> <output.yaml>", file=sys.stderr)
        sys.exit(1)

    bib_path = Path(sys.argv[1])
    yaml_path = Path(sys.argv[2])

    bib_text = bib_path.read_text(encoding="utf-8")
    highlight_map = extract_highlight_map(bib_text)
    clean_bib_map = extract_clean_bibtex(bib_text)
    venue_map = extract_venue_map(bib_text)
    csl_entries = bib_to_csl(bib_path)
    entries = process_entries(csl_entries, highlight_map, clean_bib_map, venue_map)
    years = group_by_year(entries)

    yaml_path.parent.mkdir(parents=True, exist_ok=True)
    with yaml_path.open("w", encoding="utf-8") as f:
        yaml.dump(
            {"years": years},
            f,
            allow_unicode=True,
            sort_keys=False,
            default_flow_style=False,
        )

    total = sum(len(y["entries"]) for y in years)
    print(f"Written {total} entries in {len(years)} year groups → {yaml_path}")


if __name__ == "__main__":
    main()
