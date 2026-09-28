defmodule Docgen.Ingest.Xml do
  @moduledoc """
  Parses untrusted XML into a lightweight element tree.

  Built on `:xmerl_sax_parser`, which reports names as strings — unlike
  `:xmerl_scan`, which creates an atom per distinct tag/attribute and could
  exhaust the atom table on hostile input. Documents with a DOCTYPE are
  rejected to rule out entity-expansion attacks.

  Elements are `{ns, name, attrs, children}`:

    * `ns` — a known namespace atom (`:w`, `:r`, `:a`, `:pic`, `:wp`, `:mc`,
      `:v`, `:rel`) or `nil`
    * `name` — local name, e.g. `"p"`
    * `attrs` — map keyed by local name; attributes in the relationships
      namespace are keyed `"r:<name>"` (e.g. `"r:id"`)
    * `children` — elements and text binaries
  """

  @namespaces %{
    "http://schemas.openxmlformats.org/wordprocessingml/2006/main" => :w,
    "http://purl.oclc.org/ooxml/wordprocessingml/main" => :w,
    "http://schemas.openxmlformats.org/officeDocument/2006/relationships" => :r,
    "http://purl.oclc.org/ooxml/officeDocument/relationships" => :r,
    "http://schemas.openxmlformats.org/drawingml/2006/main" => :a,
    "http://schemas.openxmlformats.org/drawingml/2006/picture" => :pic,
    "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" => :wp,
    "http://schemas.openxmlformats.org/markup-compatibility/2006" => :mc,
    "http://schemas.openxmlformats.org/package/2006/relationships" => :rel,
    "urn:schemas-microsoft-com:vml" => :v
  }

  @type element ::
          {atom() | nil, String.t(), %{String.t() => String.t()}, [element() | String.t()]}

  @doc """
  Parses `xml` into its root element.

  ## Options

    * `:allow_doctype` — skip the DOCTYPE check, for trusted tool output
      (the declaration is removed before parsing)
  """
  @spec parse(binary(), keyword()) :: {:ok, element()} | {:error, term()}
  def parse(xml, opts \\ []) when is_binary(xml) do
    with {:ok, xml} <- check_doctype(xml, opts) do
      try do
        case :xmerl_sax_parser.stream(xml, event_fun: &event/3, event_state: []) do
          {:ok, [root], _rest} -> {:ok, root}
          {:ok, _state, _rest} -> {:error, :no_root_element}
          {_tag, _location, reason, _end_tags, _state} -> {:error, {:invalid_xml, reason}}
        end
      catch
        kind, reason -> {:error, {:invalid_xml, {kind, reason}}}
      end
    end
  end

  defp check_doctype(xml, opts) do
    cond do
      :binary.match(xml, "<!DOCTYPE") == :nomatch ->
        {:ok, xml}

      Keyword.get(opts, :allow_doctype, false) ->
        {:ok, Regex.replace(~r/<!DOCTYPE[^>\[]*(\[[^\]]*\])?\s*>/, xml, "")}

      true ->
        {:error, :doctype_not_allowed}
    end
  end

  ## SAX events → tree (state is a stack of open elements)

  defp event({:startElement, uri, local, _qname, attributes}, _location, stack) do
    [{namespace(uri), List.to_string(local), attrs(attributes), []} | stack]
  end

  defp event({:endElement, _uri, _local, _qname}, _location, [element | stack]) do
    {ns, name, attrs, children} = element
    element = {ns, name, attrs, Enum.reverse(children)}

    case stack do
      [] ->
        [element]

      [{pns, pname, pattrs, pchildren} | rest] ->
        [{pns, pname, pattrs, [element | pchildren]} | rest]
    end
  end

  # Whitespace-only text (e.g. a Word run holding a single space) is reported
  # as ignorable whitespace; it is content here.
  defp event({:ignorableWhitespace, chars}, location, stack),
    do: event({:characters, chars}, location, stack)

  defp event({:characters, chars}, _location, [{ns, name, attrs, children} | stack]) do
    text = List.to_string(chars)

    children =
      case children do
        [prev | rest] when is_binary(prev) -> [prev <> text | rest]
        _ -> [text | children]
      end

    [{ns, name, attrs, children} | stack]
  end

  defp event(_event, _location, stack), do: stack

  defp namespace(uri), do: Map.get(@namespaces, List.to_string(uri))

  defp attrs(attributes) do
    Map.new(attributes, fn {uri, _prefix, name, value} ->
      key =
        case namespace(uri) do
          :r -> "r:" <> List.to_string(name)
          _ -> List.to_string(name)
        end

      {key, List.to_string(value)}
    end)
  end

  ## Navigation helpers

  @doc "Child elements of `element`, optionally filtered by namespace and name."
  @spec children(element()) :: [element()]
  def children({_, _, _, children}), do: for(child <- children, is_tuple(child), do: child)

  @spec children(element(), atom() | nil, String.t()) :: [element()]
  def children(element, ns, name) do
    for {^ns, ^name, _, _} = child <- children(element), do: child
  end

  @doc "First child element with `ns`/`name`, or `nil`."
  @spec child(element() | nil, atom() | nil, String.t()) :: element() | nil
  def child(nil, _ns, _name), do: nil
  def child(element, ns, name), do: element |> children(ns, name) |> List.first()

  @doc "Follows a path of `{ns, name}` steps through first children."
  @spec path(element() | nil, [{atom() | nil, String.t()}]) :: element() | nil
  def path(element, steps),
    do: Enum.reduce(steps, element, fn {ns, name}, el -> child(el, ns, name) end)

  @doc "Attribute value, or `nil`."
  @spec attr(element() | nil, String.t()) :: String.t() | nil
  def attr(nil, _key), do: nil
  def attr({_, _, attrs, _}, key), do: Map.get(attrs, key)

  @doc "All descendant elements with `ns`/`name`, depth-first."
  @spec descendants(element(), atom() | nil, String.t()) :: [element()]
  def descendants(element, ns, name) do
    Enum.flat_map(children(element), fn
      {^ns, ^name, _, _} = child -> [child | descendants(child, ns, name)]
      child -> descendants(child, ns, name)
    end)
  end

  @doc "Concatenated text content of `element` and its descendants."
  @spec text(element() | String.t()) :: String.t()
  def text(text) when is_binary(text), do: text
  def text({_, _, _, children}), do: Enum.map_join(children, &text/1)
end
