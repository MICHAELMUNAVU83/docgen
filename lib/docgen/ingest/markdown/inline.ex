defmodule Docgen.Ingest.Markdown.Inline do
  @moduledoc """
  Parses Markdown inline syntax into IR inlines.

  Supports backslash escapes, code spans, `**strong**` / `__strong__`,
  `*emphasis*` / `_emphasis_`, `[links](url)`, `<autolinks>`, bare
  `http(s)://` URLs and images (reduced to their alt text).
  """

  alias Docgen.Document

  @punctuation ~c"!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"

  @code ~r/\A(`+)(.+?)(?<!`)\1(?!`)/s
  @image ~r/\A!\[([^\]]*)\]\(\s*<?[^)\s>]*>?(?:\s+"[^"]*")?\s*\)/
  @link ~r/\A\[((?:[^\[\]]|\[[^\[\]]*\])*)\]\(\s*<?([^)\s>]*)>?(?:\s+"[^"]*")?\s*\)/
  @autolink ~r/\A<((?:https?|ftp|mailto):[^\s<>]+)>/
  @bare_url ~r/\Ahttps?:\/\/[^\s<]*[^\s<.,:;"')\]]/
  @strong_em ~r/\A\*\*\*(?=\S)(.+?)(?<=\S)\*\*\*/s
  @strong_star ~r/\A\*\*(?=\S)(.+?)(?<=\S)\*\*(?!\*)/s
  @strong_under ~r/\A__(?=\S)(.+?)(?<=\S)__(?![\p{L}\p{N}])/su
  @em_star ~r/\A\*(?=[^\s*])((?:\*\*.+?\*\*|[^*])+?)(?<=\S)\*(?!\*)/s
  @em_under ~r/\A_(?=\S)((?:__.+?__|[^_])+?)(?<=\S)_(?![\p{L}\p{N}])/su

  @spec parse(String.t()) :: [Document.inline()]
  def parse(text), do: parse(text, [], "")

  defp parse("", acc, buf), do: acc |> flush(buf) |> Enum.reverse()

  defp parse(<<?\\, c, rest::binary>>, acc, buf) when c in @punctuation,
    do: parse(rest, acc, buf <> <<c>>)

  defp parse(<<?`, _::binary>> = s, acc, buf) do
    case Regex.run(@code, s) do
      [whole, _ticks, code] -> emit(s, whole, {:code, strip_code(code)}, acc, buf)
      nil -> literal_run(s, ?`, acc, buf)
    end
  end

  defp parse(<<"![", _::binary>> = s, acc, buf) do
    case Regex.run(@image, s) do
      [whole, alt] -> emit(s, whole, {:text, alt}, acc, buf)
      nil -> parse(binary_part(s, 1, byte_size(s) - 1), acc, buf <> "!")
    end
  end

  defp parse(<<?[, _::binary>> = s, acc, buf) do
    case Regex.run(@link, s) do
      [whole, label, url] -> emit(s, whole, {:link, url, label |> parse() |> unlink()}, acc, buf)
      nil -> next(s, acc, buf)
    end
  end

  defp parse(<<?<, _::binary>> = s, acc, buf) do
    case Regex.run(@autolink, s) do
      [whole, url] -> emit(s, whole, {:link, url, [{:text, url}]}, acc, buf)
      nil -> next(s, acc, buf)
    end
  end

  defp parse(<<"http", _::binary>> = s, acc, buf) do
    with true <- boundary?(buf), [url] <- Regex.run(@bare_url, s) do
      emit(s, url, {:link, url, [{:text, url}]}, acc, buf)
    else
      _ -> next(s, acc, buf)
    end
  end

  defp parse(<<?*, _::binary>> = s, acc, buf) do
    cond do
      match = Regex.run(@strong_em, s) ->
        [whole, inner] = match
        emit(s, whole, {:bold, [{:italic, parse(inner)}]}, acc, buf)

      match = Regex.run(@strong_star, s) ->
        [whole, inner] = match
        emit(s, whole, {:bold, parse(inner)}, acc, buf)

      match = Regex.run(@em_star, s) ->
        [whole, inner] = match
        emit(s, whole, {:italic, parse(inner)}, acc, buf)

      true ->
        literal_run(s, ?*, acc, buf)
    end
  end

  defp parse(<<?_, _::binary>> = s, acc, buf) do
    cond do
      not boundary?(buf) ->
        literal_run(s, ?_, acc, buf)

      match = Regex.run(@strong_under, s) ->
        [whole, inner] = match
        emit(s, whole, {:bold, parse(inner)}, acc, buf)

      match = Regex.run(@em_under, s) ->
        [whole, inner] = match
        emit(s, whole, {:italic, parse(inner)}, acc, buf)

      true ->
        literal_run(s, ?_, acc, buf)
    end
  end

  defp parse(s, acc, buf), do: next(s, acc, buf)

  # Links can't contain links (e.g. a bare URL used as a label).
  defp unlink(inlines) do
    Enum.flat_map(inlines, fn
      {:link, _url, children} -> unlink(children)
      {format, children} when format in [:bold, :italic] -> [{format, unlink(children)}]
      node -> [node]
    end)
  end

  # Consumes one character as literal text.
  defp next(<<c::utf8, rest::binary>>, acc, buf), do: parse(rest, acc, buf <> <<c::utf8>>)
  defp next(<<c, rest::binary>>, acc, buf), do: parse(rest, acc, buf <> <<c>>)

  # Consumes a run of the same delimiter character as literal text, so e.g. an
  # unmatched `**` isn't retried as `*` + `*`.
  defp literal_run(s, char, acc, buf) do
    run_length = count_leading(s, char, 0)
    <<run::binary-size(^run_length), rest::binary>> = s
    parse(rest, acc, buf <> run)
  end

  defp count_leading(<<c, rest::binary>>, c, n), do: count_leading(rest, c, n + 1)
  defp count_leading(_, _, n), do: n

  defp emit(s, whole, node, acc, buf) do
    rest = binary_part(s, byte_size(whole), byte_size(s) - byte_size(whole))

    case node do
      {:text, text} -> parse(rest, acc, buf <> text)
      node -> parse(rest, [node | flush(acc, buf)], "")
    end
  end

  defp flush(acc, ""), do: acc
  defp flush([{:text, prev} | acc], buf), do: [{:text, prev <> buf} | acc]
  defp flush(acc, buf), do: [{:text, buf} | acc]

  # True when the previous character isn't a letter or digit.
  defp boundary?(""), do: true
  defp boundary?(buf), do: not String.match?(String.last(buf), ~r/[\p{L}\p{N}]/u)

  # CommonMark: strip one leading and trailing space if both are present.
  defp strip_code(<<" ", _::binary>> = code) when byte_size(code) > 2 do
    if String.ends_with?(code, " ") and String.trim(code) != "",
      do: binary_part(code, 1, byte_size(code) - 2),
      else: code
  end

  defp strip_code(code), do: code
end
