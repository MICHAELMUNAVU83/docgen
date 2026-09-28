defmodule Docgen.AI.Plan do
  @moduledoc "A validated, reviewable document-design recommendation."

  @type template :: :basic | :advanced | :letterhead
  @type chart_type :: :bar | :line | :donut | :none

  @type chart :: %{
          type: chart_type(),
          title: String.t(),
          reason: String.t(),
          source_excerpt: String.t()
        }

  @type t :: %__MODULE__{
          template: template(),
          template_reason: String.t(),
          cover_asset: String.t(),
          asset_reason: String.t(),
          charts: [chart()],
          summary: String.t(),
          source: :ai | :rules
        }

  defstruct template: :basic,
            template_reason: "",
            cover_asset: "corporate",
            asset_reason: "",
            charts: [],
            summary: "",
            source: :rules
end
