# Docgen — GS1-Styled Document Generator

## Goal

A web UI (Phoenix LiveView) where a user pastes text or uploads a `.txt`, `.md`,
`.docx` or `.pdf` file and gets back a document formatted in the official GS1
house style — as both **Word (.docx)** and **PDF**.

The style comes directly from the official templates in
`GS1_Template_MSWord_A4_2025/`, so output matches what GS1 staff would produce
by hand in Word.

---

## Source material (what's in the template folder)

| File | Purpose | Used by us? |
|---|---|---|
| `GS1 Basic.dotm` | Simple multi-purpose document, no cover page | Yes — v1 default |
| `GS1 Advanced.dotm` | Technical document with cover page, TOC, rich style set | Yes — v2 |
| `GS1 Letterhead.dotm` | Correspondence (sender, recipient, date fields) | Yes — v3 |
| `GS1.dotm` | Word toolbar add-in | No |
| `GS1 MSWord Localisation.dotm` | Macro that injects MO logo/contact info | No (we replicate via settings) |
| `GS1_Template_MSWord_Assets_2015-05-18/` | Industry icons, corporate visual | Yes — optional cover imagery |
| `GS1_Template_Instructions_MSWord.pdf` | Human instructions | Reference only |

A `.dotm` is a zip (OOXML). The parts we care about:

- `word/styles.xml` — all paragraph/character/table styles
- `word/theme/theme1.xml` — brand colours and fonts
- `word/header*.xml`, `word/footer*.xml` + `word/media/*` — logo, page numbers
- `word/numbering.xml` — bullet/number list definitions
- `word/document.xml` — the body we **replace** with generated content
- `word/vbaProject.bin` etc. — macros, which we **strip** (output is `.docx`, not `.docm`)

### Key styles

**Basic:** `Title`, `Subtitle`, `Heading1`–`Heading7`, `BodyText`, `ListBullet`,
`ListBullet2/3`, `ListNumber`, `GS1BTitle`, `GS1BSubtitle`, `GS1BHeading1/2`,
`GS1BBodyText1/2`.

**Advanced:** `GS1Title1–4`, `GS1Body`, `GS1BodyIndent1–3`, `GS1Bullet1–4`,
`GS1List1–4`, `GS1Table`, `GS1TableHeading`, `GS1TableText`, `GS1Note`,
`GS1Important`, `GS1Code`, `GS1CodeBlock`, `GS1CaptionFigure`,
`GS1CaptionTable`, `GS1TOCHeading`, `GS1Disclaimer`. Cover page placeholders:
"GS1 Document Name", "GS1 Document Type", "Optional Description".

**Letterhead:** content controls (`<w:sdt>`) for Sender's Name, Sender's
Address, Date, Recipient, etc.

### Brand palette (from theme1.xml)

| Colour | Hex |
|---|---|
| GS1 Blue (navy) | `#002C6C` |
| GS1 Orange | `#F26334` |
| Link blue | `#008DBD` |
| Sky | `#00B6DE` |
| Green | `#7AC143` |
| Dark grey | `#454545` |
| Light grey | `#B1B3B3` |
| Accents | `#FBB034`, `#F05587`, `#BF83B9` |

Body font in the templates: Verdana (with the GS1 brand font where licensed).

---

## Architecture

```
┌───────────────────────── LiveView UI ─────────────────────────┐
│ paste text / upload file → choose template → fill metadata    │
│ → live HTML preview → download .docx / .pdf                   │
└───────────────┬───────────────────────────────────────────────┘
                │
        ┌───────▼────────┐
        │   Ingest       │  Docgen.Ingest.{Text, Markdown, Docx, Pdf}
        │  file → IR     │
        └───────┬────────┘
                │  Docgen.Document (intermediate representation)
        ┌───────▼────────┐
        │   Render       │  Docgen.Render.Docx  (template + IR → .docx)
        │                │  Docgen.Render.Html  (IR → preview HTML)
        └───────┬────────┘
                │ .docx
        ┌───────▼────────┐
        │   Convert      │  Docgen.Convert.Pdf  (LibreOffice headless)
        └────────────────┘
```

### 1. Intermediate representation (IR)

Every input is normalised into one structure so renderers never care where
content came from:

```elixir
%Docgen.Document{
  template: :basic | :advanced | :letterhead,
  meta: %{title: "...", subtitle: "...", doc_type: "...", date: ~D[...],
          sender: ..., recipient: ...},
  blocks: [
    {:heading, level, inlines},
    {:paragraph, inlines},
    {:bullet_list, level, [items]},
    {:numbered_list, level, [items]},
    {:table, header_rows, rows},
    {:note, inlines},          # GS1Note
    {:important, inlines},     # GS1Important
    {:caption, :table, inlines},  # caption of the following table
    {:code_block, text},
    {:image, %{data: binary, content_type: "image/png", width: emu, height: emu}, caption},
    :page_break
  ]
}
# inlines: [{:text, "..."}, {:bold, [...]}, {:italic, [...]}, {:link, url, [...]}, {:code, "..."}]
```

### 2. Ingest

| Input | Approach | Fidelity |
|---|---|---|
| Plain text | Blank-line-separated paragraphs; heuristics for headings (short line, no trailing punctuation) and bullets (`-`, `*`, `•`, `1.`) | Good |
| Markdown | `Earmark` / `MDEx` AST → IR | Excellent |
| `.docx` | Unzip, parse `document.xml` (`Saxy` / `SweetXml`); map source styles (`Heading1`, `ListParagraph`, tables, bold/italic runs) → IR | Very good |
| `.pdf` | `pdftotext -layout` (poppler) or `pdftohtml -xml` for font sizes; infer headings from font size/weight | Fair — flag for user review |

### 3. Render DOCX (the core)

1. Copy the chosen `.dotm` from `priv/templates/`.
2. Unzip in memory (`:zip`).
3. Replace the body of `word/document.xml` with generated `<w:p>` / `<w:tbl>`
   XML, each paragraph using `<w:pStyle w:val="GS1..."/>`. Keep the final
   `<w:sectPr>` so headers/footers/margins survive.
4. Fill cover/letterhead placeholders from `meta`.
5. Strip macros: remove `vbaProject.bin`, `vbaData.xml`, signatures, their
   rels, and `customUI`; change content type from
   `macroEnabledTemplate` → `wordprocessingml.document.main+xml`.
6. Re-zip → `.docx`.

A per-template **style map** config decides which GS1 style each IR block uses
(e.g. `{:heading, 1}` → `Heading1` in Basic, `GS1Title1` in Advanced).

### 4. Convert to PDF

`soffice --headless --convert-to pdf` against the generated `.docx`, run via
`System.cmd/3` in a temp dir with a timeout and a pool limit (LibreOffice is
not concurrency-safe per profile — use a unique `-env:UserInstallation` per
job, or a single worker queue). Alternative for deployment: a Gotenberg
container called with `Req`.

### 5. Preview

`Docgen.Render.Html` renders the IR with Tailwind/CSS classes that imitate the
GS1 styles (navy headings, orange title bar, Verdana). Fast, updates live as
the user edits; the downloaded PDF is the source of truth.

### 6. UI (LiveView)

- `/` — **New document**: textarea or drag-and-drop upload (`allow_upload`),
  template picker, metadata form (fields depend on template).
- Right pane: live preview.
- Buttons: *Download .docx*, *Download .pdf*.
- Warnings banner when ingest is low-confidence (PDF input, unmapped styles).
- Optional later: history of generated documents (Postgres + Ecto), block
  editor to fix headings detected wrongly.

### 7. AI document planning

`Docgen.AI.Planner` is an advisory step between ingest and render. It uses a
schema-constrained response to recommend Basic, Advanced or Letterhead and to
identify explicit data that would benefit from a bar, line or donut graph.
Every graph recommendation includes a source excerpt; the planner must never
invent numbers. Recommendations remain reviewable and are only applied after
the user accepts them. Without `OPENAI_API_KEY`, conservative local rules keep
template and percentage detection available.

The planner also receives the allow-listed catalogue from
`GS1_Template_MSWord_A4_2025/GS1_Template_MSWord_Assets_2015-05-18`. It may
select the corporate visual or one of the official industry icons for an
Advanced cover. Runtime rendering reads the deployment-safe copies in
`priv/templates/icons`; arbitrary paths or model-generated asset names are
rejected.

The UI defaults to **Auto — AI recommended**. After pasted content or an
import changes, it analyses the current document and immediately uses the
recommended template and official cover asset for preview and download.
Choosing Basic, Advanced or Letterhead explicitly disables automatic
switching, so a user's manual choice always wins.

Before planning, `Docgen.AI.Refiner` repairs conservative layout patterns in
editable Markdown. In particular, PDF imports that flatten an `Area / Rating /
Comment` table into consecutive percentage paragraphs are reconstructed as a
real table without changing or inventing values. Advanced HTML preview uses
separate cover, front-matter, contents and content page surfaces so the full
download structure remains visible while editing.

When LibreOffice is available, the primary preview is the generated PDF itself
served inline from the same short-lived store as downloads. This makes fonts,
pagination, headers, footers, tables and selected GS1 imagery identical to the
download. HTML page surfaces remain only as a conversion fallback. Advanced
reports omit Document Summary, Contributors, Document Version and Log of
Changes, retaining the disclaimer, contents and report body.

Advanced output has an explicit font policy: Verdana for body copy, titles,
headings and table headers; Arial for table body, TOC, footer and page-number
styles; and Times New Roman Bold for square bullet markers in the HTML
fallback. The PDF converter embeds available fonts, so production hosts must
have properly licensed Verdana, Arial and Times New Roman installations.

Cover selection starts in AI mode and is grounded in the document text. A
user changing the Cover graphic field creates a persistent manual override;
subsequent analysis may still explain its recommendation but cannot overwrite
the chosen visual. “Use AI visual” explicitly returns control to the planner.

---

## Dependencies

**Hex:** `saxy` or `sweet_xml` (XML), `mdex` or `earmark` (Markdown),
optionally `oban` (background PDF jobs).

**System:**
- LibreOffice (`brew install --cask libreoffice`; `soffice` on PATH)
- Poppler (`brew install poppler`) for PDF input
- Fonts: Verdana, plus the GS1 brand font if licensed — must be installed on
  the machine running LibreOffice, or PDFs fall back to substitute fonts.

---

## Risks & open questions

- **Brand usage rights** — confirm the organisation is permitted to use GS1
  branding/templates (intended for GS1 Member Organisations).
- **Fonts** — PDF fidelity depends on fonts installed on the server.
- **PDF input quality** — PDFs carry no semantic structure; expect manual
  touch-up.
- **LibreOffice vs Word rendering** — minor layout differences are possible;
  compare against Word-exported samples.
- **Localisation** — MO logo/address currently baked into templates; later
  make these configurable (replace `word/media/image*.png` and footer text).

## Milestones

1. **M1** — Text/Markdown → GS1 Basic `.docx` (download works, opens cleanly in Word).
2. **M2** — PDF export via LibreOffice.
3. **M3** — LiveView UI with live preview and uploads.
4. **M4** — `.docx` and `.pdf` input.
5. **M5** — GS1 Advanced (cover page, TOC, tables, notes, code).
6. **M6** — GS1 Letterhead.
7. **M7** — Polish: history, localisation settings, deployment (Docker with LibreOffice + fonts).

See `tasks.md` for the task breakdown.
