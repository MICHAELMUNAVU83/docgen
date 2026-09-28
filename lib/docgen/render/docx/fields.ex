defmodule Docgen.Render.Docx.Fields do
  @moduledoc """
  Fills document properties used by `DOCPROPERTY` fields.

  Word shows a field's *cached result* until fields are updated, so setting
  the property in `docProps/custom.xml` isn't enough: the cached result text
  of every field referencing it must be rewritten too. Fields may be simple
  (`<w:fldSimple>`) or complex (`fldChar` begin/separate/end, possibly nested
  — the GS1 cover uses `IF {DOCPROPERTY …} <> "" "{DOCPROPERTY …}" ""`).

  The XML is tokenized into field markers and text runs and walked with a
  stack of open fields; the first result text of a field that refers to a
  property gets the new value, and its other result texts are emptied.
  """

  alias Docgen.Render.Docx.Xml

  @token ~r{<w:fldChar\b[^>]*w:fldCharType="(?:begin|separate|end)"[^>]*/>|<w:instrText\b[^>]*>.*?</w:instrText>|<w:instrText\b[^>]*/>|<w:t\b[^>]*>.*?</w:t>|<w:t\b[^>]*/>|<w:fldSimple\b[^>]*>|</w:fldSimple>}s

  @doc """
  Rewrites cached `DOCPROPERTY` results in a document/header/footer part.
  `values` maps property names (e.g. `"GS1 DocName"`) to text.
  """
  @spec fill(String.t(), %{String.t() => String.t()}) :: String.t()
  def fill(xml, values) when map_size(values) == 0, do: xml

  def fill(xml, values) do
    {parts, _stack} =
      @token
      |> Regex.split(xml, include_captures: true)
      |> Enum.map_reduce([], &token(&1, &2, values))

    IO.iodata_to_binary(parts)
  end

  # Each open field: %{instr: iodata, phase: :instr | :result, value: nil | String.t(), written?: bool}
  defp token(<<"<w:fldChar", _::binary>> = tag, stack, values) do
    cond do
      tag =~ ~s(w:fldCharType="begin") ->
        {tag, [new_field() | stack]}

      tag =~ ~s(w:fldCharType="separate") ->
        case stack do
          [field | rest] ->
            {tag, [%{field | phase: :result, value: value_for(field.instr, values)} | rest]}

          [] ->
            {tag, stack}
        end

      true ->
        case stack do
          [field | rest] -> {tag, add_instr(rest, field.instr)}
          [] -> {tag, stack}
        end
    end
  end

  defp token(<<"<w:fldSimple", _::binary>> = tag, stack, values) do
    instr =
      case Regex.run(~r/w:instr="([^"]*)"/, tag) do
        [_, instr] -> unescape(instr)
        nil -> ""
      end

    field = %{new_field() | instr: [instr], phase: :result, value: value_for([instr], values)}
    {tag, [field | stack]}
  end

  defp token("</w:fldSimple>" = tag, [field | rest], _values),
    do: {tag, add_instr(rest, field.instr)}

  defp token(<<"<w:instrText", _::binary>> = tag, stack, _values) do
    case stack do
      # A simple field's cached result can live in instrText (inside an outer
      # field's instruction); treat it like result text.
      [%{phase: :result, value: value} = field | rest] when is_binary(value) ->
        {replace_text(tag, field), [%{field | written?: true} | rest]}

      [%{phase: :instr} = field | rest] ->
        {tag, [%{field | instr: [field.instr, text_of(tag)]} | rest]}

      _ ->
        {tag, stack}
    end
  end

  defp token(<<"<w:t", rest::binary>> = tag, stack, _values)
       when binary_part(rest, 0, 1) in [">", " ", "/"] do
    case stack do
      [%{phase: :result, value: value} = field | rest] when is_binary(value) ->
        {replace_text(tag, field), [%{field | written?: true} | rest]}

      _ ->
        {tag, stack}
    end
  end

  defp token(other, stack, _values), do: {other, stack}

  defp new_field, do: %{instr: [], phase: :instr, value: nil, written?: false}

  # A finished nested field's instruction becomes part of its parent's, so an
  # IF field "knows" which property it tests.
  defp add_instr([parent | rest], instr),
    do: [%{parent | instr: [parent.instr, " ", instr]} | rest]

  defp add_instr([], _instr), do: []

  defp value_for(instr, values) do
    instr = IO.iodata_to_binary(instr)

    Enum.find_value(values, fn {name, value} ->
      if Regex.match?(~r/DOCPROPERTY\s+"#{Regex.escape(name)}"/, instr), do: value
    end)
  end

  defp replace_text(tag, %{written?: true}), do: set_text(tag, "")
  defp replace_text(tag, %{value: value}), do: set_text(tag, value)

  defp set_text(tag, text) do
    [open | _] = String.split(tag, ">", parts: 2)
    open = String.trim_trailing(open, "/")
    name = if String.starts_with?(open, "<w:instrText"), do: "w:instrText", else: "w:t"
    open = if open =~ "xml:space", do: open, else: open <> ~s( xml:space="preserve")
    "#{open}>#{Xml.escape(text)}</#{name}>"
  end

  defp text_of(tag) do
    case Regex.run(~r/>(.*)</s, tag) do
      [_, text] -> unescape(text)
      nil -> ""
    end
  end

  defp unescape(text) do
    text
    |> String.replace("&quot;", "\"")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&apos;", "'")
    |> String.replace("&amp;", "&")
  end

  @doc """
  Sets custom document properties in `docProps/custom.xml`.
  """
  @spec set_properties(String.t(), %{String.t() => String.t()}) :: String.t()
  def set_properties(xml, values) do
    Enum.reduce(values, xml, fn {name, value}, xml ->
      Regex.replace(
        ~r{(<property\b[^>]*\bname="#{Regex.escape(name)}"[^>]*>\s*<vt:lpwstr>).*?(</vt:lpwstr>)}s,
        xml,
        fn _, open, close -> open <> Xml.escape(value) <> close end
      )
    end)
  end
end
