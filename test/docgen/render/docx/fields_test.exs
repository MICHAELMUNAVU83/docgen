defmodule Docgen.Render.Docx.FieldsTest do
  use ExUnit.Case, async: true

  alias Docgen.Render.Docx.Fields

  @values %{"GS1 DocName" => "New & improved", "GS1 Description" => ""}

  test "simple fields" do
    xml =
      ~s(<w:fldSimple w:instr=" DOCPROPERTY &quot;GS1 DocName&quot; "><w:r><w:t>Old</w:t></w:r><w:r><w:t>er</w:t></w:r></w:fldSimple>)

    assert Fields.fill(xml, @values) ==
             ~s(<w:fldSimple w:instr=" DOCPROPERTY &quot;GS1 DocName&quot; "><w:r><w:t xml:space="preserve">New &amp; improved</w:t></w:r><w:r><w:t xml:space="preserve"></w:t></w:r></w:fldSimple>)
  end

  test "complex fields only change the result, not the instruction" do
    xml =
      ~s(<w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText> DOCPROPERTY  "GS1 DocName" </w:instrText></w:r>) <>
        ~s(<w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>Old</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r><w:r><w:t>after</w:t></w:r>)

    result = Fields.fill(xml, @values)
    assert result =~ ~s(<w:instrText> DOCPROPERTY  "GS1 DocName" </w:instrText>)
    assert result =~ ~s(<w:t xml:space="preserve">New &amp; improved</w:t>)
    assert result =~ "<w:t>after</w:t>"
  end

  test "IF fields testing a property take its value" do
    xml =
      ~s(<w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText> IF</w:instrText></w:r>) <>
        ~s(<w:fldSimple w:instr=" DOCPROPERTY &quot;GS1 Description&quot; "><w:r><w:instrText>Optional Description</w:instrText></w:r></w:fldSimple>) <>
        ~s(<w:r><w:instrText> &lt;&gt; "" "x" "" </w:instrText></w:r><w:r><w:fldChar w:fldCharType="separate"/></w:r>) <>
        ~s(<w:r><w:t>Optional Description</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r>)

    refute Fields.fill(xml, @values) =~ "Optional Description"
  end

  test "unrelated fields and text are untouched" do
    xml =
      ~s(<w:fldSimple w:instr=" PAGE "><w:r><w:t>3</w:t></w:r></w:fldSimple><w:r><w:t>GS1 DocName</w:t></w:r>)

    assert Fields.fill(xml, @values) == xml
  end

  test "custom properties" do
    xml = ~s(<property fmtid="x" pid="5" name="GS1 DocName"><vt:lpwstr>Old</vt:lpwstr></property>)
    assert Fields.set_properties(xml, @values) =~ "<vt:lpwstr>New &amp; improved</vt:lpwstr>"
  end
end
