defmodule Docgen.Template.StyleMap do
  @moduledoc """
  Per-template rendering configuration: which style ID each IR block uses
  (`styles`, all defined in the template's `styles.xml`) plus layout
  `options`.

  Style keys:

    * `:title`, `:subtitle` — from `meta` (`nil` when the template has a
      cover page instead)
    * `{:heading, level}`, `:paragraph`, `:note`, `:important`, `:code_block`
    * `:caption_figure`, `:caption_table`
    * `{:bullet, level}` — styles that carry their own bullet numbering
    * `{:number, level}` — numbered list paragraphs
    * `:table`, `:table_text`, `:table_heading`
    * `:code_char` — character style for inline code (`nil` → monospace font)

  Options:

    * `:numbering` — `:generated` (Docgen's own multi-level definition) or
      `{:template, num_id}` to restart the template's list definition
    * `:table_header_fill` — shading for header cells, or `nil` when the
      table style provides it
    * `:caption_labels` — prefix captions with numbered `Figure N:` / `Table N:`
    * `:front_matter_until` — keep the template body up to and including the
      paragraph with this style (cover, summary, TOC heading); `nil` replaces
      the whole body
    * `:toc` — generate a table of contents after the front matter
    * `:generated_bullets` — attach generated bullet numbering (for templates
      without bullet styles)
    * `:bold_headings` — render headings bold (for templates without heading
      styles)
    * `:branding` — parts localised by `Docgen.Render.Docx.Branding`
      (`:logo_media`, `:address_part`)
    * `:letter` — fill the template's letter content controls instead of
      replacing its body (see `Docgen.Render.Docx.Letter`)
    * `:normalize_headings` — shift heading levels so the shallowest becomes
      level 1 (for auto-numbered headings, where a document starting at
      level 2 would otherwise read "0.1")
  """

  @basic %{
    styles: %{
      title: "GS1BTitle",
      subtitle: "GS1BSubtitle",
      headings: ~w(Heading1 Heading2 Heading3 Heading4 Heading5 Heading6 Heading7),
      paragraph: "BodyText",
      note: "BodyText2",
      important: "BodyText2",
      code_block: "NoSpacing",
      caption_figure: "BodyText",
      caption_table: "BodyText",
      bullets: ~w(ListBullet ListBullet2 ListBullet3),
      numbers: ~w(ListNumber),
      table: "TableGrid",
      table_text: "NoSpacing",
      table_heading: "NoSpacing",
      code_char: nil
    },
    options: %{
      numbering: :generated,
      table_header_fill: "002C6C",
      caption_labels: false,
      front_matter_until: nil,
      toc: false,
      normalize_headings: false,
      generated_bullets: false,
      bold_headings: false,
      letter: false,
      branding: %{logo_media: "word/media/image1.png"}
    }
  }

  @advanced %{
    styles: %{
      title: nil,
      subtitle: nil,
      headings: ~w(Heading1 Heading2 Heading3 Heading4 Heading5 Heading6),
      paragraph: "GS1Body",
      note: "GS1Note",
      important: "GS1Important",
      code_block: "GS1CodeBlock",
      caption_figure: "GS1CaptionFigure",
      caption_table: "GS1CaptionTable",
      bullets: ~w(GS1Bullet1 GS1Bullet2 GS1Bullet3 GS1Bullet4),
      numbers: ~w(GS1List1 GS1List2 GS1List3 GS1List4),
      table: "GS1Table",
      table_text: "GS1TableText",
      table_heading: "GS1TableHeading",
      code_char: "GS1Code"
    },
    options: %{
      numbering: {:template, "28"},
      table_header_fill: nil,
      caption_labels: true,
      front_matter_until: "GS1TOCHeading",
      toc: true,
      normalize_headings: true,
      generated_bullets: false,
      bold_headings: false,
      letter: false,
      branding: %{logo_media: "word/media/image5.jpg"}
    }
  }

  @letterhead %{
    styles: %{
      title: nil,
      subtitle: nil,
      headings: ~w(BodyText2),
      paragraph: "BodyText2",
      note: "BodyText2",
      important: "BodyText2",
      code_block: "NoSpacing",
      caption_figure: "BodyText2",
      caption_table: "BodyText2",
      bullets: ~w(BodyText2),
      numbers: ~w(BodyText2),
      table: "TableGrid",
      table_text: "NoSpacing",
      table_heading: "NoSpacing",
      code_char: nil
    },
    options: %{
      numbering: :generated,
      table_header_fill: "002C6C",
      caption_labels: false,
      front_matter_until: nil,
      toc: false,
      normalize_headings: false,
      generated_bullets: true,
      bold_headings: true,
      letter: true,
      branding: %{logo_media: "word/media/image1.png", address_part: "word/footer3.xml"}
    }
  }

  @maps %{basic: @basic, advanced: @advanced, letterhead: @letterhead}

  @type t :: %{styles: map(), options: map()}
  @type key ::
          :title
          | :subtitle
          | {:heading, pos_integer()}
          | :paragraph
          | :note
          | :important
          | :code_block
          | :caption_figure
          | :caption_table
          | {:bullet, pos_integer()}
          | {:number, pos_integer()}
          | :table
          | :table_text
          | :table_heading
          | :code_char

  @doc "Returns the configuration for `template`."
  @spec fetch(atom()) :: {:ok, t()} | {:error, {:unsupported_template, atom()}}
  def fetch(template) do
    case Map.fetch(@maps, template) do
      {:ok, map} -> {:ok, map}
      :error -> {:error, {:unsupported_template, template}}
    end
  end

  @doc """
  Style ID for `key` (may be `nil`). Levels beyond what the template defines
  use the deepest available style.
  """
  @spec style(t(), key()) :: String.t() | nil
  def style(%{styles: styles}, {:heading, level}), do: at_level(styles.headings, level)
  def style(%{styles: styles}, {:bullet, level}), do: at_level(styles.bullets, level)
  def style(%{styles: styles}, {:number, level}), do: at_level(styles.numbers, level)
  def style(%{styles: styles}, key), do: Map.fetch!(styles, key)

  @doc "Layout option `key`."
  @spec option(t(), atom()) :: term()
  def option(%{options: options}, key), do: Map.fetch!(options, key)

  @doc "Every style ID referenced by `map`."
  @spec style_ids(t()) :: [String.t()]
  def style_ids(%{styles: styles}) do
    styles |> Map.values() |> List.flatten() |> Enum.filter(&is_binary/1) |> Enum.uniq()
  end

  defp at_level(styles, level), do: Enum.at(styles, min(max(level, 1), length(styles)) - 1)
end
