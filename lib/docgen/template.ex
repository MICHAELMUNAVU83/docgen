defmodule Docgen.Template do
  @moduledoc """
  A GS1 Word template (`priv/templates/*.dotm`) unzipped in memory.

  `parts` maps OOXML part names (e.g. `"word/document.xml"`) to their
  contents; `order` keeps the original zip entry order for re-packing.
  """

  @templates [:basic, :advanced, :letterhead]

  @type t :: %__MODULE__{
          name: Docgen.Document.template(),
          parts: %{String.t() => binary()},
          order: [String.t()]
        }

  defstruct [:name, parts: %{}, order: []]

  @doc "Names of the bundled templates."
  @spec names() :: [Docgen.Document.template()]
  def names, do: @templates

  @doc "Path of the bundled `.dotm` for `name`."
  @spec path(Docgen.Document.template()) :: String.t()
  def path(name) when name in @templates do
    Application.app_dir(:docgen, "priv/templates/#{name}.dotm")
  end

  @doc """
  Loads and unzips the bundled template `name`.
  """
  @spec load(atom()) :: {:ok, t()} | {:error, term()}
  def load(name) when name in @templates do
    with {:ok, zip} <- File.read(path(name)),
         {:ok, entries} <- :zip.unzip(zip, [:memory]) do
      entries = Enum.map(entries, fn {entry, data} -> {to_string(entry), data} end)

      {:ok,
       %__MODULE__{name: name, parts: Map.new(entries), order: Enum.map(entries, &elem(&1, 0))}}
    end
  end

  def load(name), do: {:error, {:unknown_template, name}}

  @doc """
  Industry icons bundled for the GS1 Advanced cover (`priv/templates/icons`),
  as `{slug, label}` sorted by label.
  """
  @spec cover_icons() :: [{String.t(), String.t()}]
  def cover_icons do
    Application.app_dir(:docgen, "priv/templates/icons")
    |> Path.join("*.png")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      slug = Path.basename(path, ".png")
      label = slug |> String.split("_") |> Enum.map_join(" ", &label_word/1)
      {slug, label}
    end)
    |> Enum.sort_by(&elem(&1, 1))
  end

  defp label_word(word) when word in ~w(and), do: word
  defp label_word(word) when word in ~w(cpg diy), do: String.upcase(word)
  defp label_word(word), do: String.capitalize(word)

  @doc "PNG data of a bundled cover icon. Only known slugs are accepted."
  @spec cover_icon(String.t()) :: {:ok, binary()} | :error
  def cover_icon(slug) when is_binary(slug) do
    with true <- Enum.any?(cover_icons(), fn {known, _label} -> known == slug end),
         {:ok, png} <- File.read(Application.app_dir(:docgen, "priv/templates/icons/#{slug}.png")) do
      {:ok, png}
    else
      _ -> :error
    end
  end

  def cover_icon(_slug), do: :error

  @doc "Returns the contents of part `name`, or `nil`."
  @spec part(t(), String.t()) :: binary() | nil
  def part(%__MODULE__{parts: parts}, name), do: Map.get(parts, name)

  @doc "Replaces (or adds) part `name`."
  @spec put_part(t(), String.t(), binary()) :: t()
  def put_part(%__MODULE__{} = template, name, data) do
    order =
      if Map.has_key?(template.parts, name), do: template.order, else: template.order ++ [name]

    %{template | parts: Map.put(template.parts, name, data), order: order}
  end

  @doc "Applies `fun` to part `name` if it exists."
  @spec update_part(t(), String.t(), (binary() -> binary())) :: t()
  def update_part(%__MODULE__{} = template, name, fun) do
    case part(template, name) do
      nil -> template
      data -> put_part(template, name, fun.(data))
    end
  end

  @doc "Removes every part for which `fun` returns true."
  @spec reject_parts(t(), (String.t() -> boolean())) :: t()
  def reject_parts(%__MODULE__{} = template, fun) do
    {removed, kept} = Enum.split_with(template.order, fun)
    %{template | parts: Map.drop(template.parts, removed), order: kept}
  end

  @doc """
  Paragraph/character/table style IDs defined in `word/styles.xml`.
  """
  @spec style_ids(t()) :: MapSet.t(String.t())
  def style_ids(%__MODULE__{} = template) do
    ~r/<w:style\b[^>]*\bw:styleId="([^"]+)"/
    |> Regex.scan(part(template, "word/styles.xml") || "", capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end

  @doc """
  Zips the parts back into a package binary, `[Content_Types].xml` first.
  """
  @spec to_zip(t()) :: {:ok, binary()} | {:error, term()}
  def to_zip(%__MODULE__{} = template) do
    {types, rest} = Enum.split_with(template.order, &(&1 == "[Content_Types].xml"))

    entries =
      for name <- types ++ rest do
        {String.to_charlist(name), Map.fetch!(template.parts, name)}
      end

    case :zip.create(~c"document.docx", entries, [:memory]) do
      {:ok, {_name, binary}} -> {:ok, binary}
      {:error, reason} -> {:error, reason}
    end
  end
end
