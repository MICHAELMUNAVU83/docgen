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
    assert xml =~ "September 2026"
    assert xml =~ ">Ratified<"

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

    assert parts["word/settings.xml"] =~ ~s(<w:updateFields w:val="true"/>)

    starts = Regex.scan(~r/<w:bookmarkStart[^>]*w:id="(\d+)"/, xml, capture: :all_but_first)
    ends = Regex.scan(~r/<w:bookmarkEnd[^>]*w:id="(\d+)"/, xml, capture: :all_but_first)
    assert Enum.sort(starts) == Enum.sort(ends)
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

    [_, abstract] =
      Regex.run(~r/<w:num w:numId="28"[^>]*><w:abstractNumId w:val="(\d+)"/, numbering)

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
end
