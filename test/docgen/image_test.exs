defmodule Docgen.ImageTest do
  use ExUnit.Case, async: true

  alias Docgen.Image

  test "reads PNG, GIF and JPEG sizes as EMU at 96 dpi" do
    assert Image.size_emu(Docgen.DocxBuilder.png(4, 2)) == {4 * 9525, 2 * 9525}
    assert Image.size_emu(<<"GIF89a", 3::little-16, 5::little-16, 0>>) == {3 * 9525, 5 * 9525}

    jpeg = <<0xFF, 0xD8, 0xFF, 0xE0, 0, 4, 0, 0, 0xFF, 0xC0, 0, 11, 8, 7::16, 9::16, 3>>
    assert Image.size_emu(jpeg) == {9 * 9525, 7 * 9525}

    assert Image.size_emu("nope") == {nil, nil}
  end

  test "new/3 prefers a given size and rejects unknown types" do
    png = Docgen.DocxBuilder.png(4, 2)

    assert %{content_type: "image/png", width: 100, height: 50} =
             Image.new("a.PNG", png, width: 100, height: 50)

    assert %{width: 38_100} = Image.new("a.png", png)
    assert Image.new("a.exe", png) == nil
  end
end
