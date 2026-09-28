# Tasks

Legend: `[ ]` todo · `[x]` done · **(S/M/L)** rough size

See `project.md` for architecture and background.

---

## M0 — Setup

- [x] Copy `GS1 Basic.dotm`, `GS1 Advanced.dotm`, `GS1 Letterhead.dotm` into `priv/templates/` (rename without spaces: `basic.dotm`, `advanced.dotm`, `letterhead.dotm`) **(S)**
- [x] Keep `GS1_Template_MSWord_A4_2025/` originals in the repo as reference (3.8 MB); ignore `.DS_Store` / `Thumbs.db` **(S)**
- [ ] Install system tools locally: LibreOffice (`soffice`), poppler (`pdftotext`), Verdana font **(S)**
  - [x] poppler (`/opt/homebrew/bin/pdftotext`, `pdftohtml`)
  - [x] Verdana (ships with macOS)
  - [x] LibreOffice 26.8 installed (`/opt/homebrew/bin/soffice`)
  - [ ] Clear Gatekeeper quarantine (open LibreOffice.app once) — until then headless runs exit 1 with no output
- [ ] ~~Add Hex deps: `saxy`, `mdex`~~ — still blocked by sandbox proxy (`repo.hex.pm`); M1 built dependency-free instead (string-built OOXML, OTP `:zip`/`:xmerl`, own Markdown parser). Revisit if richer Markdown (footnotes, HTML) is needed **(S)**
- [x] Add a `Docgen.SystemCheck` that verifies `soffice`/`pdftotext` exist at boot and logs a warning if not **(S)**

## M1 — Text/Markdown → GS1 Basic DOCX

- [x] Define `Docgen.Document` struct + block/inline types (see IR in `project.md`) **(S)**
- [x] `Docgen.Ingest.Markdown` — Markdown AST → IR (headings, paragraphs, bold/italic/code/links, bullet & numbered lists incl. nesting, tables, code blocks) **(M)** — also front matter (`title`/`subtitle`), blockquotes → `:note`, sole leading H1 → title
- [x] `Docgen.Ingest.Text` — plain text heuristics (paragraphs, bullet detection, heading guess) **(S)**
- [x] `Docgen.Template` — load `.dotm` from `priv/templates`, unzip in memory, expose parts as a map **(S)**
- [x] Style map per template (`Docgen.Template.StyleMap`): IR block → GS1 style ID **(S)**
- [x] `Docgen.Render.Docx.Xml` — IR → WordprocessingML (`<w:p>`, `<w:r>`, `<w:rPr>`, `<w:tbl>`), with proper XML escaping **(M)**
- [x] Lists: wire bullets/numbering to existing `numbering.xml` `numId`s (or use `ListBullet`/`ListNumber` styles that already carry numbering) **(M)** — bullets use `ListBullet*` styles; each numbered list gets its own `<w:num>` with `startOverride` so it restarts at 1
- [x] Hyperlinks: add relationships to `document.xml.rels` **(S)**
- [x] Replace body of `document.xml`, preserve trailing `<w:sectPr>` (headers/footers/margins) **(M)**
- [x] Fill title/subtitle from `meta` using `GS1BTitle` / `GS1BSubtitle` **(S)**
- [x] Strip macros: remove `vbaProject.bin`, `vbaData.xml`, signatures, `customUI/`, related rels & `[Content_Types].xml` overrides; switch main content type to `.docx` **(M)**
- [x] Re-zip to `.docx` binary **(S)**
- [x] Tests: generated docx unzips, XML is well-formed, expected style IDs present, no vba parts remain **(M)**
- [x] `mix docgen.render INPUT [-o OUT] [--title T] [--subtitle S]` for manual checks **(S)**
- [ ] Manual check: open output in Word and LibreOffice — no "repair" prompt **(S)**

## M2 — PDF export

- [x] `Docgen.Convert.Pdf.from_docx/2` — write temp file, `soffice --headless --convert-to pdf --outdir`, read result, clean up **(M)**
- [x] Isolated `-env:UserInstallation` profiles — one per limiter slot (reused, avoids first-run setup each call; reset after a timeout) **(S)**
- [x] Timeout + error handling (`{:error, :timeout | :conversion_failed | :soffice_not_found}`); runs via a Port and kills soffice on timeout **(S)**
- [x] Limit concurrency — `Docgen.Convert.Limiter` (FIFO semaphore, frees slots when callers die), `max_concurrency: 2` in config **(S)**
- [x] Test (tagged `:libreoffice`, skipped when `soffice` missing) **(S)** — plus fake-`soffice` tests for success/failure/timeout/cleanup
- [x] `Docgen.to_pdf/2` and `mix docgen.render INPUT --pdf` **(S)**
- [ ] Run the `:libreoffice` tests for real (`mix test --include libreoffice`) once quarantine is cleared **(S)**
- [ ] Visual comparison: generated PDF vs a document made by hand in Word with the same template **(S)**

## M3 — LiveView UI

- [x] Route `live "/", DocumentLive.New` **(S)** — replaces the generated PageController home
- [x] Layout: left = input (tabs: *Paste text* / *Upload file*), right = preview **(M)**
- [x] Template picker (Basic / Advanced / Letterhead) with dynamic metadata form using `<.input>` **(M)** — Advanced/Letterhead preview only; downloads disabled with a notice until M5/M6
- [x] `allow_upload(:source, accept: ~w(.txt .md .docx .pdf), max_file_size: 20MB)` **(S)** — `.md`/`.txt` load into the editor; `.docx`/`.pdf` show "not supported yet" until M4
- [x] `Docgen.Render.Html` — IR → preview HTML with GS1-like CSS (navy `#002C6C` headings, orange `#F26334` title band, Verdana) **(M)**
- [x] Live preview updates on text change (debounced) **(S)**
- [x] Download controller: `GET /documents/:token/download` served from `Docgen.Store` (ETS, random token per file, 30 min TTL, periodic sweep); triggered via `push_event` + colocated `.Download` hook **(M)**
- [x] Loading state while PDF converts (`start_async`); flash on errors **(S)**
- [x] Warnings panel for low-confidence ingest **(S)** — plain-text heading guesses, unsupported template
- [x] LiveView tests for paste → preview → download flow **(M)** — also upload, sample, template switch, PDF error; `ConnCase` tests can opt out of the DB with `@moduletag db: false`
- [ ] Manual browser check (`mix phx.server`) — not possible from the sandbox (can't bind a port) **(S)**

## M4 — DOCX & PDF input

- [x] `Docgen.Ingest.Docx` — parse source `document.xml`: paragraphs, runs (b/i/u), headings by style name/outline level, lists via `w:numPr`, tables **(L)** — also hyperlinks, tracked changes (ins kept, del dropped), content controls, merged cells, code/quote/caption styles; underline has no IR form and is dropped; warnings for footnotes, comments, text boxes
- [x] Safe XML parsing (`Docgen.Ingest.Xml`, SAX-based — no atoms from input, DOCTYPE rejected) and zip-bomb limits (200 MB total / 50 MB per part) **(M)**
- [x] Read source `styles.xml` to resolve custom heading styles to levels **(M)** — via `basedOn` chains and outline levels; "List Bullet 2"-style names set nesting
- [x] Extract embedded images (`word/media`) into `{:image, ...}` blocks **(M)** — IR image is now `%{data, content_type, width, height}`; rendered into the `.docx` (scaled to text width) and the preview
- [x] `Docgen.Ingest.Pdf` — `pdftohtml -xml` to get text + font sizes; cluster font sizes → heading levels; join lines into paragraphs; detect bullets **(L)** — also strips running headers/footers and page numbers, rejoins hyphenation, continues paragraphs across pages; no tables/images yet; copy-restricted PDFs are refused (no `-nodrm`)
- [x] Mark PDF ingest as low confidence; surface in UI **(S)**
- [x] Fixture files + tests for each ingest path **(M)** — fixtures are generated in tests (`Docgen.DocxBuilder`, `Docgen.PdfBuilder`) instead of binary files
- [x] Imports are editable: IR → Markdown (`Docgen.Render.Markdown`, round-trips exactly), images kept as `docgen-image:N` references; upload runs in `start_async` with progress + error messages **(M)**
- [x] `Docgen.ingest/3` for all formats; `mix docgen.render` accepts `.docx`/`.pdf` **(S)**
- [ ] Try real-world files (Word-authored reports, multi-column PDFs) and tune heuristics **(M)**

## M5 — GS1 Advanced template

- [x] Style map for Advanced (`GS1Title1–4`, `GS1Body`, `GS1Bullet1–4`, `GS1List1–4`, `GS1Table*`, `GS1Note`, `GS1Important`, `GS1CodeBlock`, captions) **(M)** — `StyleMap` now holds styles + layout options; numbered lists restart the template's own list definition; inline code uses `GS1Code`; headings are auto-numbered, so levels are normalised to start at 1
- [x] Keep the template's front matter (cover, Document Summary, Contributors, Log of Changes, Disclaimer, TOC heading) and replace only the sample content **(M)**
- [x] Fill cover page placeholders ("GS1 Document Name", "GS1 Document Type", "Optional Description") **(M)** — sets `docProps/custom.xml` and rewrites cached `DOCPROPERTY` results (incl. nested `IF` fields) in body, headers and footers; also version, status, date
- [x] Cover graphic option (choose from template media / industry icons in assets folder) **(M)** — corporate visual (default), none, or one of 46 industry icons bundled in `priv/templates/icons`
- [x] Table of contents field (`TOC \o "1-3"`) + update on PDF conversion **(M)** — bookmarked headings, cached entries with `PAGEREF`s, `updateFields` so Word refreshes page numbers; PDF export runs twice and fills page numbers via `pdftotext` (`Docgen.Convert.TocPages`)
- [ ] Verify the two-pass PDF and TOC with real LibreOffice (only tested with fakes; LibreOffice still quarantined) **(S)**
- [ ] Open an Advanced `.docx` in Word: check the update-fields prompt, cover, TOC and page numbers **(S)**
- [x] Markdown extensions for notes: `> **Note:**` → `GS1Note`, `> **Important:**` → `GS1Important` **(S)** — new IR block `{:important, inlines}`
- [x] Figure/table captions **(S)** — `Table: …` next to a table → `{:caption, :table, …}`; image alt text → figure caption; Advanced numbers them with `SEQ` fields ("Table 1:", "Figure 1:")
- [x] Importing GS1 Advanced `.docx` files skips the front matter and TOC and reads name/type/description from custom properties; `numStyleLink` numbering resolved **(S)**
- [x] Preview for Advanced: cover block, contents, numbered headings; UI fields for type/description/version/status/date/cover; `mix docgen.render --template advanced` **(S)**

## M6 — GS1 Letterhead template

- [x] Map letterhead content controls (`<w:sdt>`: sender name/address, date, recipient) to `meta` fields **(M)** — all 11 controls (also subject, salutation, closing, signature name/title) are unwrapped into plain text; the body control holds the rendered document; generated bullets and bold headings since the template has no list/heading styles
- [x] Metadata form fields for letter **(S)** — plus a letter-layout preview
- [x] Option: "hide letterhead graphics" for pre-printed paper **(S)**
- [ ] Open a generated letter in Word and check layout/fonts **(S)**

## M7 — Polish & deploy

- [x] AI document planner: recommend Basic/Advanced/Letterhead and explain the choice; use OpenAI Structured Outputs when configured, with a deterministic fallback **(M)**
- [x] Detect explicit percentage data and recommend an appropriate donut/bar graph without inventing values **(S)**
- [x] Let the planner select and apply a relevant official visual from the GS1 Word asset pack **(S)**
- [x] Make AI planning the default and automatically apply its template/asset recommendation while preserving explicit manual choices **(M)**
- [x] Streamline Advanced reports by hiding Document Version and Log of Changes; mirror summary, contributors, disclaimer, TOC, fonts and tables in preview **(M)**
- [x] Reconstruct flattened percentage-rating tables during AI refinement and show Advanced preview as complete document pages **(M)**
- [x] Use the generated PDF as the exact preview, show selected GS1 icon imagery, and remove Summary/Contributors from Advanced reports **(M)**
- [x] Preserve manual cover overrides and provide an explicit return to content-based AI cover selection **(S)**
- [x] Enforce the Advanced Verdana/Arial font policy and Times New Roman Bold square markers across DOCX and preview **(S)**
- [x] Prevent macOS LibreOffice headless font substitution by using its native CoreText-backed VCL backend **(S)**
- [ ] Generate editable graph blocks in preview, DOCX and PDF after the user accepts a recommendation **(L)**
- [ ] Add planner eval fixtures for reports, specifications, letters, percentage comparisons and time series **(M)**

- [x] Localisation settings: upload MO logo, address, footer text → swap `word/media` image + footer XML **(L)** — app-wide via env vars (`DOCGEN_ORG_NAME`, `DOCGEN_ORG_WEBSITE`, `DOCGEN_ORG_ADDRESS`, `DOCGEN_LOGO_PATH`), applied to all templates (`Docgen.Render.Docx.Branding`); a settings UI needs accounts (open question)
- [x] Persist generated documents (Ecto schema: source, template, meta, files) + history page **(M)** — `generated_documents` table, recorded on each .docx download (best-effort), `/history` with .docx/PDF downloads and delete
- [ ] Run the migration and `Docgen.HistoryTest` once Postgres is back **(S)**
- [x] Dockerfile with LibreOffice, poppler, fonts (Verdana/brand font) **(M)** — hand-written (release generator couldn't reach bob.hex.pm); `mix phx.gen.release` files added
- [ ] Build and run the Docker image (Docker daemon wasn't running here; confirm the builder image tag) **(S)**
- [x] Clean up temp files (periodic job) **(S)** — `Docgen.Janitor`; the download store already expires entries
- [x] Update `README.md` with setup (system deps) and usage **(S)**
- [ ] `mix precommit` passes **(S)** — compile (warnings as errors), unused deps and format pass; the test step needs Postgres

## M8 — GS1 PowerPoint presentations

- [x] Bundle `GS1_Template_2026.pptx` as `priv/templates/presentation.pptx` **(S)**
- [x] `Docgen.Render.Pptx.Deck` — IR → slide plan (title, agenda, dividers, content, table, image; pagination with "(continued)") **(M)**
- [x] `Docgen.Render.Pptx` — strip the 48 sample slides, prune unreachable parts, write slides on the GS1 layouts; logo/organisation localisation **(M)**
- [x] PDF export via LibreOffice (`Convert.Pdf.from_office/3`), history and `mix docgen.render --template presentation` **(S)**
- [x] UI: Document / Presentation switch, presentation fields, slide-card HTML preview **(M)**
- [ ] Manual check: open a generated deck in PowerPoint and Keynote; compare PDF output (LibreOffice was sandboxed during development) **(S)**

---

## Open questions

- [ ] Confirm rights to use GS1 branding/templates
- [ ] Is the GS1 brand font available/licensed for the server?
- [ ] Which template is the priority after Basic — Advanced or Letterhead?
- [ ] Need user accounts/history, or stateless generate-and-download?
