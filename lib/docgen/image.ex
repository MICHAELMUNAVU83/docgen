defmodule Docgen.Image do
  @moduledoc """
  Image helpers for the IR's `{:image, image, caption}` blocks.

  An image is `%{data: binary, content_type: String.t(), width: emu, height: emu}`
  where the size (in EMU, 914400 per inch) may be `nil` when unknown.
  """

  @emu_per_px 9525

  @content_types %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".bmp" => "image/bmp",
    ".tif" => "image/tiff",
    ".tiff" => "image/tiff",
    ".svg" => "image/svg+xml",
    ".emf" => "image/x-emf",
    ".wmf" => "image/x-wmf"
  }

  @extensions %{
    "image/png" => "png",
    "image/jpeg" => "jpeg",
    "image/gif" => "gif",
    "image/bmp" => "bmp",
    "image/tiff" => "tiff",
    "image/svg+xml" => "svg",
    "image/x-emf" => "emf",
    "image/x-wmf" => "wmf"
  }

  @type t :: %{
          data: binary(),
          content_type: String.t(),
          width: pos_integer() | nil,
          height: pos_integer() | nil
        }

  @doc "Builds an image from a file name and data; `nil` for unknown types."
  @spec new(String.t(), binary(), keyword()) :: t() | nil
  def new(filename, data, opts \\ []) do
    with content_type when is_binary(content_type) <- content_type(filename) do
      {width, height} =
        case {opts[:width], opts[:height]} do
          {w, h} when is_integer(w) and is_integer(h) and w > 0 and h > 0 -> {w, h}
          _ -> size_emu(data)
        end

      %{data: data, content_type: content_type, width: width, height: height}
    end
  end

  @doc "MIME type from a file name's extension."
  @spec content_type(String.t()) :: String.t() | nil
  def content_type(filename),
    do: Map.get(@content_types, filename |> Path.extname() |> String.downcase())

  @doc "File extension (without dot) for a MIME type."
  @spec extension(String.t()) :: String.t()
  def extension(content_type), do: Map.get(@extensions, content_type, "bin")

  @doc "True for formats browsers can display in `<img>`."
  @spec web_safe?(t()) :: boolean()
  def web_safe?(%{content_type: type}), do: type in ~w(image/png image/jpeg image/gif image/bmp)

  @doc "Pixel size read from PNG, GIF or JPEG headers, converted to EMU at 96 dpi."
  @spec size_emu(binary()) :: {pos_integer(), pos_integer()} | {nil, nil}
  def size_emu(data) do
    case pixels(data) do
      {w, h} when w > 0 and h > 0 -> {w * @emu_per_px, h * @emu_per_px}
      _ -> {nil, nil}
    end
  end

  defp pixels(<<0x89, "PNG", 13, 10, 26, 10, _len::32, "IHDR", w::32, h::32, _::binary>>),
    do: {w, h}

  defp pixels(<<"GIF8", _, "a", w::little-16, h::little-16, _::binary>>), do: {w, h}
  defp pixels(<<0xFF, 0xD8, rest::binary>>), do: jpeg(rest)
  defp pixels(_), do: nil

  # Walks JPEG segments to the first start-of-frame marker.
  defp jpeg(<<0xFF, 0xFF, rest::binary>>), do: jpeg(<<0xFF, rest::binary>>)

  defp jpeg(<<0xFF, marker, _len::16, _precision, h::16, w::16, _::binary>>)
       when marker in 0xC0..0xCF and marker not in [0xC4, 0xC8, 0xCC],
       do: {w, h}

  defp jpeg(<<0xFF, _marker, len::16, rest::binary>>) when len >= 2 do
    skip = len - 2

    case rest do
      <<_::binary-size(^skip), next::binary>> -> jpeg(next)
      _ -> nil
    end
  end

  defp jpeg(_), do: nil
end
