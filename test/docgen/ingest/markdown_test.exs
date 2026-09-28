defmodule Docgen.Ingest.MarkdownTest do
  use ExUnit.Case, async: true

  alias Docgen.Ingest.Markdown
  alias Docgen.Ingest.Markdown.Inline

  defp blocks(markdown), do: Markdown.parse(markdown, promote_title: false).blocks

  describe "blocks" do
    test "ATX and setext headings" do
      assert blocks("# One\n\n## Two ##\n\nThree\n=====\n\nFour\n----") == [
               {:heading, 1, [text: "One"]},
               {:heading, 2, [text: "Two"]},
               {:heading, 1, [text: "Three"]},
               {:heading, 2, [text: "Four"]}
             ]
    end

    test "paragraphs join wrapped lines and keep hard breaks" do
      assert blocks("one\ntwo  \nthree\\\nfour\n\nnext") == [
               {:paragraph, [text: "one two\nthree\nfour"]},
               {:paragraph, [text: "next"]}
             ]
    end

    test "nested bullet and numbered lists" do
      markdown = """
      - a
        continued
      - b
        1. b1
        2. b2
      - c
      """

      assert blocks(markdown) == [
               {:bullet_list, 1,
                [
                  {[text: "a continued"], []},
                  {[text: "b"], [{:numbered_list, 2, [{[text: "b1"], []}, {[text: "b2"], []}]}]},
                  {[text: "c"], []}
                ]}
             ]
    end

    test "a change of list marker starts a new list" do
      assert [{:bullet_list, 1, _}, {:numbered_list, 1, _}] = blocks("- a\n1. b")
    end

    test "pipe tables pad short rows" do
      markdown = """
      | A | B |
      |---|:-:|
      | 1 | `x \\| y` |
      | 2 |
      """

      assert blocks(markdown) == [
               {:table, [[[text: "A"], [text: "B"]]],
                [[[text: "1"], [code: "x | y"]], [[text: "2"], []]]}
             ]
    end

    test "fenced code keeps content verbatim" do
      assert blocks("```elixir\n  # not a heading\n\n*x*\n```\nafter") == [
               {:code_block, "  # not a heading\n\n*x*"},
               {:paragraph, [text: "after"]}
             ]
    end

    test "block quotes become notes" do
      assert blocks("> quoted\n> text") == [{:note, [text: "quoted text"]}]
    end

    test "Important block quotes" do
      assert blocks("> **Important:** read this") == [
               {:important, [{:bold, [text: "Important:"]}, {:text, " read this"}]}
             ]

      assert [{:note, _}] = blocks("> **Note:** fine")
    end

    test "Table: paragraphs before or after a table become its caption" do
      table = "| A |\n|---|\n| 1 |"

      for markdown <- ["Table: Codes\n\n#{table}", "#{table}\n\nTable: Codes"] do
        assert [{:caption, :table, [text: "Codes"]}, {:table, _, _}] = blocks(markdown)
      end

      assert [{:paragraph, [text: "Table: loose"]}] = blocks("Table: loose")
    end

    test "thematic breaks are dropped" do
      assert blocks("a\n\n***\n\nb") == [{:paragraph, [text: "a"]}, {:paragraph, [text: "b"]}]
    end
  end

  describe "metadata" do
    test "front matter sets title and subtitle" do
      doc = Markdown.parse("---\ntitle: \"Report\"\nsubtitle: Draft\nauthor: x\n---\nBody")
      assert doc.meta == %{title: "Report", subtitle: "Draft"}
      assert doc.blocks == [{:paragraph, [text: "Body"]}]
    end

    test "a sole leading H1 is promoted to the title" do
      doc = Markdown.parse("# Report\n\n## Intro")
      assert doc.meta.title == "Report"
      assert doc.blocks == [{:heading, 2, [text: "Intro"]}]
    end

    test "H1s are kept when there are several" do
      doc = Markdown.parse("# One\n\n# Two")
      refute Map.has_key?(doc.meta, :title)
      assert length(doc.blocks) == 2
    end

    test "explicit meta wins over the heading" do
      doc = Markdown.parse("# Heading", meta: %{title: "Given"})
      assert doc.meta.title == "Given"
      assert doc.blocks == [{:heading, 1, [text: "Heading"]}]
    end
  end

  describe "inlines" do
    test "emphasis, code and links" do
      assert Inline.parse("**b** *i* ***bi*** `c` [l](https://x.org)") == [
               {:bold, [text: "b"]},
               {:text, " "},
               {:italic, [text: "i"]},
               {:text, " "},
               {:bold, [italic: [text: "bi"]]},
               {:text, " "},
               {:code, "c"},
               {:text, " "},
               {:link, "https://x.org", [text: "l"]}
             ]
    end

    test "nested formatting" do
      assert Inline.parse("*a **b** c*") ==
               [{:italic, [{:text, "a "}, {:bold, [text: "b"]}, {:text, " c"}]}]

      assert Inline.parse("[**bold** link](https://x.org)") ==
               [{:link, "https://x.org", [{:bold, [text: "bold"]}, {:text, " link"}]}]
    end

    test "intraword underscores and lone asterisks stay literal" do
      assert Inline.parse("snake_case_name and 2 * 3") == [text: "snake_case_name and 2 * 3"]
      assert Inline.parse("**unclosed") == [text: "**unclosed"]
    end

    test "escapes" do
      assert Inline.parse(~S"\*not italic\* \[x\]") == [text: "*not italic* [x]"]
    end

    test "autolinks and bare URLs" do
      assert Inline.parse("<https://a.org> and https://b.org/x.") == [
               {:link, "https://a.org", [text: "https://a.org"]},
               {:text, " and "},
               {:link, "https://b.org/x", [text: "https://b.org/x"]},
               {:text, "."}
             ]
    end

    test "images reduce to alt text" do
      assert Inline.parse("see ![a chart](c.png) here") == [text: "see a chart here"]
    end
  end
end
