defmodule Docgen.Template.Macros do
  @moduledoc """
  Turns a macro-enabled template (`.dotm`) into a plain `.docx` package.

  Removes VBA projects and signatures, `customUI/` ribbon parts and keymap
  customisations, drops every relationship and content-type override that
  pointed at them, and switches the main part to the `.docx` content type.
  """

  alias Docgen.Template

  @docx_main "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"

  @macro_part ~r{\A(customUI/|word/(_rels/)?(vba|customizations\.xml|attachedToolbars))}

  @spec strip(Template.t()) :: Template.t()
  def strip(%Template{} = template) do
    removed = template.order |> Enum.filter(&macro_part?/1) |> MapSet.new()
    template = Template.reject_parts(template, &MapSet.member?(removed, &1))

    template.order
    |> Enum.filter(&String.ends_with?(&1, ".rels"))
    |> Enum.reduce(template, fn rels, acc ->
      Template.update_part(acc, rels, &drop_relationships(&1, rels_base(rels), removed))
    end)
    |> Template.update_part("[Content_Types].xml", &content_types(&1, removed))
  end

  @doc "True if `part` is a macro/customisation part that must not ship in a `.docx`."
  @spec macro_part?(String.t()) :: boolean()
  def macro_part?(part), do: Regex.match?(@macro_part, part)

  defp drop_relationships(xml, base, removed) do
    Regex.replace(~r/<Relationship\b[^>]*\/>/, xml, fn rel ->
      target = attr(rel, "Target")
      external? = attr(rel, "TargetMode") == "External"

      if (not external? and target) && MapSet.member?(removed, resolve(base, target)),
        do: "",
        else: rel
    end)
  end

  defp content_types(xml, removed) do
    xml
    |> then(
      &Regex.replace(~r/<Override\b[^>]*\/>/, &1, fn override ->
        part = override |> attr("PartName") |> String.trim_leading("/")

        cond do
          MapSet.member?(removed, part) ->
            ""

          part == "word/document.xml" ->
            ~s(<Override PartName="/word/document.xml" ContentType="#{@docx_main}"/>)

          true ->
            override
        end
      end)
    )
    |> then(
      &Regex.replace(~r/<Default\b[^>]*\/>/, &1, fn default ->
        if String.contains?(attr(default, "ContentType") || "", "vbaProject"),
          do: "",
          else: default
      end)
    )
  end

  # "word/_rels/document.xml.rels" → "word"; "_rels/.rels" → ""
  defp rels_base(rels), do: rels |> Path.dirname() |> Path.dirname() |> String.trim_leading(".")

  defp resolve(_base, "/" <> absolute), do: absolute

  defp resolve(base, target) do
    ["/", base, target] |> Path.join() |> Path.expand("/") |> String.trim_leading("/")
  end

  defp attr(element, name) do
    case Regex.run(~r/\b#{name}="([^"]*)"/, element) do
      [_, value] -> value
      nil -> nil
    end
  end
end
