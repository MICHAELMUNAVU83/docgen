defmodule Docgen.Render.Docx.Context do
  @moduledoc """
  State threaded through `Docgen.Render.Docx.Xml` while rendering a body.

    * `links` — `{relationship_id, url}` for every external hyperlink
    * `numbered_lists` — `{num_id, ilvl, :number | :bullet}` for every list
      needing its own numbering instance; each gets
      its own `<w:num>` in `numbering.xml`
    * `images` — `{relationship_id, part_name, image}` for every embedded image
    * `headings` — `%{level, number, text, bookmark}` for table-of-contents
      entries (reversed)
    * `heading_counters` / `captions` — running heading and caption numbers
  """

  alias Docgen.Template.StyleMap

  @type t :: %__MODULE__{
          styles: StyleMap.t(),
          text_width: pos_integer(),
          links: [{String.t(), String.t()}],
          next_link: pos_integer(),
          numbered_lists: [{pos_integer(), non_neg_integer(), :number | :bullet}],
          next_num_id: pos_integer(),
          images: [{String.t(), String.t(), Docgen.Image.t()}],
          headings: [map()],
          heading_counters: [non_neg_integer()],
          captions: %{optional(:figure | :table) => pos_integer()}
        }

  defstruct styles: %{},
            text_width: 9000,
            links: [],
            next_link: 1,
            numbered_lists: [],
            next_num_id: 1,
            images: [],
            headings: [],
            heading_counters: [],
            captions: %{}

  @spec new(StyleMap.t(), keyword()) :: t()
  def new(styles, opts \\ []), do: struct!(__MODULE__, [styles: styles] ++ opts)
end
