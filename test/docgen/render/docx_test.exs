defmodule Docgen.Render.DocxTest do
  use ExUnit.Case, async: true

  import Docgen.DocxHelpers

  alias Docgen.Document

  @markdown """
  ---
  title: GS1 Report
  subtitle: Draft & <review>
  ---

  ## Introduction

  Text with **bold**, *italic*, `code` and a [link](https://www.gs1.org/?a=1&b=2).

  - one
    - nested
  - two

  1. first
  2. second

  Between the lists.

  1. restarts

  | Key | Value |
  |-----|-------|
  | GTIN | 14 digits |

  > A note.

  ```
  x < y && z
  ```
  """

  setup do
    {:ok, docx} = @markdown |> Docgen.parse(:markdown) |> Docgen.to_docx()
    %{parts: unzip!(docx)}
  end

  test "every XML part is well-formed", %{parts: parts} do
    for {name, data} <- parts, Path.extname(name) in ~w(.xml .rels) do
      assert well_formed?(data), "#{name} is not well-formed"
    end
  end

  test "no macro parts remain and the main part is a document", %{parts: parts} do
    refute Enum.any?(Map.keys(parts), &(&1 =~ ~r/vba|customUI|customizations/))
    assert parts["[Content_Types].xml"] =~ "wordprocessingml.document.main+xml"
    refute parts["[Content_Types].xml"] =~ "macroEnabled"
  end

  test "body uses GS1 Basic styles in order", %{parts: parts} do
    assert paragraph_styles(parts["word/document.xml"]) == ~w(
             GS1BTitle GS1BSubtitle Heading1 BodyText
             ListBullet ListBullet2 ListBullet
             ListNumber ListNumber BodyText ListNumber
             NoSpacing NoSpacing NoSpacing NoSpacing
             BodyText2 NoSpacing
           )
  end

  test "text is escaped", %{parts: parts} do
    xml = parts["word/document.xml"]
    assert xml =~ "Draft &amp; &lt;review&gt;"
    assert xml =~ "x &lt; y &amp;&amp; z"
  end

  test "the template's section properties survive", %{parts: parts} do
    xml = parts["word/document.xml"]
    assert xml =~ ~r{<w:footerReference [^>]*/>.*<w:headerReference [^>]*/>.*<w:titlePg/>}s
    assert length(:binary.matches(xml, "<w:sectPr")) == 1
  end

  test "hyperlinks get external relationships", %{parts: parts} do
    [id] =
      Regex.run(~r/<w:hyperlink r:id="([^"]+)"/, parts["word/document.xml"],
        capture: :all_but_first
      )

    rels = parts["word/_rels/document.xml.rels"]
    assert rels =~ ~s(Id="#{id}")
    assert rels =~ ~s(Target="https://www.gs1.org/?a=1&amp;b=2" TargetMode="External")
  end

  test "each numbered list gets its own restarting numbering instance", %{parts: parts} do
    ids =
      ~r/<w:numId w:val="(\d+)"\/>/
      |> Regex.scan(parts["word/document.xml"], capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    assert length(ids) == 2

    numbering = parts["word/numbering.xml"]

    for id <- ids do
      assert numbering =~
               ~r{<w:num w:numId="#{id}"><w:abstractNumId w:val="\d+"/><w:lvlOverride w:ilvl="0"><w:startOverride w:val="1"/>}
    end

    # All abstract definitions still precede the first <w:num>.
    {last_abstract, _} = numbering |> :binary.matches("<w:abstractNum ") |> List.last()
    {first_num, _} = :binary.match(numbering, "<w:num ")
    assert last_abstract < first_num
  end

  test "document title is set in core properties", %{parts: parts} do
    assert parts["docProps/core.xml"] =~ "<dc:title>GS1 Report</dc:title>"
  end

  test "an empty document still renders a body paragraph" do
    {:ok, docx} = Docgen.to_docx(%Document{})
    xml = unzip!(docx)["word/document.xml"]
    assert well_formed?(xml)
    assert xml =~ ~r{<w:body><w:p>.*</w:p><w:sectPr}s
  end

  test "invalid XML characters and unsafe links are dropped" do
    doc = %Document{
      blocks: [
        {:paragraph, [{:text, "bad\u0001char"}, {:link, "not a url", [text: "plain"]}]}
      ]
    }

    {:ok, docx} = Docgen.to_docx(doc)
    xml = unzip!(docx)["word/document.xml"]
    assert well_formed?(xml)
    assert xml =~ "badchar"
    refute xml =~ "w:hyperlink"
  end

  test "unknown templates are rejected" do
    assert {:error, {:unsupported_template, :nope}} = Docgen.to_docx(%Document{template: :nope})
  end

  test "images are embedded as media parts scaled to the text width" do
    png = Docgen.DocxBuilder.png(4, 2)
    wide = %{data: png, content_type: "image/png", width: 20_000_000, height: 10_000_000}
    gif = %{data: "GIF89a", content_type: "image/gif", width: nil, height: nil}

    doc = %Document{blocks: [{:image, wide, "Wide"}, {:image, gif, nil}]}
    {:ok, docx} = Docgen.to_docx(doc)
    parts = unzip!(docx)
    xml = parts["word/document.xml"]

    assert parts["word/media/docgen1.png"] == png
    assert parts["word/media/docgen2.gif"] == "GIF89a"
    assert parts["word/_rels/document.xml.rels"] =~ ~s(Target="media/docgen1.png")
    assert parts["[Content_Types].xml"] =~ ~s(<Default Extension="gif" ContentType="image/gif"/>)
    assert well_formed?(xml)

    # 10209 twips of text width × 635 EMU/twip; aspect ratio kept.
    assert xml =~ ~s(<wp:extent cx="6482715" cy="3241357"/>)
    assert xml =~ ~s(<wp:extent cx="3657600" cy="2743200"/>)
    assert xml =~ "Wide"
  end

  test "text after a list or table is spaced from it", %{parts: parts} do
    xml = parts["word/document.xml"]

    assert xml =~
             ~s(<w:pStyle w:val="BodyText"/><w:spacing w:before="120"/></w:pPr><w:r><w:t xml:space="preserve">Between the lists.)

    refute xml =~ ~r{<w:pStyle w:val="Heading\d"/><w:spacing}

    # The note follows the table.
    assert xml =~ ~r{</w:tbl><w:p><w:pPr><w:pStyle w:val="BodyText2"/><w:spacing w:before="240"/>}
  end

  test "list text matches body text and headings keep with what follows", %{parts: parts} do
    styles = parts["word/styles.xml"]

    for id <- ~w(ListBullet ListBullet2 ListBullet3 ListNumber) do
      style = style_block(styles, id)
      assert style =~ ~s(<w:sz w:val="22"/>)
      assert style =~ ~s(<w:contextualSpacing w:val="0"/>)
      refute style =~ "<w:contextualSpacing/>"
    end

    for id <- ~w(Heading1 Heading2 Heading3 Heading4) do
      assert style_block(styles, id) =~ "<w:keepNext/>"
    end

    assert well_formed?(styles)
  end

  defp style_block(styles, id) do
    [block] =
      Regex.run(
        ~r{<w:style\b(?=[^>]*\bw:styleId="#{Regex.escape(id)}")[^>]*>.*?</w:style>}s,
        styles
      )

    block
  end
end
