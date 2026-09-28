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

  @type template :: :basic | :advanced | :letterhead

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
