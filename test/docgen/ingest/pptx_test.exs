defmodule Docgen.Ingest.PptxTest do
  use ExUnit.Case, async: true

  @markdown """
  # Intro

  ## Why

  - one **bold**
    - nested
  - [link](https://www.gs1.org)

  ## Data

  | A | B |
  |---|---|
  | 1 | 2 |

  # Next

  ## Steps

  1. first
  2. second

  # Last

  ## End

  Thanks.
  """

  defp deck(markdown, meta) do
    {:ok, pptx} =
      markdown
      |> Docgen.parse(:markdown, template: :presentation, meta: meta)
      |> Docgen.to_pptx()

    pptx
  end

  test "imports the title slide, sections, lists and tables of a deck" do
    pptx = deck(@markdown, %{title: "Launch", subtitle: "Sub", presenter: "Jo"})

    assert {:ok, doc} = Docgen.ingest(pptx, :pptx, template: :presentation)
    assert doc.template == :presentation
    assert %{title: "Launch", subtitle: "Sub", presenter: "Jo"} = doc.meta
    assert doc.warnings == []

    headings = for {:heading, level, [{:text, text}]} <- doc.blocks, do: {level, text}

    # The generated agenda slide is not imported as content.
    assert headings == [
             {1, "Intro"},
             {2, "Why"},
             {2, "Data"},
             {1, "Next"},
             {2, "Steps"},
             {1, "Last"},
             {2, "End"}
           ]

    assert [{:bullet_list, 1, [{first, [{:bullet_list, 2, [_]}]}, {[link], []}]}] =
             for({:bullet_list, _, _} = list <- doc.blocks, do: list)

    assert {:bold, [text: "bold"]} in first
    assert {:link, "https://www.gs1.org", [text: "link"]} = link

    assert [{:numbered_list, 1, [_, _]}] =
             for({:numbered_list, _, _} = list <- doc.blocks, do: list)

    assert [{:table, [[_, _]], [[[text: "1"], [text: "2"]]]}] =
             for({:table, _, _} = table <- doc.blocks, do: table)

    assert {:paragraph, [text: "Thanks."]} in doc.blocks
  end

  test "slides without dividers become top-level headings" do
    pptx = deck("# One\n\nFirst.\n\n# Two\n\nSecond.", %{title: "Deck"})

    assert {:ok, doc} = Docgen.ingest(pptx, :pptx)

    assert [
             {:heading, 1, [text: "One"]},
             {:paragraph, [text: "First."]},
             {:heading, 1, [text: "Two"]},
             {:paragraph, [text: "Second."]}
           ] = doc.blocks
  end

  test "imports the GS1 template's own sample slides" do
    pptx = File.read!(Application.app_dir(:docgen, "priv/templates/presentation.pptx"))

    assert {:ok, doc} = Docgen.ingest(pptx, :pptx)
    assert Enum.any?(doc.blocks, &match?({:heading, _, _}, &1))
    assert Enum.any?(doc.blocks, &match?({:image, %{content_type: _}, _}, &1))
  end

  test "rejects files that aren't presentations" do
    assert {:error, :invalid_pptx} = Docgen.ingest("PK nope", :pptx)
    assert {:error, :invalid_pptx} = Docgen.ingest(Docgen.DocxBuilder.build(""), :pptx)
  end
end
