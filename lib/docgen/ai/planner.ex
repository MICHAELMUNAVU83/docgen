defmodule Docgen.AI.Planner do
  @moduledoc """
  Selects a suitable GS1 template and identifies data that would benefit from
  a chart. AI output is advisory: it never changes the document automatically
  and chart suggestions quote the source they are based on.

  When no API key is configured, a conservative rules-based plan is returned.
  """

  alias Docgen.AI.Plan
  alias Docgen.Document

  @endpoint "https://api.openai.com/v1/responses"
  @templates ~w(basic advanced letterhead)
  @chart_types ~w(bar line donut none)
  @asset_aliases %{
    "transport_and_logistics" =>
      ~w(transport transportation logistics freight shipping supply-chain),
    "healthcare" => ~w(health healthcare hospital clinical),
    "medical_devices" => ~w(medical device devices medtech),
    "pharmaceuticals" => ~w(pharmaceutical pharmaceuticals pharma medicine medicines),
    "retail" => ~w(retail retailer retailers store stores),
    "foodservice" => ~w(foodservice restaurant catering hospitality),
    "finance" => ~w(finance financial banking bank payment payments),
    "construction" => ~w(construction building infrastructure),
    "government" => ~w(government public-sector ministry regulator),
    "consumer_electronics" => ~w(electronics technology devices),
    "recycling" => ~w(recycling circularity waste sustainability)
  }

  @spec analyze(Document.t(), keyword()) :: {:ok, Plan.t()} | {:error, term()}
  def analyze(%Document{} = doc, opts \\ []) do
    config = Application.get_env(:docgen, __MODULE__, [])
    api_key = Keyword.get(opts, :api_key, config[:api_key])

    if api_key in [nil, ""] do
      {:ok, rules_plan(doc)}
    else
      request(doc, api_key, Keyword.merge(config, opts))
    end
  end

  defp request(doc, api_key, opts) do
    client = Keyword.get(opts, :client, &Req.post/2)

    body = %{
      "model" => Keyword.get(opts, :model, "gpt-4o-mini"),
      "store" => false,
      "instructions" => instructions(),
      "input" => document_text(doc),
      "text" => %{"format" => schema()}
    }

    case client.(@endpoint,
           json: body,
           auth: {:bearer, api_key},
           receive_timeout: Keyword.get(opts, :timeout, 30_000)
         ) do
      {:ok, %{status: status, body: response}} when status in 200..299 -> parse_response(response)
      {:ok, %{status: status}} -> {:error, {:api_error, status}}
      {:error, reason} -> {:error, {:request_failed, reason}}
    end
  end

  defp parse_response(response) do
    with text when is_binary(text) <- output_text(response),
         {:ok, data} <- Jason.decode(text),
         {:ok, plan} <- validate(data) do
      {:ok, %{plan | source: :ai}}
    else
      _ -> {:error, :invalid_ai_response}
    end
  end

  defp output_text(%{"output" => output}) when is_list(output) do
    Enum.find_value(output, fn
      %{"content" => content} when is_list(content) ->
        Enum.find_value(content, fn
          %{"type" => "output_text", "text" => text} -> text
          _ -> nil
        end)

      _ ->
        nil
    end)
  end

  defp output_text(_), do: nil

  defp validate(%{
         "template" => template,
         "template_reason" => reason,
         "cover_asset" => cover_asset,
         "asset_reason" => asset_reason,
         "charts" => charts,
         "summary" => summary
       })
       when template in @templates and is_binary(reason) and is_binary(cover_asset) and
              is_binary(asset_reason) and is_list(charts) and is_binary(summary) do
    charts = Enum.map(charts, &validate_chart/1)

    if Enum.all?(charts, & &1) and cover_asset in asset_slugs() do
      {:ok,
       %Plan{
         template: String.to_existing_atom(template),
         template_reason: reason,
         cover_asset: cover_asset,
         asset_reason: asset_reason,
         charts: charts,
         summary: summary
       }}
    else
      {:error, :invalid_chart}
    end
  end

  defp validate(_), do: {:error, :invalid_plan}

  defp validate_chart(%{
         "type" => type,
         "title" => title,
         "reason" => reason,
         "source_excerpt" => excerpt
       })
       when type in @chart_types and is_binary(title) and is_binary(reason) and is_binary(excerpt) do
    %{type: String.to_existing_atom(type), title: title, reason: reason, source_excerpt: excerpt}
  end

  defp validate_chart(_), do: nil

  defp rules_plan(doc) do
    text = document_text(doc)
    down = String.downcase(text)
    letter? = Regex.match?(~r/\b(dear|sincerely|recipient|subject:)\b/, down)
    percentage_count = Regex.scan(~r/\b\d+(?:\.\d+)?\s*%/, text) |> length()

    rich? =
      Enum.any?(doc.blocks, &match?({:table, _, _}, &1)) or length(doc.blocks) > 12 or
        percentage_count > 1

    {template, reason} =
      cond do
        letter? ->
          {:letterhead, "The content reads like formal correspondence."}

        rich? ->
          {:advanced,
           "The document has enough structure or data to benefit from a cover and contents page."}

        true ->
          {:basic, "The content is a concise, general-purpose document."}
      end

    charts = rule_charts(text)
    cover_asset = rule_asset(down)

    %Plan{
      template: template,
      template_reason: reason,
      cover_asset: cover_asset,
      asset_reason: asset_reason(cover_asset),
      charts: charts,
      summary: summary(charts),
      source: :rules
    }
  end

  defp rule_charts(text) do
    percentage_lines =
      text
      |> String.split("\n")
      |> Enum.filter(&Regex.match?(~r/\b\d+(?:\.\d+)?\s*%/, &1))
      |> Enum.take(4)

    case percentage_lines do
      [] ->
        []

      [line] ->
        [
          chart(
            :donut,
            "Percentage highlight",
            "A single part-to-whole percentage is easy to scan as a donut or KPI.",
            line
          )
        ]

      lines ->
        [
          chart(
            :bar,
            "Percentage comparison",
            "Several percentages are clearer as a labelled bar chart.",
            Enum.join(lines, " | ")
          )
        ]
    end
  end

  defp chart(type, title, reason, excerpt),
    do: %{type: type, title: title, reason: reason, source_excerpt: String.slice(excerpt, 0, 280)}

  defp summary([]),
    do:
      "No chart is recommended because the source does not contain enough explicit numeric data."

  defp summary(_),
    do: "The source contains explicit percentages that can be visualised without inventing data."

  defp rule_asset(text) do
    @asset_aliases
    |> Enum.map(fn {slug, words} ->
      score = Enum.count(words, &String.contains?(text, String.replace(&1, "-", " ")))
      {score, slug}
    end)
    |> Enum.max(fn -> {0, "corporate"} end)
    |> case do
      {0, _slug} -> "corporate"
      {_score, slug} -> slug
    end
  end

  defp asset_reason("corporate"),
    do:
      "No single industry dominates the content, so the official GS1 corporate visual is the safest choice."

  defp asset_reason(slug) do
    label =
      Docgen.Template.cover_icons()
      |> Enum.find_value(slug, fn {known, label} -> if known == slug, do: label end)

    "The content is related to #{label}, matching an official visual from the GS1 Word asset pack."
  end

  defp document_text(doc) do
    title = doc.meta[:title] || ""
    {markdown, _images} = Docgen.to_markdown(doc)
    String.slice("Title: #{title}\n\n#{markdown}", 0, 40_000)
  end

  defp instructions do
    """
    You are a document design planner for GS1-styled documents. Recommend:
    - basic for short general documents without front matter;
    - advanced for reports, specifications, policies, multi-section documents, tables, or documents needing a cover/TOC;
    - letterhead only for correspondence addressed to a recipient.

    Recommend charts only when explicit source data supports them. Use donut only for a single part-to-whole percentage, bar for comparisons, and line for a time series. Never invent values. Include a short verbatim source excerpt for every chart. Return no chart rather than forcing one.

    For Advanced documents, select the most relevant official GS1 cover asset from this catalogue. Use corporate when no industry is clearly supported by the content. For Basic or Letterhead, return corporate because they do not use an Advanced cover visual:
    #{asset_catalogue()}
    """
  end

  defp asset_catalogue do
    asset_slugs()
    |> Enum.map_join(", ", fn slug ->
      case Enum.find(Docgen.Template.cover_icons(), fn {known, _label} -> known == slug end) do
        nil -> slug
        {_slug, label} -> "#{slug} (#{label})"
      end
    end)
  end

  defp asset_slugs,
    do: ["corporate", "none" | Enum.map(Docgen.Template.cover_icons(), &elem(&1, 0))]

  defp schema do
    %{
      "type" => "json_schema",
      "name" => "document_design_plan",
      "strict" => true,
      "schema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => [
          "template",
          "template_reason",
          "cover_asset",
          "asset_reason",
          "charts",
          "summary"
        ],
        "properties" => %{
          "template" => %{"type" => "string", "enum" => @templates},
          "template_reason" => %{"type" => "string"},
          "cover_asset" => %{"type" => "string", "enum" => asset_slugs()},
          "asset_reason" => %{"type" => "string"},
          "summary" => %{"type" => "string"},
          "charts" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "additionalProperties" => false,
              "required" => ["type", "title", "reason", "source_excerpt"],
              "properties" => %{
                "type" => %{"type" => "string", "enum" => @chart_types},
                "title" => %{"type" => "string"},
                "reason" => %{"type" => "string"},
                "source_excerpt" => %{"type" => "string"}
              }
            }
          }
        }
      }
    }
  end
end
