defmodule Docgen.Render.MarkdownTest do
  use ExUnit.Case, async: true

  alias Docgen.Document

  defp round_trip(blocks) do
    {markdown, images} = Docgen.to_markdown(%Document{blocks: blocks})

    {markdown,
     Docgen.Ingest.Markdown.parse(markdown, images: images, promote_title: false).blocks}
  end

  test "rich documents round-trip exactly" do
    blocks = [
      {:heading, 2, [text: "Scope"]},
      {:paragraph,
       [
         {:text, "Mixed "},
         {:bold, [text: "bold ", italic: [text: "and italic"]]},
         {:text, ", "},
         {:code, "a `tick`"},
         {:text, " and "},
         {:link, "https://x.org/?a=1&b=2", [text: "a link"]},
         {:text, ".\nNew line."}
       ]},
      {:bullet_list, 1,
       [{[text: "a"], [{:numbered_list, 2, [{[text: "one"], []}, {[text: "two"], []}]}]}]},
      {:table, [[[text: "K"], [text: "V | pipe"]]], [[[code: "x"], []]]},
      {:note, [text: "Careful."]},
      {:important, [{:bold, [text: "Important:"]}, {:text, " really."}]},
      {:caption, :table, [text: "Codes"]},
      {:table, [[[text: "A"]]], [[[text: "1"]]]},
      {:code_block, "```\nnested fence\n```"}
    ]

    assert {_markdown, ^blocks} = round_trip(blocks)
  end

  test "text that looks like Markdown is escaped" do
    blocks = [
      {:paragraph, [text: "# not a heading"]},
      {:paragraph, [text: "1. not a list"]},
      {:paragraph, [text: "- not a bullet"]},
      {:paragraph, [text: "> not a quote"]},
      {:paragraph, [text: "*not italic* [not a link](x) <tag> a\\b"]},
      {:paragraph, [text: "snake_case stays _plain_"]},
      {:paragraph, [text: "line\n# after a break"]}
    ]

    {markdown, parsed} = round_trip(blocks)
    assert parsed == blocks
    assert markdown =~ "snake_case"
  end

  test "images become references and come back" do
    image = %{data: "png", content_type: "image/png", width: 10, height: 10}
    {markdown, images} = Docgen.to_markdown(%Document{blocks: [{:image, image, "Logo [v2]"}]})

    assert markdown =~ "![Logo  v2](docgen-image:1)"
    assert images == %{"1" => image}

    assert [{:image, ^image, "Logo  v2"}] =
             Docgen.Ingest.Markdown.parse(markdown, images: images).blocks
  end

  test "unknown image references fall back to their alt text" do
    assert Docgen.Ingest.Markdown.parse("![Chart](docgen-image:9)").blocks == [
             {:paragraph, [text: "Chart"]}
           ]
  end

  test "page breaks and empty paragraphs are dropped" do
    assert {"# T\n", _} =
             Docgen.to_markdown(%Document{
               blocks: [{:heading, 1, [text: "T"]}, :page_break, {:paragraph, []}]
             })
  end

  test "Important notes without a label get one so they stay Important" do
    {markdown, _} = Docgen.to_markdown(%Document{blocks: [{:important, [text: "Heads up."]}]})
    assert markdown == "> **Important:** Heads up.\n"
  end
end
