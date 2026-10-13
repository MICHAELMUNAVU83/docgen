defmodule Docgen.UnsplashStub do
  @moduledoc """
  A stand-in for the Unsplash API, for `Docgen.Unsplash`'s `:client` option.
  Every request is sent to `test_pid` as `{:unsplash, url, request}`.
  """

  @jpeg <<0xFF, 0xD8, 0xFF, 0xC0, 0, 11, 8, 960::16, 900::16, 3, 0, 0, 0>>

  @doc "The smallest thing `Docgen.Image` reads as a 900 × 960 JPEG."
  def jpeg, do: @jpeg

  @doc "A client that answers every search with `photos` photos."
  def client(test_pid, photos \\ 3) do
    fn url, request ->
      send(test_pid, {:unsplash, url, request})

      cond do
        url =~ "/search/photos" ->
          query = request[:params][:query]

          {:ok,
           %{
             status: 200,
             body: %{"results" => Enum.take(Enum.map(1..3, &result(query, &1)), photos)}
           }}

        url =~ "images.example" ->
          {:ok, %{status: 200, body: @jpeg}}

        true ->
          {:ok, %{status: 200, body: %{}}}
      end
    end
  end

  defp result(query, n) do
    %{
      "id" => "#{query}-#{n}",
      "alt_description" => "#{query} #{n}",
      "urls" => %{
        "raw" => "https://images.example/#{n}?ixid=1",
        "thumb" => "https://images.example/thumb-#{n}"
      },
      "links" => %{"download_location" => "https://api.unsplash.com/photos/#{n}/download"},
      "user" => %{"name" => "Photographer #{n}"}
    }
  end
end
