defmodule Docgen.Ingest.PdfTest do
  use ExUnit.Case, async: true

  import Docgen.PdfBuilder, only: [build: 1]

  alias Docgen.Ingest.Pdf

  # PDF coordinates: origin bottom-left, A4 is 595×842.
  defp t(y, text, size \\ 11, weight \\ :regular, x \\ 72), do: {:text, x, y, size, weight, text}

  defp header, do: t(810, "ACME Corp - Confidential", 8)
  defp page_number(n), do: t(30, "#{n}", 8, :regular, 290)

  defp parse!(pages) do
    {:ok, doc} = pages |> build() |> Pdf.parse()
    doc
  end

  test "headings by size, paragraphs by spacing, running headers removed" do
    doc =
      parse!([
        [
          header(),
          t(760, "Supplier Guide", 22, :bold),
          t(720, "1 Introduction", 15, :bold),
          t(700, "This guide explains how suppliers share data with retail-"),
          t(686, "ers using GS1 standards."),
          t(660, "A second paragraph starts after a gap."),
          t(630, "Scope", 11, :bold),
          t(610, "Applies to everyone."),
          page_number(1)
        ],
        [
          header(),
          t(760, "2 Details", 15, :bold),
          t(740, "More text on page two."),
          page_number(2)
        ]
      ])

    assert doc.meta.title == "Supplier Guide"

    assert doc.blocks == [
             {:heading, 2, [text: "1 Introduction"]},
             {:paragraph,
              [
                text:
                  "This guide explains how suppliers share data with retailers using GS1 standards."
              ]},
             {:paragraph, [text: "A second paragraph starts after a gap."]},
             {:heading, 3, [text: "Scope"]},
             {:paragraph, [text: "Applies to everyone."]},
             {:heading, 2, [text: "2 Details"]},
             {:paragraph, [text: "More text on page two."]}
           ]

    assert [warning] = doc.warnings
    assert warning =~ "Converted from PDF"
  end

  test "bullets nest by indent, wrapped items continue, numbered lists" do
    doc =
      parse!([
        [
          t(760, "Checklist", 15, :bold),
          t(740, "• First item that wraps"),
          t(726, "onto a second line", 11, :regular, 84),
          t(712, "• Nested item", 11, :regular, 96),
          t(698, "• Back to top"),
          t(670, "1. Step one"),
          t(656, "2. Step two"),
          t(630, "Closing text.")
        ]
      ])

    assert doc.blocks == [
             {:bullet_list, 1,
              [
                {[text: "First item that wraps onto a second line"],
                 [{:bullet_list, 2, [{[text: "Nested item"], []}]}]},
                {[text: "Back to top"], []}
              ]},
             {:numbered_list, 1, [{[text: "Step one"], []}, {[text: "Step two"], []}]},
             {:paragraph, [text: "Closing text."]}
           ]

    # A lone large heading is promoted to the title.
    assert doc.meta.title == "Checklist"
  end

  test "paragraphs continue across a page break mid-sentence" do
    doc =
      parse!([
        [t(760, "This sentence runs over"), page_number(1)],
        [t(800, "the page break."), page_number(2)]
      ])

    assert doc.blocks == [{:paragraph, [text: "This sentence runs over the page break."]}]
  end

  test "bold words inside a paragraph are kept" do
    doc =
      parse!([
        [t(760, "Plain"), t(760, "loud", 11, :bold, 110), t(760, "end.", 11, :regular, 140)]
      ])

    assert doc.blocks == [{:paragraph, [text: "Plain ", bold: [text: "loud"], text: " end."]}]
  end

  test "a PDF without text" do
    assert Pdf.parse(build([[]])) == {:error, :no_text}
  end

  test "garbage input" do
    assert Pdf.parse("not a pdf") == {:error, :unreadable_pdf}
  end

  test "missing pdftohtml" do
    assert Pdf.parse(build([[t(700, "x")]]), pdftohtml: nil) == {:error, :pdftohtml_not_found}
  end
end
