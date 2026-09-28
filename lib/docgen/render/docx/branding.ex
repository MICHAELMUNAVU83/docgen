defmodule Docgen.Render.Docx.Branding do
  @moduledoc """
  Localises a template for a GS1 Member Organisation (MO).

  Settings come from `config :docgen, :localisation` (set from environment
  variables in `config/runtime.exs`); unset keys leave the template as is:

    * `:organisation` — replaces "GS1 AISBL" in headers/footers
      (e.g. "GS1 Kenya")
    * `:website` — replaces "www.gs1.org" in headers/footers
    * `:address` — lines replacing the Letterhead footer's address block
    * `:logo` — path to a PNG/JPEG replacing the GS1 logo; drawings keep
      their height and take the logo's aspect ratio

  Also removes header/footer graphics for letters printed on pre-printed
  paper (`hide_graphics/1`).
  """

  alias Docgen.Render.Docx.Xml
  alias Docgen.Template

  @doc "Current localisation settings."
  @spec settings() :: keyword()
  def settings, do: Application.get_env(:docgen, :localisation, [])

  @doc """
  Applies `settings` to `template`. `targets` gives the template-specific
  parts: `:logo_media` (the logo image part) and `:address_part`.
  """
  @spec apply(Template.t(), keyword(), map()) :: Template.t()
  def apply(template, settings, targets) do
    template
    |> replace_text("GS1 AISBL", settings[:organisation])
    |> replace_text("www.gs1.org", settings[:website])
    |> replace_address(targets[:address_part], settings[:address])
    |> replace_logo(targets[:logo_media], settings[:logo])
  end

  @doc "Removes all drawings from headers and footers."
  @spec hide_graphics(Template.t()) :: Template.t()
  def hide_graphics(template) do
    Enum.reduce(header_footer_parts(template), template, fn part, acc ->
      Template.update_part(acc, part, fn xml ->
        xml
        |> String.replace(~r{<w:drawing>.*?</w:drawing>}s, "")
        |> String.replace(~r{<w:pict>.*?</w:pict>}s, "")
      end)
    end)
  end

  defp header_footer_parts(template),
    do: Enum.filter(template.order, &(&1 =~ ~r{^word/(header|footer)\d*\.xml$}))

  ## Text

  defp replace_text(template, _from, value) when value in [nil, ""], do: template

  defp replace_text(template, from, value) do
    Enum.reduce(header_footer_parts(template), template, fn part, acc ->
      Template.update_part(acc, part, fn xml ->
        Regex.replace(~r{<w:p[ >].*?</w:p>}s, xml, &replace_in_paragraph(&1, from, value))
      end)
    end)
  end

  @t ~r{(<w:t\b[^>]*>)([^<]*)(</w:t>)}

  # Word splits text into runs freely ("GS1" + " " + "AISBL"), so matching
  # works on the paragraph's joined text: the first run a match touches gets
  # the replacement, the rest lose the matched characters.
  defp replace_in_paragraph(paragraph, from, value) do
    texts = @t |> Regex.scan(paragraph) |> Enum.map(fn [_, _, text, _] -> unescape(text) end)
    joined = Enum.join(texts)

    case :binary.match(joined, from) do
      :nomatch ->
        paragraph

      {start, len} ->
        {_offset, replaced} =
          Enum.reduce(texts, {0, []}, fn text, {offset, acc} ->
            size = byte_size(text)
            stop = offset + size
            cut_from = max(start, offset) - offset
            cut_to = min(start + len, stop) - offset

            new =
              if cut_to <= cut_from,
                do: text,
                else:
                  binary_part(text, 0, cut_from) <>
                    if(start >= offset, do: value, else: "") <>
                    binary_part(text, cut_to, size - cut_to)

            {stop, [new | acc]}
          end)

        replaced = Enum.reverse(replaced)

        {result, _} =
          Regex.split(@t, paragraph, include_captures: true)
          |> Enum.map_reduce(replaced, fn
            <<"<w:t", _::binary>> = tag, [text | rest] ->
              [_, open, _, close] = Regex.run(@t, tag)

              open =
                if open =~ "xml:space",
                  do: open,
                  else: String.replace(open, "<w:t", ~s(<w:t xml:space="preserve"), global: false)

              {open <> Xml.escape(text) <> close, rest}

            chunk, rest ->
              {chunk, rest}
          end)

        result = IO.iodata_to_binary(result)

        # Further matches — unless the value itself contains `from`, which
        # would never terminate.
        if String.contains?(value, from),
          do: result,
          else: replace_in_paragraph(result, from, value)
    end
  end

  defp unescape(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&amp;", "&")
  end

  # The address block is one text paragraph per line; lines fill them in
  # order and leftover paragraphs are emptied.
  defp replace_address(template, nil, _address), do: template
  defp replace_address(template, _part, address) when address in [nil, ""], do: template

  defp replace_address(template, part, address) do
    lines = address |> String.split(~r/\r?\n/) |> Enum.map(&String.trim/1)

    Template.update_part(template, part, fn xml ->
      {xml, _rest} =
        ~r{<w:p[ >].*?</w:p>}s
        |> Regex.split(xml, include_captures: true)
        |> Enum.map_reduce(lines, fn chunk, lines ->
          if chunk =~ ~r/\A<w:p[ >]/ and chunk =~ ~r{<w:t\b[^>]*>[^<]*\S[^<]*</w:t>} do
            {line, rest} = List.pop_at(lines, 0, "")
            {set_paragraph_text(chunk, line), rest}
          else
            {chunk, lines}
          end
        end)

      IO.iodata_to_binary(xml)
    end)
  end

  defp set_paragraph_text(paragraph, text) do
    {result, _first?} =
      ~r{<w:t\b[^>]*>[^<]*</w:t>}
      |> Regex.split(paragraph, include_captures: true)
      |> Enum.map_reduce(true, fn
        <<"<w:t", _::binary>> = _t, true ->
          {~s(<w:t xml:space="preserve">#{Xml.escape(text)}</w:t>), false}

        <<"<w:t", _::binary>> = _t, false ->
          {"<w:t></w:t>", false}

        chunk, first? ->
          {chunk, first?}
      end)

    IO.iodata_to_binary(result)
  end

  ## Logo

  defp replace_logo(template, nil, _logo), do: template
  defp replace_logo(template, _media, logo) when logo in [nil, ""], do: template

  defp replace_logo(template, media, path) do
    with {:ok, data} <- File.read(path),
         %{} = image <- Docgen.Image.new(path, data) do
      ext = Docgen.Image.extension(image.content_type)
      new_part = "word/media/docgen_logo.#{ext}"
      old_target = String.trim_leading(media, "word/")
      new_target = String.trim_leading(new_part, "word/")

      template
      |> Template.put_part(new_part, data)
      |> retarget_logo(old_target, new_target, image)
      |> Template.update_part("[Content_Types].xml", fn types ->
        if types =~ ~r/<Default Extension="#{ext}"/i,
          do: types,
          else:
            String.replace(
              types,
              "<Default ",
              ~s(<Default Extension="#{ext}" ContentType="#{image.content_type}"/><Default ),
              global: false
            )
      end)
    else
      _ -> template
    end
  end

  # Points header/footer relationships at the new logo and fixes the
  # extents of the drawings that use it.
  defp retarget_logo(template, old_target, new_target, image) do
    rels = Enum.filter(template.order, &(&1 =~ ~r{^word/_rels/(header|footer)\d*\.xml\.rels$}))

    Enum.reduce(rels, template, fn rels_part, acc ->
      xml = Template.part(acc, rels_part)

      ids =
        ~r/<Relationship\b[^>]*Id="([^"]+)"[^>]*Target="#{Regex.escape(old_target)}"/
        |> Regex.scan(xml, capture: :all_but_first)
        |> List.flatten()

      if ids == [] do
        acc
      else
        part = "word/" <> (rels_part |> Path.basename() |> String.trim_trailing(".rels"))

        acc
        |> Template.put_part(
          rels_part,
          String.replace(xml, ~s(Target="#{old_target}"), ~s(Target="#{new_target}"))
        )
        |> Template.update_part(part, &resize_drawings(&1, ids, image))
      end
    end)
  end

  defp resize_drawings(xml, ids, %{width: w, height: h}) when is_integer(w) and is_integer(h) do
    Regex.replace(~r{<w:drawing>.*?</w:drawing>}s, xml, fn drawing ->
      if Enum.any?(ids, &String.contains?(drawing, ~s(r:embed="#{&1}"))) do
        case Regex.run(~r/<wp:extent cx="\d+" cy="(\d+)"/, drawing) do
          [_, cy] ->
            cy = String.to_integer(cy)
            cx = div(cy * w, h)

            Regex.replace(
              ~r/(<wp:extent|<a:ext) cx="\d+" cy="\d+"/,
              drawing,
              "\\1 cx=\"#{cx}\" cy=\"#{cy}\""
            )

          nil ->
            drawing
        end
      else
        drawing
      end
    end)
  end

  defp resize_drawings(xml, _ids, _image), do: xml
end
