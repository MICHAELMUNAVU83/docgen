defmodule Docgen.DocxHelpers do
  @moduledoc """
  Helpers for inspecting generated `.docx` packages in tests.
  """

  @doc "Unzips a package into `%{part_name => binary}`."
  def unzip!(docx) do
    {:ok, entries} = :zip.unzip(docx, [:memory])
    Map.new(entries, fn {name, data} -> {to_string(name), data} end)
  end

  @doc "True if `xml` parses as well-formed XML."
  def well_formed?(xml) do
    :xmerl_scan.string(:binary.bin_to_list(xml), quiet: true)
    true
  catch
    :exit, _ -> false
  end

  @doc "Paragraph style IDs used in `document.xml`, in order."
  def paragraph_styles(document_xml) do
    ~r/<w:pStyle w:val="([^"]+)"/
    |> Regex.scan(document_xml, capture: :all_but_first)
    |> List.flatten()
  end
end
