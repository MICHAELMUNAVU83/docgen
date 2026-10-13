defmodule Docgen.Unsplash do
  @moduledoc """
  Finds and downloads photos from [Unsplash](https://unsplash.com/developers)
  for `Docgen.AI.Visuals`.

  Following the API guidelines, a photo that ends up in a document is
  reported through its download endpoint and carries a credit line naming
  the photographer.

  Configuration:

      config :docgen, Docgen.Unsplash, access_key: "…"

  Without an access key nothing is searched.
  """

  @api "https://api.unsplash.com/search/photos"

  # The picture panel of a slide, in pixels (see `Docgen.Render.Pptx`).
  @crop "w=900&h=960&fit=crop&crop=entropy&fm=jpg&q=80"

  @type photo :: %{
          id: String.t(),
          description: String.t(),
          thumb: String.t(),
          raw: String.t(),
          download_location: String.t() | nil,
          credit: String.t()
        }

  @doc "True when an access key is configured (or given in `opts`)."
  @spec configured?(keyword()) :: boolean()
  def configured?(opts \\ []), do: access_key(opts) not in [nil, ""]

  @doc """
  The best matches for `query`, most relevant first.

  ## Options

    * `:per_page` — how many photos to return (default 3)
    * `:access_key`, `:client` — override the configuration
  """
  @spec search(String.t(), keyword()) :: {:ok, [photo()]} | {:error, term()}
  def search(query, opts \\ []) do
    request = [
      params: [
        query: query,
        per_page: Keyword.get(opts, :per_page, 3),
        orientation: "squarish",
        content_filter: "high"
      ]
    ]

    case get(@api, request, opts) do
      {:ok, %{"results" => results}} when is_list(results) ->
        {:ok, Enum.flat_map(results, &photo/1)}

      {:ok, _body} ->
        {:error, :invalid_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Downloads `photo` cropped for a slide, and reports the download to Unsplash."
  @spec download(photo(), keyword()) :: {:ok, Docgen.Image.t()} | {:error, term()}
  def download(photo, opts \\ []) do
    separator = if String.contains?(photo.raw, "?"), do: "&", else: "?"

    with {:ok, <<0xFF, 0xD8, _::binary>> = data} <-
           get(photo.raw <> separator <> @crop, [], opts),
         %{} = image <- Docgen.Image.new("unsplash.jpg", data) do
      if photo.download_location, do: get(photo.download_location, [], opts)
      {:ok, image}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_image}
    end
  end

  defp photo(%{"id" => id, "urls" => %{"raw" => raw, "thumb" => thumb}} = result)
       when is_binary(raw) and is_binary(thumb) do
    [
      %{
        id: id,
        description: result["alt_description"] || result["description"] || "",
        thumb: thumb,
        raw: raw,
        download_location: get_in(result, ["links", "download_location"]),
        credit: "Photo: #{get_in(result, ["user", "name"]) || "Unsplash"} / Unsplash"
      }
    ]
  end

  defp photo(_result), do: []

  defp get(url, request, opts) do
    case access_key(opts) do
      key when key in [nil, ""] ->
        {:error, :not_configured}

      key ->
        client = Keyword.get_lazy(opts, :client, fn -> config()[:client] || (&Req.get/2) end)

        request =
          Keyword.merge(request,
            headers: [{"authorization", "Client-ID " <> key}, {"accept-version", "v1"}],
            receive_timeout: 10_000
          )

        case client.(url, request) do
          {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
          {:ok, %{status: status}} -> {:error, {:api_error, status}}
          {:error, reason} -> {:error, {:request_failed, reason}}
        end
    end
  end

  defp access_key(opts), do: Keyword.get_lazy(opts, :access_key, fn -> config()[:access_key] end)

  defp config, do: Application.get_env(:docgen, __MODULE__, [])
end
