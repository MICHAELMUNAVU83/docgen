defmodule Docgen.AI.PlannerTest do
  use ExUnit.Case, async: true

  alias Docgen.AI.Planner

  test "falls back to Advanced and recommends bars for percentage comparisons" do
    source = """
    # Annual report

    | Region | Completion |
    | --- | --- |
    | East | 72% |
    | West | 48% |
    """

    doc = Docgen.parse(source, :markdown)
    assert {:ok, plan} = Planner.analyze(doc, api_key: nil)
    assert plan.template == :advanced
    assert plan.source == :rules
    assert plan.cover_asset == "corporate"
    assert [%{type: :bar, source_excerpt: excerpt}] = plan.charts
    assert excerpt =~ "72%"
    assert excerpt =~ "48%"
  end

  test "uses a donut for one explicit percentage" do
    doc = Docgen.parse("Uptake reached 64% of members.", :text)
    assert {:ok, plan} = Planner.analyze(doc, api_key: nil)
    assert [%{type: :donut}] = plan.charts
  end

  test "parses schema-constrained API output" do
    client = fn _url, options ->
      assert options[:json]["text"]["format"]["strict"]

      data = %{
        template: "letterhead",
        template_reason: "It is addressed correspondence.",
        cover_asset: "corporate",
        asset_reason: "Letterhead does not use a cover visual.",
        charts: [],
        summary: "No chart is needed."
      }

      {:ok,
       %{
         status: 200,
         body: %{
           "output" => [
             %{"content" => [%{"type" => "output_text", "text" => Jason.encode!(data)}]}
           ]
         }
       }}
    end

    doc = Docgen.parse("Dear Partner,\n\nThank you.", :text)
    assert {:ok, plan} = Planner.analyze(doc, api_key: "test", client: client)
    assert plan.template == :letterhead
    assert plan.source == :ai
  end

  test "selects an official GS1 industry asset from document content" do
    doc =
      Docgen.parse(
        "# Healthcare traceability report\n\nHospitals and clinical teams use these identifiers.",
        :markdown
      )

    assert {:ok, plan} = Planner.analyze(doc, api_key: nil)
    assert plan.cover_asset == "healthcare"
    assert plan.asset_reason =~ "official visual"
    assert {plan.cover_asset, "Healthcare"} in Docgen.Template.cover_icons()
  end

  @unmarked """
  # Cloud Decisions

  ## Projects I've scaled

  Asake Kenya: ticketing, flash sales

  CallWisely AI: 50K+ voice calls / month

  Wasomi AI: EdTech, LLM pipelines

  ## Why it matters

  Elixir keeps the bill small, which is why every one of these projects could start on a single modest server and grow from there.
  """

  test "flags runs of short paragraphs as list items without an API key" do
    doc = Docgen.parse(@unmarked, :markdown)
    assert {:ok, plan} = Planner.analyze(doc, api_key: nil)
    assert plan.list_items == [1, 2, 3]
  end

  test "keeps only the paragraph indices the API returns" do
    client = fn _url, options ->
      assert options[:json]["input"] =~ "[1] Asake Kenya: ticketing, flash sales"

      data = %{
        template: "basic",
        template_reason: "Short.",
        cover_asset: "corporate",
        asset_reason: "None.",
        charts: [],
        summary: "No chart is needed.",
        list_items: [3, 1, 2, 0, 99]
      }

      {:ok,
       %{
         status: 200,
         body: %{
           "output" => [
             %{"content" => [%{"type" => "output_text", "text" => Jason.encode!(data)}]}
           ]
         }
       }}
    end

    doc = Docgen.parse(@unmarked, :markdown)
    assert {:ok, plan} = Planner.analyze(doc, api_key: "test", client: client)
    assert plan.list_items == [1, 2, 3]
  end
end
