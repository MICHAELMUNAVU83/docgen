defmodule Docgen.Ingest.DocxTest do
  use ExUnit.Case, async: true

  import Docgen.DocxBuilder

  alias Docgen.Ingest.Docx

  defp parse!(body) do
    {:ok, doc} = body |> build() |> Docx.parse()
    doc
  end

  describe "paragraph styles" do
    test "title and subtitle fill meta; headings resolve through basedOn and outline levels" do
      doc =
        parse!([
          p("Annual Report", style: "Title"),
          p("2026 edition", style: "Subtitle"),
          p("Overview", style: "Heading1"),
          p("Custom section", style: "MySection"),
          p("Outline only", outline: 2),
          p("Body text.")
        ])

      assert doc.meta == %{title: "Annual Report", subtitle: "2026 edition"}

      assert doc.blocks == [
               {:heading, 1, [text: "Overview"]},
               {:heading, 2, [text: "Custom section"]},
               {:heading, 3, [text: "Outline only"]},
               {:paragraph, [text: "Body text."]}
             ]
    end

    test "quote, code and empty paragraphs" do
      doc =
        parse!([
          p("Quoted.", style: "Quote"),
          p("", []),
          p("def a, do: 1", style: "SourceCode"),
          p("  :ok", style: "SourceCode")
        ])

      assert doc.blocks == [{:note, [text: "Quoted."]}, {:code_block, "def a, do: 1\n  :ok"}]
    end
  end

  describe "runs" do
    test "bold, italic, monospace, character styles, breaks and tabs" do
      doc =
        parse!(
          p([
            r("bold", "<w:b/>"),
            r(" "),
            r("not bold", ~s(<w:b w:val="0"/>)),
            r(" "),
            r("italic", "<w:i/>"),
            r(" "),
            r("strong", ~s(<w:rStyle w:val="Strong"/>)),
            r(" "),
            r("mono", ~s(<w:rFonts w:ascii="Consolas" w:hAnsi="Consolas"/>)),
            "<w:r><w:br/><w:t>line</w:t><w:tab/><w:t>tab</w:t></w:r>"
          ])
        )

      assert doc.blocks == [
               {:paragraph,
                [
                  {:bold, [text: "bold"]},
                  {:text, " not bold "},
                  {:italic, [text: "italic"]},
                  {:text, " "},
                  {:bold, [text: "strong"]},
                  {:text, " "},
                  {:code, "mono"},
                  {:text, "\nline\ttab"}
                ]}
             ]
    end

    test "hyperlinks, tracked changes and content controls" do
      doc =
        parse!(
          p([
            ~s(<w:hyperlink r:id="rIdLink">#{r("GS1")}</w:hyperlink>),
            r(" "),
            ~s(<w:hyperlink w:anchor="intro">#{r("intro")}</w:hyperlink>),
            ~s(<w:del><w:r><w:delText>removed</w:delText></w:r></w:del>),
            ~s(<w:ins>#{r(" added")}</w:ins>),
            ~s(<w:sdt><w:sdtContent>#{r(" field")}</w:sdtContent></w:sdt>)
          ])
        )

      assert doc.blocks == [
               {:paragraph,
                [
                  {:link, "https://www.gs1.org/", [text: "GS1"]},
                  {:text, " "},
                  {:link, "#intro", [text: "intro"]},
                  {:text, " added field"}
                ]}
             ]
    end
  end

  describe "lists" do
    test "bullets nest by ilvl; separate numbering instances stay separate lists" do
      doc =
        parse!([
          p("style bullet", style: "ListBullet"),
          p("nested", num: {1, 1}),
          p("one", num: {2, 0}),
          p("sub", num: {2, 1}),
          p("two", num: {2, 0}),
          p("again", num: {3, 0})
        ])

      assert doc.blocks == [
               {:bullet_list, 1,
                [{[text: "style bullet"], [{:bullet_list, 2, [{[text: "nested"], []}]}]}]},
               {:numbered_list, 1,
                [
                  {[text: "one"], [{:numbered_list, 2, [{[text: "sub"], []}]}]},
                  {[text: "two"], []}
                ]},
               {:numbered_list, 1, [{[text: "again"], []}]}
             ]
    end

    test "numId 0 removes numbering" do
      assert parse!(p("plain", num: {0, 0})).blocks == [{:paragraph, [text: "plain"]}]
    end
  end

  describe "tables" do
    test "header rows, merged cells and multi-paragraph cells" do
      tc = fn content, tcpr -> "<w:tc><w:tcPr>#{tcpr}</w:tcPr>#{content}</w:tc>" end

      table = """
      <w:tbl>
        <w:tr><w:trPr><w:tblHeader/></w:trPr>#{tc.(p([r("Key", "<w:b/>")]), "")}#{tc.(p("Value"), ~s(<w:gridSpan w:val="2"/>))}</w:tr>
        <w:tr>#{tc.(p("GTIN"), ~s(<w:vMerge w:val="restart"/>))}#{tc.(p("14") <> p("digits"), "")}#{tc.(p("x"), "")}</w:tr>
        <w:tr>#{tc.(p("ignored"), "<w:vMerge/>")}#{tc.(p("13"), "")}#{tc.(p("y"), "")}</w:tr>
      </w:tbl>
      """

      assert parse!(table).blocks == [
               {:table, [[[text: "Key"], [text: "Value"], []]],
                [
                  [[text: "GTIN"], [text: "14\ndigits"], [text: "x"]],
                  [[], [text: "13"], [text: "y"]]
                ]}
             ]
    end

    test "tblLook firstRow marks the header when tblHeader is absent" do
      table =
        ~s(<w:tbl><w:tblPr><w:tblLook w:val="04A0"/></w:tblPr>) <>
          "<w:tr><w:tc>#{p("H")}</w:tc></w:tr><w:tr><w:tc>#{p("B")}</w:tc></w:tr></w:tbl>"

      assert [{:table, [[[text: "H"]]], [[[text: "B"]]]}] = parse!(table).blocks
    end
  end

  describe "images and breaks" do
    test "embedded images keep their size and take the following caption" do
      doc = parse!([p([image_run()]), p("Figure 1: Logo", style: "Caption")])

      # Caption numbers are regenerated on output, so the label is dropped.
      assert [{:image, image, "Logo"}] = doc.blocks
      assert image.content_type == "image/png"
      assert {image.width, image.height} == {1_828_800, 914_400}
      assert <<0x89, "PNG", _::binary>> = image.data
    end

    test "page breaks" do
      doc = parse!([p("before"), p([~s(<w:r><w:br w:type="page"/></w:r>)]), p("after")])

      assert doc.blocks == [
               {:paragraph, [text: "before"]},
               :page_break,
               {:paragraph, [text: "after"]}
             ]
    end
  end

  test "unsupported content produces warnings" do
    doc = parse!(p([r("text"), ~s(<w:r><w:footnoteReference w:id="1"/></w:r>)]))
    assert doc.warnings == ["Footnotes weren't imported."]
  end

  describe "invalid input" do
    test "not a zip" do
      assert Docx.parse("not a docx") == {:error, :invalid_docx}
    end

    test "a zip without a document part" do
      {:ok, {_, zip}} = :zip.create(~c"x.zip", [{~c"hello.txt", "hi"}], [:memory])
      assert Docx.parse(zip) == {:error, :invalid_docx}
    end

    test "DOCTYPE declarations are rejected" do
      document = ~s(<?xml version="1.0"?><!DOCTYPE x [<!ENTITY a "a">]><w:document xmlns:w="w"/>)
      assert {:error, :doctype_not_allowed} = "" |> build(document: document) |> Docx.parse()
    end
  end

  test "documents generated by Docgen round-trip" do
    markdown =
      "## Scope\n\nSome **bold** and `code`.\n\n- a\n  - b\n\n1. one\n2. two\n\n| K | V |\n| --- | --- |\n| x | y |"

    original = Docgen.parse(markdown, :markdown, meta: %{title: "Round trip", subtitle: "Test"})
    {:ok, docx} = Docgen.to_docx(original)

    assert {:ok, imported} = Docx.parse(docx)
    assert imported.meta == %{title: "Round trip", subtitle: "Test"}
    # GS1 Basic renders the shallowest heading as Heading 1.
    assert imported.blocks == Docgen.Document.normalize_headings(original.blocks)
  end
end
