# Technical reference for AI agents

## Project structure

- `data/*.yaml` — CV data (single source of truth, concatenated into `cv.yaml` by Make)
- `publications.bib` — BibTeX bibliography
- `pandoc/templates/` — LaTeX templates for PDF outputs
- `pandoc/filters/cv_to_moderncv.lua` — Lua filter that generates CV body from YAML
- `scripts/` — Python utilities (`bib_to_yaml.py`, `format_bib.py`, `add_abstracts.py`)
- `site/` — Hugo website (content, layouts, assets, data)
- `site/hugo.yaml` — Hugo configuration (migrated from `hugo.toml`)
- `data/schema.json` — JSON Schema 2020-12 for all data YAML
- `site/assets/css/main.scss` — single SCSS stylesheet (Hugo Pipes)
- `.github/workflows/ci-tests.yml` — builds PDFs + site on PR/push to main
- `.github/workflows/release.yml` — deploys to GitHub Pages on CI success on main

## CV data (`data/*.yaml`)

Each YAML file has a top-level key matching its filename.
- `personal.yaml`: `first`, `last`, `address1`, `address2`, `email`, `homepage`,
  `github`, `orcid`, `googlescholar`, `linkedin`, `scopus`, `wos`, `photo`,
  `photo_height`, `photo_frame`, `bio`
- `software.yaml`: `start`, `title`, `role`, `description`, plus optional
  `website`, `github`, `citation` (publication key), `package` (URL)

Schema enforces `additionalProperties: false` — any undeclared field fails.

## Publications (`publications.bib`)

- Format: biblatex-ieee style
- Every entry requires `keywords = {journal|conference|book|poster|thesis}`
- `author+an = {N=highlight}` marks author position N for blue+bold rendering
- `addendum` renders as a blue note after the entry
- Keys follow `YY:firstauthor:keyword`
- `abstract` field percent-escaped (`\%`, `\&`, `\#`)
- Month fields must be bare (no curly braces: `month = sep,`)
- Single-author entries must not have trailing "and"
- Run `uv run python scripts/format_bib.py publications.bib` to normalise
  (idempotent only on its own output)

## Website architecture (no-JS)

- **Dark mode**: `@media (prefers-color-scheme: dark)` for OS-follow;
  `<input type="checkbox" id="dark-mode">` with `.theme-toggle-input:checked ~ .page-wrapper`
  overrides to opposite theme. Moon/sun SVG icons swap accordingly.
- **Abstract/BibTeX toggles**: `<details name="details-{{ $entryKey }}">` for
  mutual exclusion within each publication entry. Expanded content uses
  `position: absolute; left: 0; right: 0` from `.entry-btn-row` (full card width).
  Two CSS classes: `.entry-abstract-body` and `.entry-bibtex-body` (with `<pre>`).
- **Hamburger menu**: hidden checkbox `<input type="checkbox" id="nav-toggle">`
  inside `<header>`. CSS `.site-header:has(.nav-toggle-input:checked) .nav-links`
  shows the menu. Two SVGs in the label (hamburger lines / X) swap via
  `display: none/block` on `:checked`. Breakpoint: 720px.
- **Software section**: buttons build dynamically from optional fields
  (Website, GitHub, Package links; Reference toggle looks up BibTeX by key
  from `hugo.Data.publications`).
- **SEO**: canonical URLs, OG/Twitter Card meta, JSON-LD Person schema with
  sameAs (GitHub, ORCID, Google Scholar, LinkedIn, Scopus, WoS) in `head.html`.
- **Academicons**: Scopus and WoS SVGs are official Academicons files
  (SIL OFL 1.1) with `<!-- … from Academicons (SIL OFL 1.1) -->` comments.

## Shared partial: `list-entry.html`

Used by Publications, Talks, Software, Teaching, Activities pages.

Fields: `period`, `title`, `subtitle`, `kind`, `author`, `subject`, `label`,
`meta`, `desc`, `badge`, `buttons`.

Buttons are a slice of dicts:
- `{type: "toggle", label, key, content, contentClass, wrapPre}` — `<details name="…">`
- `{type: "link", label, url}` — `<a>` with `target="_blank"`

`contentClass` defaults to `"entry-abstract-body"`; passing `"entry-bibtex-body"`
with `wrapPre: true` matches the publications BibTeX display.

## Make targets

```
make cv.yaml          # concatenate data/*.yaml
make validate         # merge + check-jsonschema against schema.json
make cv               # cv.yaml + pandoc + pdflatex (2 passes)
make publications     # cv.yaml + pandoc + pdflatex + biber + pdflatex (2 passes)
make cv-with-publications  # validate + pandoc + pdflatex + biber + pdflatex (2 passes)
make site             # copy data, run bib_to_yaml.py, hugo --source site
make serve            # same with hugo server
make clean            # remove all generated artifacts
```

`cv.yaml` is rebuilt by Make when any `data/*.yaml` changes.

## CI/CD

### ci-tests.yml

Triggers on PR and push to `main`.  Steps:
1. Install Hugo extended, Pandoc, TinyTeX (cached), Python deps via `uv`
2. `make cv.yaml` → `make validate` → `make cv` → `make publications` → `make cv-with-publications`
3. `cp cv.pdf site/static/cv.pdf`
4. `uv run python scripts/bib_to_yaml.py publications.bib site/data/publications.yaml`
5. `cp cv.yaml site/data/cv.yaml`
6. `hugo --source site --minify`
7. Upload `site/public` as `site-public` artifact

TinyTeX packages installed: `moderncv eurosym geometry fontawesome5 microtype
xcolor url hyperref etoolbox xpatch lm tools collection-fontsrecommended pgf
biblatex biblatex-ieee biber.x86_64-linux`

Note: `$GITHUB_PATH` only affects subsequent steps, so full paths
(`$HOME/.TinyTeX/bin/x86_64-linux/tlmgr`) are used within the install step.

### release.yml

Triggers on `workflow_run` when CI Tests completes on `main`.  Downloads
the `site-public` artifact, configures Pages, and deploys via
`actions/deploy-pages@v4`.

## Key decisions

- No JavaScript anywhere: toggles use HTML `<details name="…">`, dark mode
  uses `@media` + `:checked`, hamburger uses hidden checkbox + `:has()`
- All data in one `cv.yaml` for Hugo (accessed as `hugo.Data.cv.*`)
- Publications data kept separate (`site/data/publications.yaml`)
- CV Lua filter only reads `title`, `role`, `description` from software entries
  (new schema fields like `website`, `citation` are website-only)
- After editing `data/personal.yaml`, regenerate CV PDF with `make cv.yaml &&
  cp cv.yaml site/data/cv.yaml`
