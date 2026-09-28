# Tasks

Legend: `[ ]` todo · `[x]` done · **(S/M/L)** rough size

See `project.md` for architecture and background.

---

## M0 — Setup

- [ ] Copy `GS1 Basic.dotm`, `GS1 Advanced.dotm`, `GS1 Letterhead.dotm` into `priv/templates/` (rename without spaces: `basic.dotm`, `advanced.dotm`, `letterhead.dotm`) **(S)**
- [ ] Add `GS1_Template_MSWord_A4_2025/` originals to `.gitignore` or keep as reference — decide **(S)**
- [ ] Install system tools locally: LibreOffice (`soffice`), poppler (`pdftotext`), Verdana font **(S)**
- [ ] Add Hex deps: `saxy` (or `sweet_xml`), `mdex` (or `earmark`) **(S)**
- [ ] Add a `Docgen.SystemCheck` that verifies `soffice`/`pdftotext` exist at boot and logs a warning if not **(S)**

## M1 — Text/Markdown → GS1 Basic DOCX

- [ ] Define `Docgen.Document` struct + block/inline types (see IR in `project.md`) **(S)**
- [ ] `Docgen.Ingest.Markdown` — Markdown AST → IR (headings, paragraphs, bold/italic/code/links, bullet & numbered lists incl. nesting, tables, code blocks) **(M)**
- [ ] `Docgen.Ingest.Text` — plain text heuristics (paragraphs, bullet detection, heading guess) **(S)**
- [ ] `Docgen.Template` — load `.dotm` from `priv/templates`, unzip in memory, expose parts as a map **(S)**
- [ ] Style map per template (`Docgen.Template.StyleMap`): IR block → GS1 style ID **(S)**
- [ ] `Docgen.Render.Docx.Xml` — IR → WordprocessingML (`<w:p>`, `<w:r>`, `<w:rPr>`, `<w:tbl>`), with proper XML escaping **(M)**
- [ ] Lists: wire bullets/numbering to existing `numbering.xml` `numId`s (or use `ListBullet`/`ListNumber` styles that already carry numbering) **(M)**
- [ ] Hyperlinks: add relationships to `document.xml.rels` **(S)**
- [ ] Replace body of `document.xml`, preserve trailing `<w:sectPr>` (headers/footers/margins) **(M)**
- [ ] Fill title/subtitle from `meta` using `GS1BTitle` / `GS1BSubtitle` **(S)**
- [ ] Strip macros: remove `vbaProject.bin`, `vbaData.xml`, signatures, `customUI/`, related rels & `[Content_Types].xml` overrides; switch main content type to `.docx` **(M)**
- [ ] Re-zip to `.docx` binary **(S)**
- [ ] Tests: generated docx unzips, XML is well-formed, expected style IDs present, no vba parts remain **(M)**
- [ ] Manual check: open output in Word and LibreOffice — no "repair" prompt **(S)**

## M2 — PDF export

- [ ] `Docgen.Convert.Pdf.from_docx/1` — write temp file, `soffice --headless --convert-to pdf --outdir`, read result, clean up **(M)**
- [ ] Unique `-env:UserInstallation=file:///tmp/lo-<uuid>` per run to allow concurrency **(S)**
- [ ] Timeout + error handling (`{:error, :timeout | :conversion_failed}`) **(S)**
- [ ] Limit concurrency (Task.Supervisor with max children, or Oban queue) **(S)**
- [ ] Test (tagged `:libreoffice`, skipped when `soffice` missing) **(S)**
- [ ] Visual comparison: generated PDF vs a document made by hand in Word with the same template **(S)**

## M3 — LiveView UI

- [ ] Route `live "/", DocumentLive.New` **(S)**
- [ ] Layout: left = input (tabs: *Paste text* / *Upload file*), right = preview **(M)**
- [ ] Template picker (Basic / Advanced / Letterhead) with dynamic metadata form using `<.input>` **(M)**
- [ ] `allow_upload(:source, accept: ~w(.txt .md .docx .pdf), max_file_size: 20MB)` **(S)**
- [ ] `Docgen.Render.Html` — IR → preview HTML with GS1-like CSS (navy `#002C6C` headings, orange `#F26334` title band, Verdana) **(M)**
- [ ] Live preview updates on text change (debounced) **(S)**
- [ ] Download controller: `GET /documents/:id/download?format=docx|pdf` (serve from temp storage/ETS keyed by token) **(M)**
- [ ] Loading state while PDF converts; flash on errors **(S)**
- [ ] Warnings panel for low-confidence ingest **(S)**
- [ ] LiveView tests for paste → preview → download flow **(M)**

## M4 — DOCX & PDF input

- [ ] `Docgen.Ingest.Docx` — parse source `document.xml`: paragraphs, runs (b/i/u), headings by style name/outline level, lists via `w:numPr`, tables **(L)**
- [ ] Read source `styles.xml` to resolve custom heading styles to levels **(M)**
- [ ] Extract embedded images (`word/media`) into `{:image, ...}` blocks **(M)**
- [ ] `Docgen.Ingest.Pdf` — `pdftohtml -xml` to get text + font sizes; cluster font sizes → heading levels; join lines into paragraphs; detect bullets **(L)**
- [ ] Mark PDF ingest as low confidence; surface in UI **(S)**
- [ ] Fixture files + tests for each ingest path **(M)**

## M5 — GS1 Advanced template

- [ ] Style map for Advanced (`GS1Title1–4`, `GS1Body`, `GS1Bullet1–4`, `GS1List1–4`, `GS1Table*`, `GS1Note`, `GS1Important`, `GS1CodeBlock`, captions) **(M)**
- [ ] Fill cover page placeholders ("GS1 Document Name", "GS1 Document Type", "Optional Description") **(M)**
- [ ] Cover graphic option (choose from template media / industry icons in assets folder) **(M)**
- [ ] Table of contents field (`TOC \o "1-3"`) + update on PDF conversion **(M)**
- [ ] Markdown extensions for notes: `> **Note:**` → `GS1Note`, `> **Important:**` → `GS1Important` **(S)**
- [ ] Figure/table captions **(S)**

## M6 — GS1 Letterhead template

- [ ] Map letterhead content controls (`<w:sdt>`: sender name/address, date, recipient) to `meta` fields **(M)**
- [ ] Metadata form fields for letter **(S)**
- [ ] Option: "hide letterhead graphics" for pre-printed paper **(S)**

## M7 — Polish & deploy

- [ ] Localisation settings: upload MO logo, address, footer text → swap `word/media` image + footer XML **(L)**
- [ ] Persist generated documents (Ecto schema: source, template, meta, files) + history page **(M)**
- [ ] Dockerfile with LibreOffice, poppler, fonts (Verdana/brand font) **(M)**
- [ ] Clean up temp files (periodic job) **(S)**
- [ ] Update `README.md` with setup (system deps) and usage **(S)**
- [ ] `mix precommit` passes **(S)**

---

## Open questions

- [ ] Confirm rights to use GS1 branding/templates
- [ ] Is the GS1 brand font available/licensed for the server?
- [ ] Which template is the priority after Basic — Advanced or Letterhead?
- [ ] Need user accounts/history, or stateless generate-and-download?
