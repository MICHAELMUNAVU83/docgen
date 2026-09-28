defmodule Docgen.Render.DocxAdvancedTest do
  use ExUnit.Case, async: true

  import Docgen.DocxHelpers

  @markdown """
  ## Introduction

  Some **bold** text and `code`.

  ### Scope

  1. first
  2. second

  Table: Identifier types

  | Key | Digits |
  | --- | --- |
  | GTIN | 14 |

  ## Details

  > **Note:** check this.

  > **Important:** never reuse a GTIN.

  ![Logo](docgen-image:1)
  """

  @meta %{
    title: "Supplier Guide",
    doc_type: "Guideline",
    description: "How suppliers onboard & share data",
    version: "2.1",
    status: "Ratified",
    date: "2026-09-28"
  }

  defp render(meta \\ @meta, opts \\ []) do
    image = Docgen.Image.new("logo.png", Docgen.DocxBuilder.png(40, 20))

    doc =
      Docgen.parse(@markdown, :markdown, template: :advanced, meta: meta, images: %{"1" => image})

    {:ok, docx} = Docgen.Render.Docx.render(doc, opts)
    unzip!(docx)
  end

  defp style_block(styles, id) do
    [block] =
      Regex.run(
        ~r{<w:style\b(?=[^>]*\bw:styleId="#{Regex.escape(id)}")[^>]*>.*?</w:style>}s,
        styles
      )

    block
  end

  setup_all do
    %{parts: render()}
  end

  test "every XML part is well-formed and macros are gone", %{parts: parts} do
    for {name, data} <- parts, Path.extname(name) in ~w(.xml .rels) do
      assert well_formed?(data), "#{name} is not well-formed"
    end

    refute Enum.any?(Map.keys(parts), &(&1 =~ ~r/vba|customUI|customizations/))
  end

  test "keeps the template's front matter and drops its sample content", %{parts: parts} do
    xml = parts["word/document.xml"]

    for text <- ["Disclaimer", "Table of Contents"] do
      assert xml =~ text
    end

    refute xml =~ "Document Summary"
    refute xml =~ "Contributors"
    refute xml =~ "Document Version"
    refute xml =~ "Log of Changes"
    refute parts["word/footer2.xml"] =~ "Release "

    refute xml =~ "_Toc195537005"
    assert length(:binary.matches(xml, "<w:sectPr")) == 2
  end

  test "cover, summary, header and footer fields show the metadata", %{parts: parts} do
    for part <- ["word/document.xml", "word/header2.xml", "word/footer2.xml"] do
      refute parts[part] =~ ~r/GS1 Document Name|GS1 Document Type|Optional Description|May 2025/,
             "#{part} still shows placeholder text"
    end

    xml = parts["word/document.xml"]
    assert xml =~ "Supplier Guide"
    assert xml =~ "How suppliers onboard &amp; share data"
    # Release, status and date are not shown.
    refute xml =~ "September 2026"
    refute xml =~ ">Ratified<"

    custom = parts["docProps/custom.xml"]
    assert custom =~ ~s(name="GS1 DocName"><vt:lpwstr>Supplier Guide</vt:lpwstr>)
    assert custom =~ ~s(name="GS1 Version"><vt:lpwstr>2.1</vt:lpwstr>)
    assert custom =~ ~s(name="GS1 Date"><vt:lpwstr>September 2026</vt:lpwstr>)
  end

  test "blank metadata falls back to sensible defaults" do
    custom = render(%{})["docProps/custom.xml"]
    assert custom =~ ~s(name="GS1 DocName"><vt:lpwstr>Untitled document</vt:lpwstr>)
    assert custom =~ ~s(name="GS1 Description"><vt:lpwstr></vt:lpwstr>)
    assert custom =~ ~s(name="GS1 Status"><vt:lpwstr>Draft</vt:lpwstr>)
  end

  test "a TOC field lists bookmarked, numbered headings", %{parts: parts} do
    xml = parts["word/document.xml"]
    assert xml =~ ~s(TOC \\o &quot;1-3&quot;) or xml =~ ~s(TOC \\o "1-3")

    for {n, number, text} <- [{1, "1", "Introduction"}, {2, "1.1", "Scope"}, {3, "2", "Details"}] do
      assert xml =~ ~s(<w:hyperlink w:anchor="_TocDocgen#{n}")
      assert xml =~ ~s(<w:bookmarkStart w:id="#{90_000 + n}" w:name="_TocDocgen#{n}"/>)

      assert xml =~
               ~r{_TocDocgen#{n}" w:history="1"><w:r><w:t xml:space="preserve">#{Regex.escape(number)}</w:t></w:r><w:r><w:tab/></w:r><w:r><w:t xml:space="preserve">#{text}</w:t>}
    end

    refute parts["word/settings.xml"] =~ "<w:updateFields"

    starts = Regex.scan(~r/<w:bookmarkStart[^>]*w:id="(\d+)"/, xml, capture: :all_but_first)
    ends = Regex.scan(~r/<w:bookmarkEnd[^>]*w:id="(\d+)"/, xml, capture: :all_but_first)
    assert Enum.sort(starts) == Enum.sort(ends)
  end

  test "headings contain stable visible numbers and suppress template numbering", %{parts: parts} do
    xml = parts["word/document.xml"]

    for number <- ["1", "1.1", "2"] do
      assert xml =~
               ~r{<w:pStyle w:val="Heading\d+"/><w:numPr><w:numId w:val="0"/></w:numPr>.*?<w:t xml:space="preserve">#{Regex.escape(number)}</w:t></w:r><w:r><w:tab/></w:r>}s
    end
  end

  test "an empty document does not emit an empty TOC message" do
    doc = Docgen.parse("", :markdown, template: :advanced, meta: @meta)
    {:ok, docx} = Docgen.Render.Docx.render(doc)
    xml = unzip!(docx)["word/document.xml"]

    refute xml =~ "No table of contents entries found."
  end

  test "headings start at level 1 even when the Markdown starts at ##", %{parts: parts} do
    styles = paragraph_styles(parts["word/document.xml"])
    assert "Heading1" in styles
    assert "Heading2" in styles
    refute "Heading3" in styles
  end

  test "TOC page numbers are filled when known" do
    xml = render(@meta, toc_pages: %{"_TocDocgen1" => 4, "_TocDocgen3" => 7})["word/document.xml"]
    assert xml =~ ~r{PAGEREF _TocDocgen1 \\h </w:instrText>.*?<w:t xml:space="preserve">4</w:t>}s
    assert xml =~ ~r{PAGEREF _TocDocgen3 \\h </w:instrText>.*?<w:t xml:space="preserve">7</w:t>}s
  end

  test "blocks use GS1 Advanced styles", %{parts: parts} do
    xml = parts["word/document.xml"]
    styles = paragraph_styles(xml)

    for style <-
          ~w(GS1Body GS1List1 GS1CaptionTable GS1Note GS1Important GS1CaptionFigure GS1TableHeading GS1TableText) do
      assert style in styles, "missing #{style}"
    end

    assert xml =~ ~s(<w:tblStyle w:val="GS1Table"/>)
    assert xml =~ ~s(<w:rStyle w:val="GS1Code"/>)
    # The table style provides the header look; no hard-coded shading.
    refute xml =~ ~s(w:fill="002C6C")
  end

  test "performance tables give the rating a narrow column and the comment room" do
    markdown = "| Area | Rating | Comment |\n| --- | --- | --- |\n| Quality | 90% | Strong work |"
    doc = Docgen.parse(markdown, :markdown, template: :advanced, meta: @meta)
    {:ok, docx} = Docgen.Render.Docx.render(doc)
    xml = unzip!(docx)["word/document.xml"]

    widths =
      ~r{<w:tblGrid>(.*?)</w:tblGrid>}s
      |> Regex.scan(xml, capture: :all_but_first)
      |> Enum.map(fn [grid] ->
        Regex.scan(~r{<w:gridCol w:w="(\d+)"/>}, grid, capture: :all_but_first)
      end)
      |> Enum.find(&(length(&1) == 3))

    assert [[area], [rating], [comment]] = widths
    assert String.to_integer(area) > String.to_integer(rating)
    assert String.to_integer(comment) > String.to_integer(area)
  end

  test "embeds the explicit GS1 font policy in document styles", %{parts: parts} do
    styles = parts["word/styles.xml"]

    for style <- ~w(Normal GS1Body Heading1 GS1TableHeading) do
      assert style_block(styles, style) =~ ~s(w:ascii="Verdana")
    end

    for style <- ~w(GS1TableText Footer PageNumber TOC1) do
      assert style_block(styles, style) =~ ~s(w:ascii="Arial")
    end
  end

  test "captions are numbered with SEQ fields", %{parts: parts} do
    xml = parts["word/document.xml"]

    assert xml =~
             ~r{Table </w:t></w:r>.*?SEQ Table \\\* ARABIC .*?>1</w:t>.*?: </w:t></w:r><w:r><w:t xml:space="preserve">Identifier types}s

    assert xml =~ ~r{Figure </w:t></w:r>.*?SEQ Figure \\\* ARABIC .*?>1</w:t>.*?Logo}s
  end

  test "numbered lists restart the template's GS1 list definition", %{parts: parts} do
    numbering = parts["word/numbering.xml"]

    # numId 28 links to the "ListStyleNumbers" style; restarts use the
    # definition declaring that style, which holds the levels.
    [_, abstract] =
      Regex.run(
        ~r{<w:abstractNum\b[^>]*w:abstractNumId="(\d+)"[^>]*>(?:(?!</w:abstractNum>).)*<w:styleLink w:val="ListStyleNumbers"/>}s,
        numbering
      )

    [num_id] =
      Regex.run(
        ~r/<w:numId w:val="(\d+)"\/><\/w:numPr><\/w:pPr><w:r><w:t xml:space="preserve">first/,
        parts["word/document.xml"],
        capture: :all_but_first
      )

    assert numbering =~
             ~s(<w:num w:numId="#{num_id}"><w:abstractNumId w:val="#{abstract}"/><w:lvlOverride w:ilvl="0"><w:startOverride w:val="1"/>)
  end

  describe "cover graphic" do
    test "defaults to the corporate visual" do
      assert render()["word/header3.xml"] =~ ~s(<wp:extent cx="6372000" cy="1710000"/>)
    end

    test "can be removed" do
      header = render(Map.put(@meta, :cover, "none"))["word/header3.xml"]
      refute header =~ "GS1 Cover Page Image"
      assert header =~ "GS1 Cover Page Logo"
      assert well_formed?(header)
    end

    test "can be an industry icon, sized square" do
      parts = render(Map.put(@meta, :cover, "retail"))
      {:ok, icon} = Docgen.Template.cover_icon("retail")

      assert parts["word/media/image6.png"] == icon
      assert parts["word/header3.xml"] =~ ~s(<wp:extent cx="1710000" cy="1710000"/>)
    end

    test "unknown icons keep the default" do
      parts = render(Map.put(@meta, :cover, "../../etc/passwd"))
      assert parts["word/header3.xml"] =~ ~s(<wp:extent cx="6372000" cy="1710000"/>)
    end
  end

  test "Advanced documents import back to the same content" do
    image = Docgen.Image.new("logo.png", Docgen.DocxBuilder.png(40, 20))

    original =
      Docgen.parse(@markdown, :markdown,
        template: :advanced,
        meta: @meta,
        images: %{"1" => image}
      )

    {:ok, docx} = Docgen.to_docx(original)
    {:ok, imported} = Docgen.ingest(docx, :docx)

    assert imported.meta == Map.take(@meta, [:title, :doc_type, :description])
    assert imported.blocks == Docgen.Document.normalize_headings(original.blocks)
  end

  test "numbered headings keep the template's hanging indent", %{parts: parts} do
    assert parts["word/document.xml"] =~
             ~s(<w:pStyle w:val="Heading1"/><w:numPr><w:numId w:val="0"/></w:numPr><w:tabs><w:tab w:val="left" w:pos="864"/></w:tabs><w:ind w:left="864" w:hanging="864"/>)
  end

  test "headings below the contents depth are numbered the same way" do
    markdown = "# One\n\n## Two\n\n### Three\n\n#### Four\n\n##### Five"
    doc = Docgen.parse(markdown, :markdown, template: :advanced, meta: @meta)
    {:ok, docx} = Docgen.Render.Docx.render(doc)
    xml = unzip!(docx)["word/document.xml"]

    for {level, number, indent} <- [{4, "1.1.1.1", 864}, {5, "1.1.1.1.1", 1008}] do
      assert xml =~
               ~r{<w:pStyle w:val="Heading#{level}"/><w:numPr><w:numId w:val="0"/></w:numPr><w:tabs><w:tab w:val="left" w:pos="#{indent}"/>.*?<w:t xml:space="preserve">#{Regex.escape(number)}</w:t>}
    end

    refute xml =~ "_TocDocgen4\""
  end

  test "contents entries leave room for the heading number" do
    markdown = "# One\n\n## Two\n\n### Three"
    doc = Docgen.parse(markdown, :markdown, template: :advanced, meta: @meta)
    {:ok, docx} = Docgen.Render.Docx.render(doc)
    xml = unzip!(docx)["word/document.xml"]

    for {level, pos} <- [{1, 504}, {2, 1170}, {3, 1710}] do
      assert xml =~
               ~s(<w:pStyle w:val="TOC#{level}"/><w:tabs><w:tab w:val="left" w:pos="#{pos}"/>)
    end
  end

  test "typed heading numbers give way to the template's numbering" do
    doc =
      Docgen.parse("# 1. Background\n\n# 2. Scope", :markdown, template: :advanced, meta: @meta)

    {:ok, docx} = Docgen.Render.Docx.render(doc)
    xml = unzip!(docx)["word/document.xml"]

    assert xml =~ ~r{>2</w:t></w:r><w:r><w:tab/></w:r><w:r><w:t xml:space="preserve">Scope</w:t>}
    refute xml =~ "2. Scope"
  end

  test "without headings the contents heading gives way to a page break" do
    doc = Docgen.parse("Just a paragraph.", :markdown, template: :advanced, meta: @meta)
    {:ok, docx} = Docgen.Render.Docx.render(doc)
    parts = unzip!(docx)
    xml = parts["word/document.xml"]

    refute xml =~ "Table of Contents"
    assert xml =~ ~r{<w:br w:type="page"/></w:r></w:p><w:p><w:pPr><w:pStyle w:val="GS1Body"/>}
    assert well_formed?(xml)
  end

  test "release, status and date are removed from the cover and footer", %{parts: parts} do
    footer = parts["word/footer2.xml"]

    for text <- [
          "Release ",
          "GS1 Version",
          "GS1 Status",
          "GS1 Date",
          "Ratified",
          "September 2026"
        ] do
      refute footer =~ text
    end

    assert footer =~ "AISBL"
    assert footer =~ "NUMPAGES"
    assert well_formed?(footer)

    xml = parts["word/document.xml"]
    refute xml =~ "Release "

    # The cover's layout table keeps every row, and every cell a paragraph.
    refute xml =~ ~r{<w:tcPr>(?:(?!</w:tc>).)*?</w:tcPr>\s*</w:tc>}s
    [cover] = Regex.run(~r{<w:tbl>.*?</w:tbl>}s, xml)
    assert length(Regex.scan(~r{<w:tr\b}, cover)) == 3
  end
end
