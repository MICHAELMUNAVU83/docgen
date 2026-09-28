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

  test "numbered bold titles are headings that keep their number" do
    doc =
      parse!([
        [
          t(760, "Review", 22, :bold),
          t(720, "1. Background", 13, :bold),
          t(700, "Joined in June."),
          t(670, "2. Assessment", 13, :bold),
          t(650, "Ratings follow.")
        ]
      ])

    assert doc.blocks == [
             {:heading, 2, [text: "1. Background"]},
             {:paragraph, [text: "Joined in June."]},
             {:heading, 2, [text: "2. Assessment"]},
             {:paragraph, [text: "Ratings follow."]}
           ]
  end

  test "column-aligned lines become a table, wrapped cell text joining its row" do
    doc =
      parse!([
        [
          t(760, "Ratings follow."),
          t(730, "Area", 11, :bold),
          t(730, "Rating", 11, :bold, 300),
          t(730, "Comment", 11, :bold, 380),
          # The comment wraps; area and rating are centred between its lines.
          t(706, "Strong across web and", 11, :regular, 380),
          t(699, "Design Skills", 11, :regular),
          t(699, "90%", 11, :regular, 300),
          t(692, "internal systems", 11, :regular, 380),
          t(670, "Quality", 11, :regular),
          t(670, "85%", 11, :regular, 300),
          t(670, "Clear designs", 11, :regular, 380),
          t(620, "Well done overall.")
        ]
      ])

    assert doc.blocks == [
             {:paragraph, [text: "Ratings follow."]},
             {:table, [[[text: "Area"], [text: "Rating"], [text: "Comment"]]],
              [
                [
                  [text: "Design Skills"],
                  [text: "90%"],
                  [text: "Strong across web and internal systems"]
                ],
                [[text: "Quality"], [text: "85%"], [text: "Clear designs"]]
              ]},
             {:paragraph, [text: "Well done overall."]}
           ]
  end

  test "bullets set apart from their text are not a table" do
    doc =
      parse!([
        [
          t(760, "Intro text."),
          t(740, "\u2022", 11, :regular, 72),
          t(740, "First point", 11, :regular, 100),
          t(726, "\u2022", 11, :regular, 72),
          t(726, "Second point", 11, :regular, 100),
          t(712, "\u2022", 11, :regular, 72),
          t(712, "Third point", 11, :regular, 100)
        ]
      ])

    refute Enum.any?(doc.blocks, &match?({:table, _, _}, &1))
  end

  test "tables with centred headers and wrapped cells continue across pages" do
    row = fn y, area, rating, comment ->
      [t(y, area), t(y, rating, 11, :regular, 300), t(y, comment, 11, :regular, 380)]
    end

    header = fn y ->
      [
        t(y, "Area", 11, :bold, 110),
        t(y, "Rating", 11, :bold, 320),
        t(y, "Comment", 11, :bold, 420)
      ]
    end

    doc =
      parse!([
        # The area wraps downwards, next to the comment's second line.
        [t(700, "Ratings follow.")] ++
          header.(670) ++
          row.(646, "Quality", "90%", "Careful work") ++
          row.(622, "Initiative &", "80%", "Explores ideas;") ++
          [t(608, "Problem Solving"), t(608, "volunteers more", 11, :regular, 380)],
        header.(700) ++ row.(676, "Overall", "85%", "Average") ++ [t(620, "Well done.")]
      ])

    assert doc.blocks == [
             {:paragraph, [text: "Ratings follow."]},
             {:table, [[[text: "Area"], [text: "Rating"], [text: "Comment"]]],
              [
                [[text: "Quality"], [text: "90%"], [text: "Careful work"]],
                [
                  [text: "Initiative & Problem Solving"],
                  [text: "80%"],
                  [text: "Explores ideas; volunteers more"]
                ],
                [[text: "Overall"], [text: "85%"], [text: "Average"]]
              ]},
             {:paragraph, [text: "Well done."]}
           ]
  end

  test "a lone larger line under the title is not the document's only top heading" do
    doc =
      parse!([
        [
          t(760, "Review", 22, :bold),
          t(735, "Engineer, Platform Team", 15),
          t(700, "1 Background", 13, :bold),
          t(680, "Joined in June."),
          t(650, "2 Assessment", 13, :bold),
          t(630, "Ratings follow.")
        ]
      ])

    assert [{:paragraph, [text: "Engineer, Platform Team"]}, {:heading, 3, _} | _] = doc.blocks
  end
end
