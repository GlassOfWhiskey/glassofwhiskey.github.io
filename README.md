# Personal CV & website

This repository builds [my academic CV](https://glassofwhiskey.github.io/cv.pdf)
and [personal website](https://glassofwhiskey.github.io) from YAML data files
and a BibTeX bibliography.

---

## Prerequisites

| Tool | Install |
|------|---------|
| `pandoc` ≥ 3.0 | `brew install pandoc` |
| `pdflatex` + `biber` | [MacTeX](https://tug.org/mactex/) |
| `hugo` (extended) | `brew install hugo` |
| `uv` | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |
| `check-jsonschema` | `uv tool install check-jsonschema` |

---

## Make targets

**Generic**
```
make cv.yaml       Merge data/*.yaml into cv.yaml
make validate      Merge + validate against data/schema.json
make clean         Remove all generated files
```

**PDF outputs**
```
make cv                     Plain CV
make publications           Publications list only (with biber)
make cv-with-publications   Full CV + publications
```

**Website**
```
make site          Build Hugo site to site/public/
make serve         Same, with dev server at http://localhost:1313
```

All PDF targets validate first.  `cv.yaml` rebuilds automatically when any
`data/*.yaml` is newer.

---

## How to add or update content

### CV data (experience, teaching, projects, etc.)

Edit the relevant file under `data/` — never edit `cv.yaml` directly.

| File | What it holds |
|------|---------------|
| `personal.yaml` | Name, bio, email, social links, photo |
| `experience.yaml` | Work positions |
| `awards.yaml` | Honours and prizes |
| `education.yaml` | Degrees |
| `research.yaml` | Research roles |
| `projects.yaml` | Funded projects |
| `conferences.yaml` | Chairs, committee, talks |
| `software.yaml` | Open-source tools |
| `editorial.yaml` | Editorial roles |
| `review.yaml` | Review activity |
| `teaching.yaml` | Courses, schools, mentorship |

Dates can be a single year (`year: 2024`), an academic year
(`year: "2023/2024"`), or a range (`start: 2020`, `end: 2024`).

Inline markup is supported: `` `code` ``, `*italic*`, `**bold**`.

After editing, run `make validate` to check for errors, then `make site` to
rebuild the website.

### Publications

Edit `publications.bib`.  Each entry needs:
- A `keywords` field: `journal`, `conference`, `book`, `poster`, or `thesis`
- An `author+an` field to highlight your name (e.g. `author+an = {3=highlight}`)
- A key following the pattern `YY:firstauthor:keyword` (e.g. `24:smith:flow`)

After editing, run:
```
uv run python scripts/bib_to_yaml.py publications.bib site/data/publications.yaml
make site
```

### Profile photo

Replace `pictures/picture.jpg` (keep the filename).

### Software entries

Optional fields per entry: `website`, `github`, `package` (URLs) and
`citation` (a publication key from `publications.bib` to show a Reference
button on the website).

---

## Workflow

1. Edit data or publications
2. `make site` to preview locally
3. Commit and push — CI builds PDFs + site and deploys to GitHub Pages
