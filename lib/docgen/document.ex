defmodule Docgen.Document do
  @moduledoc """
  Intermediate representation (IR) every input is normalised into.

  Renderers only ever see this structure, never the original source.

  ## Blocks

    * `{:heading, level, inlines}` — `level` is 1..7
    * `{:paragraph, inlines}`
    * `{:bullet_list, level, items}` / `{:numbered_list, level, items}` —
      each item is `{inlines, nested_lists}`, where `nested_lists` are list
      blocks with `level + 1`
    * `{:table, header_rows, rows}` — a row is a list of cells, a cell is a
      list of inlines
    * `{:note, inlines}` / `{:important, inlines}`
    * `{:caption, :table, inlines}` — caption of the table that follows
    * `{:code_block, text}`
    * `{:image, image, caption}` — `image` is a `t:Docgen.Image.t/0`; `caption`
      may be `nil`
    * `:page_break`

  ## Inlines

    * `{:text, string}` — `"\\n"` inside the string is a line break
    * `{:bold, inlines}` / `{:italic, inlines}`
    * `{:link, url, inlines}`
    * `{:code, string}`
  """

  @type inline ::
          {:text, String.t()}
          | {:bold, [inline()]}
          | {:italic, [inline()]}
          | {:link, String.t(), [inline()]}
          | {:code, String.t()}

  @type list_block ::
          {:bullet_list, pos_integer(), [list_item()]}
          | {:numbered_list, pos_integer(), [list_item()]}

  @type list_item :: {[inline()], [list_block()]}

  @type row :: [[inline()]]

  @type block ::
          {:heading, 1..7, [inline()]}
          | {:paragraph, [inline()]}
          | list_block()
          | {:table, [row()], [row()]}
          | {:note, [inline()]}
          | {:important, [inline()]}
          | {:caption, :table, [inline()]}
          | {:code_block, String.t()}
          | {:image, Docgen.Image.t(), String.t() | nil}
          | :page_break

  @type template :: :basic | :advanced | :letterhead | :presentation

  @type t :: %__MODULE__{
          template: template(),
          meta: map(),
          blocks: [block()],
          warnings: [String.t()]
        }

  defstruct template: :basic, meta: %{}, blocks: [], warnings: []

  @doc """
  Flattens inlines to plain text, dropping formatting.
  """
  @spec plain_text([inline()]) :: String.t()
  def plain_text(inlines) do
    inlines
    |> Enum.map(fn
      {:text, text} -> text
      {:code, text} -> text
      {:link, _url, children} -> plain_text(children)
      {_format, children} -> plain_text(children)
    end)
    |> Enum.join()
  end

  @doc """
  Moves a leading level-1 heading into `meta.title` when it is the document's
  only level-1 heading and no title has been set.
  """
  @spec promote_title(t()) :: t()
  def promote_title(%__MODULE__{blocks: [{:heading, 1, inlines} | rest]} = doc) do
    only_h1? = not Enum.any?(rest, &match?({:heading, 1, _}, &1))

    if only_h1? and blank?(doc.meta[:title]) do
      %{doc | meta: Map.put(doc.meta, :title, plain_text(inlines)), blocks: rest}
    else
      doc
    end
  end

  def promote_title(doc), do: doc

  @doc """
  Turns section titles written as one-item numbered lists — `1. **Scope**`
  on its own, then text, then `2. **Terms**` — into headings, numbered in
  order ("1. Scope", "2. Terms") whatever numbers the source used. Needs
  at least two such titles; a list with several bold items stays a list.
  """
  @spec promote_numbered_titles(t()) :: t()
  def promote_numbered_titles(%__MODULE__{blocks: blocks} = doc) do
    if Enum.count(blocks, &numbered_title/1) >= 2 do
      level =
        case for({:heading, level, _} <- blocks, do: level) do
          [] -> 1
          levels -> Enum.min(levels)
        end

      {blocks, _n} =
        Enum.map_reduce(blocks, 1, fn block, n ->
          case numbered_title(block) do
            nil -> {block, n}
            title -> {{:heading, level, [{:text, "#{n}. #{title}"}]}, n + 1}
          end
        end)

      %{doc | blocks: blocks}
    else
      doc
    end
  end

  defp numbered_title({:numbered_list, 1, [{[{:bold, inlines}], []}]}) do
    title = inlines |> plain_text() |> String.trim()
    if title != "" and not (title =~ ~r/[.,;:]\z/), do: title
  end

  defp numbered_title(_block), do: nil

  @doc """
  Removes a typed number ("2.", "2.1", "3)") from the start of heading text,
  for templates that number headings themselves.
  """
  @spec strip_heading_number([inline()]) :: [inline()]
  def strip_heading_number([{:text, text} | rest] = inlines) do
    case Regex.run(~r/\A\s*\d{1,3}(?:\.\d{1,3})*[.)]?\s+(?=\S)/u, text) do
      [prefix] when rest != [] or byte_size(prefix) < byte_size(text) ->
        [
          {:text, binary_part(text, byte_size(prefix), byte_size(text) - byte_size(prefix))}
          | rest
        ]

      _ ->
        inlines
    end
  end

  def strip_heading_number(inlines), do: inlines

  @doc """
  Shifts heading levels so the shallowest heading becomes level 1.
  """
  @spec normalize_headings([block()]) :: [block()]
  def normalize_headings(blocks) do
    case for({:heading, level, _} <- blocks, do: level) do
      [] ->
        blocks

      levels ->
        shift = Enum.min(levels) - 1

        Enum.map(blocks, fn
          {:heading, level, inlines} -> {:heading, level - shift, inlines}
          block -> block
        end)
    end
  end

  @doc """
  Merges `meta` into the document's metadata, ignoring blank values.
  """
  @spec put_meta(t(), map() | keyword()) :: t()
  def put_meta(doc, meta) do
    meta = for {key, value} <- meta, not blank?(value), into: %{}, do: {key, value}
    %{doc | meta: Map.merge(doc.meta, meta)}
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
end
