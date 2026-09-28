defmodule Docgen.Render.Pptx.Deck do
  @moduledoc """
  Plans the slides of a presentation from a `Docgen.Document`.

  Shared by the `.pptx` renderer and the HTML preview, so both show the
  same slides. The deck is:

    * a **title slide** from `meta` (`:title` — or else the first heading —
      `:subtitle`, `:presenter`, `:date`; `:cover` picks the photo, see
      `photos/0`)
    * **sections** — when the document has two or more top-level headings
      with subheadings below them, each top-level heading becomes a divider
      slide and each subheading a content slide; three or more sections also
      get an **agenda** slide. Otherwise every top-level heading starts a
      content slide.
    * **content slides** — paragraphs, lists, notes and code. Headings below
      the slide level become bold subheadings. Content that doesn't fit is
      continued on further slides ("Title (continued)").
    * **table** and **image** slides — one per table (long tables continue
      over several slides, repeating the header) and per image (SVG images,
      which PowerPoint can't show without a PNG fallback, keep only their
      caption)
    * `:page_break` starts a new slide

  Slide sizes are estimates for the GS1 layouts (Verdana 15 pt body text on
  a 16:9 slide); the renderer also turns on shrink-on-overflow as a
  fallback.
  """

  alias Docgen.Document

  @type slide ::
          %{
            kind: :title,
            title: String.t(),
            subtitle: String.t(),
            presenter: String.t(),
            date: String.t(),
            photo: String.t()
          }
          | %{kind: :agenda, title: String.t(), items: [String.t()]}
          | %{kind: :section, title: String.t()}
          | %{kind: :content, title: String.t(), blocks: [block()]}
          | %{
              kind: :table,
              title: String.t(),
              caption: String.t() | nil,
              header_rows: [Document.row()],
              rows: [Document.row()]
            }
          | %{kind: :image, title: String.t(), image: Docgen.Image.t(), caption: String.t() | nil}

  @typedoc """
  Content slide blocks: IR blocks, plus `{:subheading, inlines}` and
  `{:numbered_list, level, items, start}` for a numbered list continued
  from the previous slide.
  """
  @type block ::
          Document.block()
          | {:subheading, [Document.inline()]}
          | {:numbered_list, pos_integer(), [Document.list_item()], pos_integer()}

  @photos [
    {"photo1", "Technology"},
    {"photo2", "Retail"},
    {"photo3", "Business"},
    {"photo4", "Healthcare"},
    {"photo5", "Agriculture"},
    {"photo6", "Logistics"}
  ]

  @default_photo "photo1"

  # Body text area of the "Text Only" layout, in points: 15 pt Verdana
  # (~78 characters a line) with 110% line spacing and 4 pt between
  # paragraphs, in a 261 pt high box.
  @line_height 16.5
  @paragraph_space 4
  @body_height 255
  @chars_per_line 76
  @chars_per_indent 5
  @code_line_height 14

  # Table area below the title: 11 pt text, ~245 pt high, 649 pt wide.
  @table_height 235
  @table_caption_height 22
  @table_line_height 14
  @table_row_padding 8
  @table_chars_per_point 1 / 6.2

  @doc "Title slide photos: `{slug, label}`, plus `\"none\"` for no photo."
  @spec photos() :: [{String.t(), String.t()}]
  def photos, do: @photos

  @doc "Plans the slides of `doc`."
  @spec build(Document.t()) :: [slide()]
  def build(%Document{} = doc) do
    blocks = Document.normalize_headings(doc.blocks)
    sectioned? = sectioned?(blocks)
    slide_level = if sectioned?, do: 2, else: 1
    fallback_title = present(doc.meta[:title]) || ""

    {slides, state} =
      Enum.reduce(blocks, {[], new_state(fallback_title)}, fn block, {slides, state} ->
        add_block(block, slides, state, sectioned?, slide_level)
      end)

    slides = Enum.reverse(flush(slides, state))
    sections = for %{kind: :section, title: title} <- slides, do: title

    [title_slide(doc.meta, blocks)] ++
      if(sectioned? and length(sections) >= 3,
        do: [%{kind: :agenda, title: "Agenda", items: sections}],
        else: []
      ) ++ slides
  end

  defp sectioned?(blocks) do
    Enum.count(blocks, &match?({:heading, 1, _}, &1)) >= 2 and
      Enum.any?(blocks, &match?({:heading, level, _} when level > 1, &1))
  end

  # Without a title, the deck is named after its first heading.
  defp title_slide(meta, blocks) do
    first_heading =
      Enum.find_value(blocks, fn
        {:heading, _level, inlines} -> present(heading_text(inlines))
        _ -> nil
      end)

    photo =
      case meta[:cover] do
        "none" -> "none"
        slug when is_binary(slug) -> if(List.keymember?(@photos, slug, 0), do: slug)
        _ -> nil
      end

    %{
      kind: :title,
      title: present(meta[:title]) || first_heading || "Untitled presentation",
      subtitle: present(meta[:subtitle]) || "",
      presenter: present(meta[:presenter]) || "",
      date: format_date(meta[:date]),
      photo: photo || @default_photo
    }
  end

  ## Building

  # `title` is the title of the slide being filled, `blocks` its content so
  # far (reversed), `caption` a pending table caption and `page` the number
  # of slides already made under this title by page breaks.
  defp new_state(title), do: %{title: title, blocks: [], caption: nil, page: 0}

  defp add_block({:heading, 1, inlines}, slides, state, true, _slide_level) do
    title = heading_text(inlines)
    slides = flush(slides, state)

    {[%{kind: :section, title: title} | slides],
     %{state | title: title, blocks: [], caption: nil, page: 0}}
  end

  defp add_block({:heading, level, inlines}, slides, state, _sectioned?, slide_level)
       when level <= slide_level do
    {flush(slides, state),
     %{state | title: heading_text(inlines), blocks: [], caption: nil, page: 0}}
  end

  defp add_block({:heading, _level, inlines}, slides, state, _sectioned?, _slide_level),
    do: {slides, push(state, {:subheading, inlines})}

  defp add_block({:caption, :table, inlines}, slides, state, _sectioned?, _slide_level),
    do: {slides, %{state | caption: Document.plain_text(inlines)}}

  defp add_block({:table, header_rows, rows}, slides, state, _sectioned?, _slide_level) do
    slides = flush(slides, state)
    caption = state.caption
    title = state.title

    tables =
      rows
      |> table_pages(header_rows, caption)
      |> Enum.with_index()
      |> Enum.map(fn {page_rows, index} ->
        %{
          kind: :table,
          title: continued(title, index),
          caption: caption,
          header_rows: header_rows,
          rows: page_rows
        }
      end)

    {Enum.reverse(tables, slides), %{state | blocks: [], caption: nil}}
  end

  # PowerPoint shows SVG only with a PNG fallback, which we can't make.
  defp add_block({:image, %{content_type: "image/svg+xml"}, caption}, slides, state, _s, _l) do
    case present(caption) do
      nil -> {slides, state}
      caption -> {slides, push(state, {:paragraph, [{:italic, [{:text, caption}]}]})}
    end
  end

  defp add_block({:image, image, caption}, slides, state, _sectioned?, _slide_level) do
    slides = flush(slides, state)
    caption = present(caption)
    title = if state.title == "", do: caption || "", else: state.title

    {[%{kind: :image, title: title, image: image, caption: caption} | slides],
     %{state | blocks: []}}
  end

  defp add_block(:page_break, slides, %{blocks: []} = state, _sectioned?, _slide_level),
    do: {slides, state}

  defp add_block(:page_break, slides, state, _sectioned?, _slide_level) do
    pages = state.blocks |> Enum.reverse() |> paginate() |> length()
    {flush(slides, state), %{state | blocks: [], page: state.page + pages}}
  end

  defp add_block(block, slides, state, _sectioned?, _slide_level),
    do: {slides, push(state, block)}

  defp push(state, block), do: %{state | blocks: [block | state.blocks]}

  # Adds the content collected so far as one or more slides.
  defp flush(slides, %{blocks: []}), do: slides

  defp flush(slides, state) do
    state.blocks
    |> Enum.reverse()
    |> paginate()
    |> Enum.with_index()
    |> Enum.reduce(slides, fn {blocks, index}, slides ->
      [
        %{kind: :content, title: continued(state.title, state.page + index), blocks: blocks}
        | slides
      ]
    end)
  end

  defp continued(title, 0), do: title
  defp continued("", _index), do: ""
  defp continued(title, _index), do: title <> " (continued)"

  defp heading_text(inlines), do: inlines |> Document.plain_text() |> String.trim()

  ## Pagination

  @doc false
  # Splits content blocks into slide-sized pages. Lists split between
  # items; any other block that is too big on its own gets a page to itself.
  @spec paginate([block()]) :: [[block()]]
  def paginate(blocks) do
    {pages, page, _used} =
      blocks
      |> Enum.flat_map(&split_list/1)
      |> Enum.reduce({[], [], 0}, fn block, {pages, page, used} ->
        height = height(block)

        cond do
          page == [] -> {pages, [block], height}
          used + height <= @body_height -> {pages, [block | page], used + height}
          true -> {[Enum.reverse(page) | pages], [block], height}
        end
      end)

    pages = if page == [], do: pages, else: [Enum.reverse(page) | pages]

    pages
    |> Enum.reverse()
    |> Enum.map(&merge_lists/1)
    # A subheading shouldn't be left alone at the bottom of a slide.
    |> keep_subheadings_with_content()
  end

  # Lists are measured item by item so a long list can continue on the next
  # slide; `merge_lists/1` joins the pieces that stay together.
  defp split_list({kind, level, items}) when kind in [:bullet_list, :numbered_list] do
    items
    |> Enum.with_index(1)
    |> Enum.map(fn {item, n} -> {:list_piece, kind, level, n, item} end)
  end

  defp split_list(block), do: [block]

  # Pieces are consecutive items (n, n + 1, …) of the same list.
  defp merge_lists(blocks) do
    blocks
    |> Enum.reduce([], fn
      {:list_piece, kind, level, n, item}, [{:list, kind, level, start, last, items} | acc]
      when n == last + 1 ->
        [{:list, kind, level, start, n, [item | items]} | acc]

      {:list_piece, kind, level, n, item}, acc ->
        [{:list, kind, level, n, n, [item]} | acc]

      block, acc ->
        [block | acc]
    end)
    |> Enum.reverse()
    |> Enum.map(fn
      {:list, kind, level, start, _last, items} -> list_block(kind, level, start, items)
      block -> block
    end)
  end

  # A numbered list continued from the previous slide keeps its numbering.
  defp list_block(:numbered_list, level, start, items) when start > 1,
    do: {:numbered_list, level, Enum.reverse(items), start}

  defp list_block(kind, level, _start, items), do: {kind, level, Enum.reverse(items)}

  defp keep_subheadings_with_content(pages) do
    pages
    |> Enum.reverse()
    |> Enum.reduce([], fn page, later ->
      case {Enum.reverse(page), later} do
        {[{:subheading, _} = sub | [_ | _] = rest], [next | others]} ->
          [Enum.reverse(rest), [sub | next] | others]

        _ ->
          [page | later]
      end
    end)
  end

  defp height({:list_piece, _kind, level, _n, {inlines, nested}}) do
    nested_height =
      nested
      |> Enum.flat_map(&split_list/1)
      |> Enum.map(&height/1)
      |> Enum.sum()

    text_height(Document.plain_text(inlines), level) + nested_height
  end

  defp height({:subheading, inlines}), do: text_height(Document.plain_text(inlines), 0) + 6

  defp height({:code_block, text}),
    do: length(String.split(text, "\n")) * @code_line_height + @paragraph_space

  defp height({_kind, inlines}) when is_list(inlines),
    do: text_height(Document.plain_text(inlines), 0)

  defp height(_block), do: @line_height + @paragraph_space

  defp text_height(text, level) do
    per_line = max(@chars_per_line - level * @chars_per_indent, 20)

    lines =
      text
      |> String.split("\n")
      |> Enum.map(fn line -> max(1, ceil(String.length(line) / per_line)) end)
      |> Enum.sum()

    lines * @line_height + @paragraph_space
  end

  defp table_pages([], _header_rows, _caption), do: [[]]

  defp table_pages(rows, header_rows, caption) do
    columns = rows |> Enum.concat(header_rows) |> Enum.map(&length/1) |> Enum.max(fn -> 1 end)
    chars = 649 * @table_chars_per_point / max(columns, 1)

    budget =
      @table_height - if(caption, do: @table_caption_height, else: 0) -
        Enum.sum(Enum.map(header_rows, &row_height(&1, chars)))

    {pages, page, _used} =
      Enum.reduce(rows, {[], [], 0}, fn row, {pages, page, used} ->
        height = row_height(row, chars)

        if page == [] or used + height <= budget,
          do: {pages, [row | page], used + height},
          else: {[Enum.reverse(page) | pages], [row], height}
      end)

    Enum.reverse([Enum.reverse(page) | pages])
  end

  defp row_height(row, chars_per_line) do
    lines =
      row
      |> Enum.map(fn cell ->
        max(1, ceil(String.length(Document.plain_text(cell)) / max(chars_per_line, 4)))
      end)
      |> Enum.max(fn -> 1 end)

    lines * @table_line_height + @table_row_padding
  end

  ## Helpers

  defp format_date(%Date{} = date), do: Calendar.strftime(date, "%-d %B %Y")

  defp format_date(text) when is_binary(text) do
    case Date.from_iso8601(String.trim(text)) do
      {:ok, date} -> format_date(date)
      _ -> String.trim(text)
    end
  end

  defp format_date(_), do: ""

  defp present(nil), do: nil

  defp present(text) when is_binary(text),
    do: if(String.trim(text) == "", do: nil, else: String.trim(text))

  defp present(_), do: nil
end
