defmodule Docgen.UnsplashTest do
  use ExUnit.Case, async: true

  alias Docgen.Unsplash
  alias Docgen.UnsplashStub

  defp opts, do: [access_key: "key", client: UnsplashStub.client(self())]

  test "searches return photos with a credit line" do
    assert {:ok, [photo, _, _]} = Unsplash.search("warehouse scanning", opts())

    assert photo.credit == "Photo: Photographer 1 / Unsplash"
    assert photo.description == "warehouse scanning 1"

    assert_received {:unsplash, "https://api.unsplash.com/search/photos", request}
    assert request[:params][:query] == "warehouse scanning"
    assert {"authorization", "Client-ID key"} in request[:headers]
  end

  test "downloads are cropped for the slide and reported to Unsplash" do
    {:ok, [photo | _]} = Unsplash.search("retail", opts())

    assert {:ok, %{content_type: "image/jpeg", data: data}} = Unsplash.download(photo, opts())
    assert data == UnsplashStub.jpeg()

    assert_received {:unsplash, "https://images.example/1?ixid=1&w=900&h=960" <> _, _}
    assert_received {:unsplash, "https://api.unsplash.com/photos/1/download", _}
  end

  test "nothing is requested without an access key" do
    assert Unsplash.search("retail", access_key: nil, client: UnsplashStub.client(self())) ==
             {:error, :not_configured}

    refute_received {:unsplash, _, _}
  end

  test "API errors are returned" do
    client = fn _url, _request -> {:ok, %{status: 403, body: "Rate Limit Exceeded"}} end

    assert Unsplash.search("retail", access_key: "key", client: client) ==
             {:error, {:api_error, 403}}
  end
end
