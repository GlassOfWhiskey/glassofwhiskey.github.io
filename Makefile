.PHONY: cv publications cv-with-publications validate site serve clean

DATA_YAMLS = \
	data/personal.yaml \
	data/experience.yaml \
	data/awards.yaml \
	data/education.yaml \
	data/research.yaml \
	data/projects.yaml \
	data/conferences.yaml \
	data/software.yaml \
	data/editorial.yaml \
	data/review.yaml \
	data/teaching.yaml

cv.yaml: $(DATA_YAMLS)
	for f in $(DATA_YAMLS); do cat "$$f"; echo; done > cv.yaml

# ── Plain CV (no publications) ────────────────────────────────────────────────

cv.tex: validate pandoc/templates/moderncv.latex pandoc/filters/cv_to_moderncv.lua
	pandoc /dev/null \
		-f markdown+smart \
		--metadata-file=cv.yaml \
		--template pandoc/templates/moderncv.latex \
		--lua-filter pandoc/filters/cv_to_moderncv.lua \
		-t latex \
		-o cv.tex

cv: cv.tex
	pdflatex -interaction=nonstopmode cv.tex
	pdflatex -interaction=nonstopmode cv.tex

# ── Publications only ─────────────────────────────────────────────────────────

publications.tex: cv.yaml pandoc/templates/moderncv-publications.latex
	pandoc /dev/null \
		-f markdown+smart \
		--metadata-file=cv.yaml \
		--template pandoc/templates/moderncv-publications.latex \
		-t latex \
		-o publications.tex

publications: publications.tex
	pdflatex -interaction=nonstopmode publications.tex
	biber publications
	pdflatex -interaction=nonstopmode publications.tex
	pdflatex -interaction=nonstopmode publications.tex

# ── CV with publications ──────────────────────────────────────────────────────

cv-with-publications.tex: validate pandoc/templates/moderncv-cv-with-publications.latex pandoc/filters/cv_to_moderncv.lua
	pandoc /dev/null \
		-f markdown+smart \
		--metadata-file=cv.yaml \
		--template pandoc/templates/moderncv-cv-with-publications.latex \
		--lua-filter pandoc/filters/cv_to_moderncv.lua \
		-t latex \
		-o cv-with-publications.tex

cv-with-publications: cv-with-publications.tex
	pdflatex -interaction=nonstopmode cv-with-publications.tex
	biber cv-with-publications
	pdflatex -interaction=nonstopmode cv-with-publications.tex
	pdflatex -interaction=nonstopmode cv-with-publications.tex

# ── Validation ────────────────────────────────────────────────────────────────

validate: cv.yaml
	uv run check-jsonschema --schemafile data/schema.json cv.yaml

# ── Hugo site data (generated, gitignored) ────────────────────────────────────

site/data/cv.yaml: cv.yaml
	mkdir -p site/data
	cp cv.yaml site/data/cv.yaml

site/data/publications.yaml: publications.bib scripts/bib_to_yaml.py
	mkdir -p site/data
	uv run python scripts/bib_to_yaml.py publications.bib site/data/publications.yaml

site/data/teaching.yaml: data/teaching.yaml
	mkdir -p site/data
	cp data/teaching.yaml site/data/teaching.yaml

site/static/pictures/picture.jpg: pictures/picture.jpg
	mkdir -p site/static/pictures
	cp pictures/picture.jpg site/static/pictures/picture.jpg

# ── Build Hugo site ───────────────────────────────────────────────────────────

site: site/data/cv.yaml site/data/publications.yaml site/data/teaching.yaml site/static/pictures/picture.jpg
	hugo --source site

# ── Local dev server ──────────────────────────────────────────────────────────

serve: site/data/cv.yaml site/data/publications.yaml site/data/teaching.yaml site/static/pictures/picture.jpg
	hugo server --source site

# ── Clean ─────────────────────────────────────────────────────────────────────

clean:
	rm -f cv.tex cv.pdf publications.tex publications.pdf \
		cv-with-publications.tex cv-with-publications.pdf \
		cv.yaml *.aux *.log *.out *.toc *.lof *.lot *.fls *.fdb_latexmk \
		*.bbl *.bcf *.blg *.run.xml *.synctex.gz
	rm -f site/data/cv.yaml site/data/publications.yaml site/data/teaching.yaml
	rm -rf site/public/ site/resources/
