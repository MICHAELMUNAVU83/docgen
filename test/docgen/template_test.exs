defmodule Docgen.TemplateTest do
  use ExUnit.Case, async: true

  alias Docgen.Template
  alias Docgen.Template.{Macros, StyleMap}

  test "loads every bundled template" do
    for name <- Template.names() do
      assert {:ok, %Template{name: ^name} = template} = Template.load(name)
      assert Template.part(template, "word/document.xml") =~ "<w:body>"
    end
  end

  test "rejects unknown templates" do
    assert {:error, {:unknown_template, :nope}} = Template.load(:nope)
  end

  for name <- [:basic, :advanced, :letterhead] do
    test "every style in the #{name} style map exists in the template" do
      {:ok, template} = Template.load(unquote(name))
      {:ok, styles} = StyleMap.fetch(unquote(name))
      ids = Template.style_ids(template)

      toc = if StyleMap.option(styles, :toc), do: ~w(TOC1 TOC2 TOC3), else: []

      for id <- StyleMap.style_ids(styles) ++ toc,
          do: assert(id in ids, "missing style #{id}")
    end
  end

  test "cover icons" do
    icons = Template.cover_icons()
    assert {"transport_and_logistics", "Transport and Logistics"} in icons
    assert {"cpg", "CPG"} in icons
    assert {:ok, <<0x89, "PNG", _::binary>>} = Template.cover_icon("retail")
    assert Template.cover_icon("../basic.dotm") == :error
  end

  test "style lookups clamp to the deepest level" do
    {:ok, styles} = StyleMap.fetch(:basic)
    assert StyleMap.style(styles, {:heading, 9}) == "Heading7"
    assert StyleMap.style(styles, {:bullet, 5}) == "ListBullet3"
  end

  describe "Macros.strip/1" do
    for name <- Template.names() do
      test "removes macro parts and references from #{name}" do
        {:ok, template} = Template.load(unquote(name))
        stripped = Macros.strip(template)

        refute Enum.any?(stripped.order, &Macros.macro_part?/1)
        assert Enum.sort(stripped.order) == Enum.sort(Map.keys(stripped.parts))

        types = Template.part(stripped, "[Content_Types].xml")
        refute types =~ ~r/vba|macroEnabled|customUI/i
        assert types =~ "wordprocessingml.document.main+xml"

        for rels <- Enum.filter(stripped.order, &String.ends_with?(&1, ".rels")) do
          refute Template.part(stripped, rels) =~ ~r/vbaProject|vbaData|customUI|customizations/,
                 "#{rels} still references a macro part"
        end
      end
    end
  end
end
