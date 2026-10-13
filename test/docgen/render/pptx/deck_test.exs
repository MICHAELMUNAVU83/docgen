defmodule Docgen.Render.Pptx.DeckTest do
  use ExUnit.Case, async: true

  alias Docgen.Render.Pptx.Deck

  defp build(markdown, meta \\ %{}) do
    markdown
    |> Docgen.parse(:markdown, template: :presentation, meta: meta)
    |> Deck.build()
  end

  defp kinds(slides), do: Enum.map(slides, &{&1.kind, &1[:title]})

  test "top-level headings become slides when there are no sections" do
    slides = build("# Deck\n\n## One\n\nText.\n\n## Two\n\n- a\n- b")

    assert kinds(slides) == [{:title, "Deck"}, {:content, "One"}, {:content, "Two"}]
  end

  test "top-level headings with subheadings become sections with an agenda" do
    slides = build("# A\n\n## A1\n\nx\n\n# B\n\n## B1\n\ny\n\n# C\n\n## C1\n\nz")

    assert kinds(slides) == [
             {:title, "A"},
             {:agenda, "Agenda"},
             {:section, "A"},
             {:content, "A1"},
             {:section, "B"},
             {:content, "B1"},
             {:section, "C"},
             {:content, "C1"}
           ]

    assert Enum.at(slides, 1).items == ~w(A B C)
  end

  test "two sections get no agenda" do
    slides = build("# A\n\n## A1\n\nx\n\n# B\n\n## B1\n\ny")
    refute Enum.any?(slides, &(&1.kind == :agenda))
  end

  test "deeper headings become subheadings" do
    [_title, slide] = build("# Deck\n\n## One\n\n### Detail\n\nText.")
    assert [{:subheading, [{:text, "Detail"}]}, {:paragraph, _}] = slide.blocks
  end

  test "long content continues on further slides, keeping list numbering" do
    items = Enum.map_join(1..30, "\n", &"#{&1}. Item number #{&1} with some words")
    [_title | slides] = build("# Deck\n\n## Steps\n\n" <> items)

    assert [%{title: "Steps"}, %{title: "Steps (continued)"} | _] = slides

    [first, second | _] = slides
    assert [{:numbered_list, 1, first_items}] = first.blocks
    assert [{:numbered_list, 1, _items, start}] = second.blocks
    assert start == length(first_items) + 1
  end

  test "long tables continue with the header repeated" do
    rows = Enum.map_join(1..40, "\n", &"| row #{&1} | value |")
    [_title | slides] = build("# Deck\n\n## Data\n\n| Key | Value |\n|---|---|\n" <> rows)

    assert length(slides) > 1
    assert Enum.all?(slides, &(&1.kind == :table and &1.header_rows != []))
    assert Enum.sum(Enum.map(slides, &length(&1.rows))) == 40
    assert Enum.at(slides, 1).title == "Data (continued)"
  end

  test "page breaks start a new slide" do
    doc = Docgen.parse("# Deck\n\n## One\n\nA", :markdown, template: :presentation)
    doc = %{doc | blocks: doc.blocks ++ [:page_break, {:paragraph, [{:text, "B"}]}]}
    assert [_title, %{title: "One"}, %{title: "One (continued)"}] = Deck.build(doc)
  end

  test "title slide metadata and photo" do
    [title | _] =
      build("# Deck\n\nText.", %{presenter: "Jo", date: "2026-01-05", cover: "photo4"})

    assert %{title: "Deck", presenter: "Jo", date: "5 January 2026", photo: "photo4"} = title

    assert [%{photo: "photo1"} | _] = build("Text.", %{cover: "../evil"})

    assert [%{photo: "none", title: "Untitled presentation"} | _] =
             build("Text.", %{cover: "none"})
  end

  test "SVG images keep only their caption" do
    svg = %{data: "<svg/>", content_type: "image/svg+xml", width: nil, height: nil}
    doc = %Docgen.Document{template: :presentation, blocks: [{:image, svg, "Chart"}]}

    assert [_title, %{kind: :content, blocks: [{:paragraph, [{:italic, _}]}]}] = Deck.build(doc)
  end

  describe "photos" do
    defp deck(markdown, visuals) do
      markdown
      |> Docgen.parse(:markdown,
        template: :presentation,
        meta: %{title: "Deck", visuals: visuals}
      )
      |> Docgen.Render.Pptx.Deck.build()
    end

    @visual %{
      image: %{data: "jpeg", content_type: "image/jpeg", width: 9, height: 9},
      credit: "Photo: A / Unsplash",
      kind: :photo
    }

    test "a content slide gets the photo found for its title" do
      slides = deck("# Why\n\n- one\n- two\n\n# How\n\nText.", %{"Why" => @visual})

      assert %{visual: @visual} = Enum.find(slides, &(&1[:title] == "Why"))
      refute Map.has_key?(Enum.find(slides, &(&1[:title] == "How")), :visual)
    end

    test "a slide too full for the narrower text column keeps all its width" do
      long =
        Enum.map_join(
          1..9,
          "\n",
          &"- Point #{&1} with enough words to wrap onto a second line beside a photo"
        )

      slides = deck("# Why\n\n" <> long, %{"Why" => @visual})

      refute Enum.any?(slides, &Map.has_key?(&1, :visual))
    end

    test "visual_candidates/1 lists the slides with room for a photo" do
      long =
        Enum.map_join(
          1..9,
          "\n",
          &"- Point #{&1} with enough words to wrap onto a second line beside a photo"
        )

      doc =
        Docgen.parse("# Why\n\n- one\n- two\n\n# Full\n\n" <> long, :markdown,
          template: :presentation
        )

      assert Docgen.Render.Pptx.Deck.visual_candidates(doc) == [
               %{key: "Why", kind: :content, title: "Why", text: "one  two "}
             ]
    end

    test "a table's chart gets a slide of its own after the table" do
      chart = %{
        type: :bar,
        title: "Stores by region",
        unit: "",
        points: [{"East", 72}, {"West", 48}]
      }

      slides =
        deck("# Results\n\n| Region | Stores |\n| --- | --- |\n| East | 72 |\n| West | 48 |", %{
          {:table, "Results"} => %{kind: :chart, chart: chart}
        })

      assert [
               %{kind: :title},
               %{kind: :table},
               %{kind: :chart, title: "Stores by region", chart: ^chart}
             ] =
               slides
    end
  end
end
